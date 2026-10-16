# frozen_string_literal: true

require "test_helper"

class ClientTest < Minitest::Test
  include Helpers

  SENT = {
    "id" => "0b6c0000-0000-4000-8000-000000000001", "messageId" => "msg_9f2b7c10ad", "sesMessageId" => nil,
    "from" => "hello@acme.io", "to" => "ada@lumen.io", "domain" => "acme.io", "subject" => "Hi",
    "status" => "queued", "createdAt" => "2026-10-16T10:00:00.000Z", "templateId" => nil
  }.freeze
  MSG = { from: "a@acme.io", to: "b@lumen.io", subject: "s", html: "h" }.freeze

  def teardown
    ENV.delete("SENDCLIPPER_API_KEY")
    ENV.delete("SENDCLIPPER_BASE_URL")
  end

  def test_send_posts_to_v1_emails_with_the_key_and_an_idempotency_key
    c, t, = client([json(201, SENT)])
    result = c.emails.send(from: "hello@acme.io", to: "ada@lumen.io", subject: "Hi", html: "<p>Hi</p>")
    assert result.ok?
    assert_nil result.error
    assert_equal SENT, result.data
    assert_equal "application/json", result.headers["content-type"]
    call = t.calls.first
    assert_equal "POST", call.method
    assert_equal "https://api.test/v1/emails", call.url
    assert_equal "Bearer sc_live_test", call.headers["Authorization"]
    assert_equal "application/json", call.headers["Content-Type"]
    assert_equal "sendclipper-ruby/#{SendClipper::VERSION}", call.headers["User-Agent"]
    assert_match(/\Asc-ruby-\h{8}-\h{4}-4\h{3}-[89ab]\h{3}-\h{12}\z/, call.headers["Idempotency-Key"])
    assert_equal '{"from":"hello@acme.io","to":"ada@lumen.io","subject":"Hi","html":"<p>Hi</p>"}', call.body
  end

  def test_a_result_destructures_to_data_and_error_and_pattern_matches
    c, = client([json(201, SENT), json(201, SENT)])
    data, error = c.emails.send(MSG)
    assert_equal SENT["id"], data["id"]
    assert_nil error
    case c.emails.send(MSG)
    in { data: Hash => sent, error: nil }
      assert_equal SENT["id"], sent["id"]
    end
  end

  def test_snake_case_fields_become_the_apis_camel_case_and_values_are_left_alone
    c, t, = client([json(201, SENT)])
    c.emails.send({ "from" => "hello@acme.io" }, to: "ada@lumen.io", template_id: "tpl_9f2b7c10ad42",
                                                  variables: { first_name: "Ada" }, track_opens: false,
                                                  send_class: "marketing", idempotency_key: "order-42-receipt")
    call = t.calls.first
    assert_equal "order-42-receipt", call.headers["Idempotency-Key"]
    assert_equal({ "from" => "hello@acme.io", "to" => "ada@lumen.io", "templateId" => "tpl_9f2b7c10ad42",
                   "variables" => { "first_name" => "Ada" }, "trackOpens" => false, "sendClass" => "marketing" }, body(call))
  end

  def test_nil_fields_are_dropped_and_empty_bodies_are_json_objects
    c, t, = client([json(201, SENT), json(201, {}), json(200, {})])
    c.emails.send(MSG.merge(text: nil))
    c.templates.create
    c.templates.preview("t1")
    refute body(t.calls[0]).key?("text")
    assert_equal "{}", t.calls[1].body
    assert_equal '{"variables":{}}', t.calls[2].body
  end

  def test_non_ascii_is_sent_as_utf8
    c, t, = client([json(201, SENT)])
    c.emails.send(MSG.merge(text: "Grüße, Përshëndetje"))
    assert_equal "Grüße, Përshëndetje", body(t.calls.first)["text"]
  end

  def test_a_503_is_retried_with_the_same_idempotency_key
    c, t, = client([json(503, { "error" => { "code" => "unavailable", "message" => "down" } }), json(201, SENT)])
    data, = c.emails.send(MSG)
    assert_equal SENT["id"], data["id"]
    assert_equal 2, t.calls.length
    assert_equal t.calls[0].headers["Idempotency-Key"], t.calls[1].headers["Idempotency-Key"]
  end

  def test_a_network_error_is_retried_then_answers_network_error_with_no_status
    c, t, = client([SendClipper::TransportError.new("refused"), SendClipper::TransportError.new("refused")], max_retries: 1)
    data, error = c.emails.get("x")
    assert_nil data
    assert_equal "network_error", error.name
    assert_nil error.status_code
    assert_includes error.message, "Could not reach SendClipper at https://api.test"
    assert_equal 2, t.calls.length
  end

  def test_a_timeout_names_the_limit
    c, t, = client([SendClipper::TransportError.new("timed out", timed_out: true)], timeout: 2.5, max_retries: 0)
    _, error = c.workspace.get
    assert_equal "network_error", error.name
    assert_includes error.message, "within 2.5 s"
    assert_in_delta 2.5, t.calls.first.timeout
  end

  def test_a_per_call_timeout_overrides_the_client
    c, t, = client([json(200, [])])
    c.domains.list(timeout: 4)
    assert_in_delta 4.0, t.calls.first.timeout
  end

  def test_an_unknown_request_option_on_an_id_method_is_refused_loudly
    c, = client([])
    err = assert_raises(ArgumentError) { c.domains.records("d1", idempotency: "x") }
    assert_match(/Unknown request option :idempotency/, err.message)
  end

  def test_429_honours_retry_after_capped_at_a_minute
    c, t, slept = client([
                           json(429, { "error" => { "code" => "rate_limited", "message" => "slow" } }, "Retry-After" => "3"),
                           json(503, nil, "Retry-After" => "86400"),
                           json(200, [])
                         ])
    assert_equal [], c.domains.list.data
    assert_equal 3, t.calls.length
    assert_equal [3.0, 60.0], slept
  end

  def test_backoff_grows_and_stays_bounded
    10.times do |attempt|
      base = [8.0, 0.5 * (2**attempt)].min
      b = SendClipper::HttpClient.backoff(attempt)
      assert_operator b, :>=, base / 2
      assert_operator b, :<=, base
    end
  end

  def test_idempotency_key_in_flight_is_retried_and_any_other_409_is_not
    in_flight = json(409, { "error" => { "code" => "idempotency_key_in_flight", "message" => "wait" } }, "Retry-After" => "0")
    c, t, = client([in_flight, json(201, SENT)])
    c.emails.send(MSG)
    assert_equal 2, t.calls.length

    c, t, = client([json(409, { "error" => { "code" => "sandbox_name_taken", "message" => "taken" } })])
    _, error = c.sandboxes.create(name: "x")
    assert_equal ["sandbox_name_taken", "taken", 409, nil], [error.name, error.message, error.status_code, error.detail]
    assert_equal 1, t.calls.length
  end

  def test_a_4xx_is_not_retried_and_the_envelope_becomes_a_typed_error
    c, t, = client([json(400, { "error" => { "code" => "template_variables_missing", "message" => "Missing first_name",
                                              "detail" => { "missing" => ["first_name"] } } })])
    data, error = c.emails.send(from: "a@acme.io", to: "b@lumen.io", template_id: "tpl_x")
    assert_nil data
    assert_equal "template_variables_missing", error.name
    assert_equal "Missing first_name", error.message
    assert_equal 400, error.status_code
    assert_equal({ "missing" => ["first_name"] }, error.detail)
    assert_equal 1, t.calls.length
  end

  def test_a_validation_error_in_nests_default_shape_becomes_validation_failed
    c, = client([json(400, { "statusCode" => 400, "message" => ["to must be a valid email address"], "error" => "Bad Request" })])
    _, error = c.emails.send(MSG.merge(to: "nope"))
    assert_equal "validation_failed", error.name
    assert_equal "to must be a valid email address", error.message
  end

  def test_a_non_json_error_body_still_answers_a_code
    c, = client([SendClipper::TransportResponse.new(status: 502, headers: { "content-type" => "text/html" }, body: "<html>Bad gateway</html>")], max_retries: 0)
    _, error = c.domains.list
    assert_equal "http_502", error.name
    assert_equal "<html>Bad gateway</html>", error.message
  end

  def test_get_requests_carry_no_idempotency_key_and_drop_empty_query_values
    c, t, = client([json(200, { "items" => [], "total" => 0 })])
    c.emails.list(status: "bounced", search: "", domain: nil, page_size: 50)
    refute t.calls.first.headers.key?("Idempotency-Key")
    assert_equal "https://api.test/v1/emails?status=bounced&pageSize=50", t.calls.first.url
  end

  def test_booleans_in_the_query_are_written_the_way_the_api_reads_them
    c, t, = client([json(200, []), json(200, [])])
    c.mailboxes.list(include_archived: true)
    c.webhooks.deliveries(final_only: false)
    assert_equal({ "includeArchived" => "true" }, query(t.calls[0]))
    assert_equal({ "finalOnly" => "false" }, query(t.calls[1]))
  end

  def test_emails_each_walks_every_page_and_stops_on_the_last
    row = ->(n) { SENT.merge("id" => "id-#{n}") }
    c, t, = client([
                     json(200, { "items" => [row.(1), row.(2)], "total" => 3 }),
                     json(200, { "items" => [row.(3)], "total" => 3 })
                   ])
    assert_equal %w[id-1 id-2 id-3], c.emails.each(page_size: 2).map { |e| e["id"] }
    assert_equal 2, t.calls.length
    assert_equal "2", query(t.calls[1])["page"]
  end

  def test_an_enumerator_is_lazy_and_stops_when_you_do
    c, t, = client([json(200, { "data" => [{ "id" => "a" }, { "id" => "b" }], "page" => { "cursor" => "c1", "hasMore" => true } })])
    assert_equal({ "id" => "a" }, c.suppressions.each.first)
    assert_equal 1, t.calls.length
  end

  def test_suppressions_each_follows_the_cursor
    s = ->(email) { { "id" => email, "email" => email, "reason" => "manual" } }
    c, t, = client([
                     json(200, { "data" => [s.("a@x.io")], "page" => { "cursor" => "c1", "hasMore" => true } }),
                     json(200, { "data" => [s.("b@x.io")], "page" => { "cursor" => nil, "hasMore" => false } })
                   ])
    seen = []
    c.suppressions.each(reason: "manual", cursor: "ignored") { |r| seen << r["email"] }
    assert_equal %w[a@x.io b@x.io], seen
    assert_equal({ "reason" => "manual" }, query(t.calls[0]))
    assert_equal({ "reason" => "manual", "cursor" => "c1" }, query(t.calls[1]))
  end

  def test_an_iterator_raises_api_error_since_a_loop_has_no_error_to_return
    c, = client([json(403, { "error" => { "code" => "api_key_not_accepted", "message" => "no" } })])
    err = assert_raises(SendClipper::ApiError) { c.contacts.each.to_a }
    assert_equal "api_key_not_accepted", err.code
    assert_equal 403, err.status
  end

  def test_unwrap_raises_the_error
    c, = client([json(404, { "error" => { "code" => "not_found", "message" => "No such domain" } })])
    err = assert_raises(SendClipper::ApiError) { c.domains.records("d1").unwrap }
    assert_equal "No such domain", err.message
  end

  def test_suppressions_remove_sends_the_recorded_reason_as_the_delete_body
    c, t, = client([json(200, { "removed" => true })])
    c.suppressions.remove("sup-1", "Customer asked us to resume mail")
    assert_equal "DELETE", t.calls.first.method
    assert_equal "/v1/suppressions/sup-1", path(t.calls.first)
    assert_equal({ "reason" => "Customer asked us to resume mail" }, body(t.calls.first))
  end

  def test_sandboxes_send_uses_the_sandbox_token_instead_of_the_api_key
    c, t, = client([json(201, { "id" => "sbx-msg" })])
    c.sandboxes.send("sc_sbx_abc", **MSG)
    assert_equal "/v1/sandbox/emails", path(t.calls.first)
    assert_equal "Bearer sc_sbx_abc", t.calls.first.headers["Authorization"]
  end

  def test_contacts_import_is_multipart_carries_no_idempotency_key_and_is_never_retried
    c, t, = client([json(503, { "error" => { "code" => "unavailable", "message" => "down" } })])
    _, error = c.contacts.import(file: "name,email\nAda,ada@lumen.io\n", filename: "contacts.csv", on_duplicate: "update")
    assert_equal 503, error.status_code
    assert_equal 1, t.calls.length
    call = t.calls.first
    refute call.headers.key?("Idempotency-Key")
    boundary = call.headers["Content-Type"][/\Amultipart\/form-data; boundary=(\S+)\z/, 1]
    parts = call.body.split("--#{boundary}")[1..-2]
    assert_equal "\r\nContent-Disposition: form-data; name=\"onDuplicate\"\r\n\r\nupdate\r\n", parts[0]
    assert_equal "\r\nContent-Disposition: form-data; name=\"file\"; filename=\"contacts.csv\"\r\n" \
                 "Content-Type: text/csv\r\n\r\nname,email\nAda,ada@lumen.io\n\r\n", parts[1]
  end

  def test_a_vcf_import_is_sent_as_text_vcard
    c, t, = client([json(200, {})])
    c.contacts.import_preview(file: "BEGIN:VCARD\r\nEND:VCARD\r\n", filename: "people.vcf")
    assert_equal "/v1/contacts/import/preview", path(t.calls.first)
    assert_includes t.calls.first.body, "Content-Type: text/vcard"
  end

  def test_template_assets_upload_base64_encodes_bytes
    c, t, = client([json(201, { "id" => "a" })])
    c.templates.assets.upload(data: "\x01\x02\x03".b, mime_type: "image/png", name: "logo")
    assert_equal({ "mimeType" => "image/png", "base64" => "AQID", "name" => "logo" }, body(t.calls.first))
  end

  def test_text_endpoints_return_the_body_as_a_utf8_string
    c, = client([SendClipper::TransportResponse.new(status: 200, headers: { "content-type" => "text/html; charset=utf-8" }, body: "<html>hï</html>".b)])
    html = c.templates.html("tpl_1").data
    assert_equal "<html>hï</html>", html
    assert_equal Encoding::UTF_8, html.encoding
  end

  def test_an_attachment_download_returns_bytes_type_and_filename
    c, t, = client([SendClipper::TransportResponse.new(status: 200, headers: {
                                                         "content-type" => "application/pdf",
                                                         "content-disposition" => "attachment; filename*=UTF-8''Rechnung%20M%C3%A4rz.pdf"
                                                       }, body: "%PDF")])
    file = c.mailboxes.messages.attachment("m1", "msg1", "p1").unwrap
    assert_equal "%PDF", file.content
    assert_equal "application/pdf", file.content_type
    assert_equal "Rechnung März.pdf", file.filename
    assert_equal({ "download" => "1" }, query(t.calls.first))
    assert_equal "*/*", t.calls.first.headers["Accept"]
  end

  def test_path_segments_are_encoded
    c, t, = client([json(200, {})])
    c.templates.get("a/b?c")
    assert_equal "https://api.test/v1/templates/a%2Fb%3Fc", t.calls.first.url
  end

  def test_no_key_anywhere_is_a_clear_api_key_missing_and_no_request_is_made
    ENV.delete("SENDCLIPPER_API_KEY")
    t = FakeTransport.new([])
    _, error = SendClipper::Client.new(transport: t).domains.list
    assert_equal "api_key_missing", error.name
    assert_equal 401, error.status_code
    assert_empty t.calls
  end

  def test_the_key_and_base_url_fall_back_to_the_environment_and_a_trailing_v1_is_tolerated
    ENV["SENDCLIPPER_API_KEY"] = "sc_live_env"
    ENV["SENDCLIPPER_BASE_URL"] = "http://localhost:4000/v1/"
    t = FakeTransport.new([json(200, [])])
    c = SendClipper::Client.new(transport: t)
    c.domains.list
    assert_equal "http://localhost:4000", c.base_url
    assert_equal "http://localhost:4000/v1/domains", t.calls.first.url
    assert_equal "Bearer sc_live_env", t.calls.first.headers["Authorization"]
  end

  def test_default_and_per_call_headers_are_sent
    c, t, = client([json(200, [])], default_headers: { "X-App" => "shop" })
    c.domains.list(headers: { "X-Trace-Id" => "t1" })
    assert_equal "shop", t.calls.first.headers["X-App"]
    assert_equal "t1", t.calls.first.headers["X-Trace-Id"]
  end

  def test_batch_send_posts_emails_with_camel_case_fields_and_returns_per_item_results
    reply = {
      "data" => [
        { "index" => 0, "status" => "accepted", "id" => "e1", "messageId" => "m1" },
        { "index" => 1, "status" => "failed", "error" => { "code" => "template_not_published", "message" => "draft" } }
      ],
      "summary" => { "submitted" => 2, "accepted" => 1, "failed" => 1 }
    }
    c, t, = client([json(200, reply), json(200, reply)])
    items = [MSG, { from: "a@acme.io", to: "y@lumen.io", template_id: "tpl_draft" }]
    assert_equal reply, c.batch.send(items).data
    c.emails.send_batch(items)
    t.calls.each do |call|
      assert_equal "/v1/emails/batch", path(call)
      assert_equal({ "emails" => [{ "from" => "a@acme.io", "to" => "b@lumen.io", "subject" => "s", "html" => "h" },
                                  { "from" => "a@acme.io", "to" => "y@lumen.io", "templateId" => "tpl_draft" }] }, body(call))
      assert call.headers["Idempotency-Key"]
    end
  end

  def test_sandbox_wait_for_polls_until_a_match_then_reads_it
    summary = { "id" => "m2", "subject" => "Hi", "trappedAt" => "2026-10-16T10:00:00.000Z" }
    c, t, = client([json(200, []), json(200, [summary]), json(200, summary.merge("bodyHtml" => "<p>Hi</p>"))])
    msg, error = c.sandboxes.messages.wait_for("sbx1", interval: 0) { |m| m["subject"] == "Hi" }
    assert_nil error
    assert_equal "<p>Hi</p>", msg["bodyHtml"]
    assert_equal %w[/v1/sandboxes/sbx1/messages /v1/sandboxes/sbx1/messages /v1/sandboxes/sbx1/messages/m2], t.calls.map { path(_1) }
    assert_equal({ "limit" => "50" }, query(t.calls.first))
  end

  def test_sandbox_wait_for_times_out_with_error_timeout
    c, = client(Array.new(5) { json(200, []) })
    _, error = c.sandboxes.messages.wait_for("sbx1", timeout: 0, interval: 0)
    assert_equal "timeout", error.name
    assert_nil error.status_code
  end

  def test_a_result_is_frozen
    assert SendClipper::Result.new({}, nil, {}).frozen?
  end

  ROUTES = [
    ["POST", "/v1/domains", ->(c) { c.domains.create(name: "send.acme.io", region: "eu-west-1") }],
    ["POST", "/v1/domains/d1/verify", ->(c) { c.domains.verify("d1") }],
    ["POST", "/v1/domains/d1/receiving", ->(c) { c.domains.enable_receiving("d1") }],
    ["DELETE", "/v1/domains/d1/receiving", ->(c) { c.domains.disable_receiving("d1") }],
    ["PATCH", "/v1/domains/d1/region", ->(c) { c.domains.set_region("d1", "us-east-1") }],
    ["GET", "/v1/domains/d1/deletion", ->(c) { c.domains.deletion_preview("d1") }],
    ["DELETE", "/v1/domains/d1", ->(c) { c.domains.remove("d1") }],
    ["GET", "/v1/emails/stats/summary", ->(c) { c.emails.stats }],
    ["GET", "/v1/templates", ->(c) { c.templates.list(tag: "t1") }],
    ["PATCH", "/v1/templates/t1", ->(c) { c.templates.update("t1", name: "n") }],
    ["DELETE", "/v1/templates/t1", ->(c) { c.templates.remove("t1") }],
    ["POST", "/v1/templates/t1/duplicate", ->(c) { c.templates.duplicate("t1") }],
    ["POST", "/v1/templates/t1/publish", ->(c) { c.templates.publish("t1") }],
    ["POST", "/v1/templates/t1/unpublish", ->(c) { c.templates.unpublish("t1") }],
    ["PUT", "/v1/templates/t1/tags", ->(c) { c.templates.set_tags("t1", ["g1"]) }],
    ["GET", "/v1/templates/projects", ->(c) { c.templates.projects }],
    ["GET", "/v1/templates/tags", ->(c) { c.templates.tags.list }],
    ["POST", "/v1/templates/tags", ->(c) { c.templates.tags.create(name: "n", color: "blue") }],
    ["PATCH", "/v1/templates/tags/g1", ->(c) { c.templates.tags.update("g1", color: "red") }],
    ["DELETE", "/v1/templates/tags/g1", ->(c) { c.templates.tags.remove("g1") }],
    ["GET", "/v1/templates/assets", ->(c) { c.templates.assets.list }],
    ["GET", "/v1/sandboxes", ->(c) { c.sandboxes.list }],
    ["GET", "/v1/sandboxes/s1", ->(c) { c.sandboxes.get("s1") }],
    ["PATCH", "/v1/sandboxes/s1", ->(c) { c.sandboxes.update("s1", name: "n") }],
    ["DELETE", "/v1/sandboxes/s1", ->(c) { c.sandboxes.remove("s1") }],
    ["GET", "/v1/sandboxes/s1/credentials", ->(c) { c.sandboxes.credentials("s1") }],
    ["POST", "/v1/sandboxes/s1/credentials", ->(c) { c.sandboxes.reset_credentials("s1") }],
    ["GET", "/v1/sandboxes/s1/messages/m1/raw", ->(c) { c.sandboxes.messages.raw("s1", "m1") }],
    ["DELETE", "/v1/sandboxes/s1/messages/m1", ->(c) { c.sandboxes.messages.remove("s1", "m1") }],
    ["DELETE", "/v1/sandboxes/s1/messages", ->(c) { c.sandboxes.messages.clear("s1") }],
    ["POST", "/v1/sandboxes/s1/read-all", ->(c) { c.sandboxes.messages.mark_all_read("s1") }],
    ["GET", "/v1/webhook-endpoints", ->(c) { c.webhooks.list }],
    ["POST", "/v1/webhook-endpoints", ->(c) { c.webhooks.create(url: "https://x.io", events: ["email.delivered"]) }],
    ["PATCH", "/v1/webhook-endpoints/w1", ->(c) { c.webhooks.update("w1", active: false) }],
    ["DELETE", "/v1/webhook-endpoints/w1", ->(c) { c.webhooks.remove("w1") }],
    ["POST", "/v1/webhook-endpoints/w1/rotate-secret", ->(c) { c.webhooks.rotate_secret("w1") }],
    ["GET", "/v1/webhook-dispatches", ->(c) { c.webhooks.dispatches.list }],
    ["GET", "/v1/webhook-dispatches/x1", ->(c) { c.webhooks.dispatches.get("x1") }],
    ["POST", "/v1/webhook-dispatches/x1/replay", ->(c) { c.webhooks.dispatches.replay("x1") }],
    ["POST", "/v1/webhook-dispatches/replay-all", ->(c) { c.webhooks.dispatches.replay_all }],
    ["GET", "/v1/contacts", ->(c) { c.contacts.list }],
    ["POST", "/v1/contacts", ->(c) { c.contacts.create(name: "Ada", email: "a@x.io") }],
    ["GET", "/v1/contacts/export", ->(c) { c.contacts.export(format: "vcf") }],
    ["GET", "/v1/audiences", ->(c) { c.audiences.list }],
    ["POST", "/v1/suppressions", ->(c) { c.suppressions.create(email: "a@x.io") }],
    ["GET", "/v1/suppressions/export", ->(c) { c.suppressions.export(reason: "manual") }],
    ["GET", "/v1/mailboxes/mb1", ->(c) { c.mailboxes.get("mb1") }],
    ["POST", "/v1/mailboxes", ->(c) { c.mailboxes.create(domain_id: "d1", local_part: "support") }],
    ["PATCH", "/v1/mailboxes/mb1", ->(c) { c.mailboxes.update("mb1", display_name: "Support") }],
    ["DELETE", "/v1/mailboxes/mb1", ->(c) { c.mailboxes.archive("mb1") }],
    ["GET", "/v1/mailboxes/mb1/messages", ->(c) { c.mailboxes.messages.list("mb1", folder: "inbox") }],
    ["GET", "/v1/mailboxes/mb1/messages/m1", ->(c) { c.mailboxes.messages.get("mb1", "m1") }],
    ["POST", "/v1/automations/a1/enrollments", ->(c) { c.automations.enroll("a1", "ada@x.io") }],
    ["GET", "/v1/workspace", ->(c) { c.workspace.get }],
    ["GET", "/v1/api-keys", ->(c) { c.api_keys.list }]
  ].freeze

  ROUTES.each do |method, route, fn|
    define_method("test_route #{method} #{route}") do
      c, t, = client([json(200, {})])
      result = fn.call(c)
      assert result.ok?, result.error.to_s
      assert_equal [method, route], [t.calls.first.method, path(t.calls.first)]
      assert t.calls.first.headers["Idempotency-Key"], "no idempotency key on a write" unless method == "GET"
    end
  end

  def test_snake_case_reaches_the_api_on_management_routes_too
    c, t, = client([json(200, {}), json(200, {})])
    c.mailboxes.create(domain_id: "d1", local_part: "support", catch_all: true)
    c.webhooks.create(url: "http://127.0.0.1", events: ["email.opened"], allow_insecure_http: true)
    assert_equal({ "domainId" => "d1", "localPart" => "support", "catchAll" => true }, body(t.calls[0]))
    assert_equal({ "url" => "http://127.0.0.1", "events" => ["email.opened"], "allowInsecureHttp" => true }, body(t.calls[1]))
  end

  def test_version_matches_the_changelog
    changelog = File.read(File.expand_path("../CHANGELOG.md", __dir__))
    assert_includes changelog, "## #{SendClipper::VERSION} "
  end
end
