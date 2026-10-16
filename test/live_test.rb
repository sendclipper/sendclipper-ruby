# frozen_string_literal: true

# Live end-to-end: this gem against a real SendClipper API, with an sc_live_
# key minted for the run.
#
#   LIVE_API_URL=http://localhost:4000 rake live
#
# It refuses anything that is not localhost: it creates and deletes data and
# sends mail through whatever transport the API has, which must be the local
# SES emulator (checked on /v1/health first). Skipped when LIVE_API_URL is unset.

require "test_helper"
require "net/http"

class LiveTest < Minitest::Test
  API = ENV.fetch("LIVE_API_URL", "")
  RUN = "sdkrb#{(Time.now.to_f * 1000).to_i.to_s(36)}"

  class << self
    attr_accessor :ctx
  end

  def raw(method, path, body = nil, token = nil)
    uri = URI("#{API}/v1#{path}")
    req = Net::HTTP.const_get(method.capitalize).new(uri)
    req["Content-Type"] = "application/json"
    req["Authorization"] = "Bearer #{token}" if token
    req.body = JSON.generate(body) if body
    res = Net::HTTP.start(uri.host, uri.port) { |h| h.request(req) }
    raise "#{method} #{path} -> #{res.code} #{res.body}" unless res.code.to_i < 300

    res.body.to_s.empty? ? nil : JSON.parse(res.body)
  end

  def setup
    skip "LIVE_API_URL is not set" if API.empty?
    return if self.class.ctx

    assert_includes %w[localhost 127.0.0.1], URI(API).host, "the live test runs against a local API only"
    backends = raw("GET", "/health")["backends"] || {}
    assert(backends["sesSend"] == "local" && backends["objectStore"] == "filesystem", "refusing a non-local API: #{backends}")

    jwt = raw("POST", "/auth/login", { email: ENV.fetch("LIVE_EMAIL", "enis@sendclipper.dev"),
                                       password: ENV.fetch("LIVE_PASSWORD", "password") })["token"]
    key = raw("POST", "/api-keys", { name: "#{RUN}-full", permission: "full" }, jwt)
    sc = SendClipper::Client.new(key["token"], base_url: API)
    domain = ok(sc.domains.list).find { |d| d["status"] == "verified" && !d["name"].end_with?(".example.com") }
    assert domain, "the seeded workspace needs a verified domain"
    self.class.ctx = { sc: sc, key_id: key["id"], from: "sdk-live@#{domain["name"]}" }
    Minitest.after_run { raw("DELETE", "/api-keys/#{key["id"]}", nil, jwt) }
  end

  def sc = self.class.ctx[:sc]

  def from = self.class.ctx[:from]

  def ok(result)
    assert_nil result.error, result.error.to_s
    result.data
  end

  def test_workspace_and_api_keys_read_back_with_the_minted_key
    assert ok(sc.workspace.get)["publicId"]
    assert_includes ok(sc.api_keys.list).map { _1["id"] }, self.class.ctx[:key_id]
  end

  def test_send_then_get_and_a_repeated_idempotency_key_answers_the_first_send
    params = { from: from, to: "ada+#{RUN}@lumen.io", subject: "SDK live #{RUN} Grüße", html: "<p>Hello from Ruby</p>", text: "Hello from Ruby" }
    first = ok(sc.emails.send(**params, idempotency_key: "#{RUN}-welcome"))
    assert_equal params[:to], first["to"]
    again = sc.emails.send(**params, idempotency_key: "#{RUN}-welcome")
    assert_equal first["id"], ok(again)["id"]
    assert_equal "true", again.headers["idempotency-replayed"]
    detail = ok(sc.emails.get(first["id"]))
    assert_equal params[:subject], detail["subject"]
    assert_kind_of Array, detail["events"]
  end

  def test_an_api_refusal_comes_back_as_error_with_the_api_code_never_a_raise
    data, error = sc.emails.send(from: "nobody@not-a-domain-we-own.test", to: "a@lumen.io", subject: "s", html: "h")
    assert_nil data
    assert_equal 403, error.status_code
    refute_empty error.name
    _, invalid = sc.emails.send(from: from, to: "not-an-address", subject: "s", html: "h")
    assert_equal "validation_failed", invalid.name
  end

  def test_batch_send_accepts_and_refuses_items_independently
    res = ok(sc.batch.send([
                             { from: from, to: "b1+#{RUN}@lumen.io", subject: "batch 1", html: "<p>1</p>" },
                             { from: from, to: "b2+#{RUN}@lumen.io", template_id: "tpl_doesnotexist0" }
                           ]))
    assert_equal 2, res["summary"]["submitted"]
    assert_equal %w[accepted failed], res["data"].map { _1["status"] }
  end

  def test_templates_create_preview_publish_send_by_id_remove
    t = ok(sc.templates.create(name: "#{RUN} welcome", subject: "Welcome {{first_name|there}}",
                               blocks: [{ type: "text", text: "Hi {{first_name|there}}, welcome aboard." }]))
    assert_equal "Welcome Ada", ok(sc.templates.preview(t["id"], { first_name: "Ada" }))["subject"]
    assert_equal "Welcome there", ok(sc.templates.preview(t["id"]))["subject"]
    ok(sc.templates.publish(t["id"]))
    sent = ok(sc.emails.send(from: from, to: "t+#{RUN}@lumen.io", template_id: t["publicId"], variables: { first_name: "Ada" }))
    assert_equal "Welcome Ada", sent["subject"]
    assert_includes ok(sc.templates.html(t["id"])), "Hi"
  ensure
    sc.templates.remove(t["id"]) if t
  end

  def test_sandboxes_reset_credentials_send_with_token_wait_for_raw
    box = ok(sc.sandboxes.create(name: "#{RUN}-box"))
    creds = ok(sc.sandboxes.reset_credentials(box["id"]))
    assert creds["apiToken"].start_with?("sc_sbx_")
    subject = "trapped #{RUN}"
    ok(sc.sandboxes.send(creds["apiToken"], from: "app@example.com", to: "someone@example.com", subject: subject, html: "<p>trap</p>"))
    msg = ok(sc.sandboxes.messages.wait_for(box["id"], timeout: 15, interval: 0.3) { |m| m["subject"] == subject })
    assert_equal subject, msg["subject"]
    assert_includes ok(sc.sandboxes.messages.raw(box["id"], msg["id"])), "Subject: #{subject}"
  ensure
    sc.sandboxes.remove(box["id"]) if box
  end

  def test_webhooks_create_returns_the_secret_once_and_verify_accepts_it
    hook = ok(sc.webhooks.create(url: "http://127.0.0.1:9/sdk-live-rb", events: %w[email.delivered email.bounced], allow_insecure_http: true))
    assert hook["secret"].start_with?("whsec_")
    body = JSON.generate({ id: "evt_live", event: "email.delivered", createdAt: "2026-10-16T10:00:00Z", data: {} })
    assert_equal "evt_live", sc.webhooks.verify(body, SendClipper.webhook_signature_header(hook["secret"], body), hook["secret"])["id"]
    assert_equal ["email.opened"], ok(sc.webhooks.update(hook["id"], events: ["email.opened"]))["events"]
    refute_equal hook["secret"], ok(sc.webhooks.rotate_secret(hook["id"]))["secret"]
    assert_kind_of Array, ok(sc.webhooks.dispatches.list(state: "all", limit: 5))["data"]
  ensure
    sc.webhooks.remove(hook["id"]) if hook
  end

  def test_suppressions_add_find_remove_with_a_reason
    email = "blocked+#{RUN}@lumen.io"
    created = ok(sc.suppressions.create(email: email, note: "sdk live test"))
    assert created["created"]
    assert_includes sc.suppressions.each(q: email).map { _1["email"] }, email
    ok(sc.suppressions.remove(created["row"]["id"], "Removed by the Ruby SDK live test run"))
  end

  def test_contacts_import_preview_multipart_and_iterators
    c = ok(sc.contacts.create(name: "SDK Live", email: "contact+#{RUN}@lumen.io"))
    assert_equal "contact+#{RUN}@lumen.io", c["email"]
    refute_empty ok(sc.contacts.import_preview(file: "name,email\nRuby Live,rb+#{RUN}@lumen.io\n"))
    sc.emails.send(from: from, to: "it+#{RUN}@lumen.io", subject: "iterate #{RUN}", html: "<p>i</p>")
    n = sc.emails.each(search: RUN, page_size: 2).count
    assert_operator n, :>=, 1, "expected this run's sends in the log, saw #{n}"
  end
end
