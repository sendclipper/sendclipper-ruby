# frozen_string_literal: true

require "test_helper"

class WebhookTest < Minitest::Test
  SECRET = "whsec_test_secret"
  T = 1_756_800_000
  BODY = '{"id":"evt_1","event":"email.delivered","createdAt":"2026-09-06T09:41:02.518Z",' \
         '"data":{"emailId":"e1","messageId":"m1","to":"user@acme.io","domain":"send.acme.io","subject":"Your receipt"}}'
  # Computed with `openssl dgst -sha256 -hmac`, not with this SDK (the Node SDK's vector).
  SIG = "76921f5ba77ae7f38686e8f147da3903c0ff87100cbd47ee466b7d646d198192"
  HEADER = "t=#{T},v1=#{SIG}".freeze

  def refused(reason)
    err = assert_raises(SendClipper::WebhookVerificationError) { yield }
    assert_equal reason, err.reason
  end

  def verify(payload = BODY, headers = HEADER, secret = SECRET, **kw)
    SendClipper.verify_webhook(payload, headers, secret, now: Time.at(T), **kw)
  end

  def test_a_genuine_delivery_verifies_and_returns_the_parsed_event
    event = SendClipper.verify_webhook(BODY, HEADER, SECRET, now: Time.at(T + 10))
    assert_equal "evt_1", event["id"]
    assert_equal "email.delivered", event["event"]
    assert_equal "user@acme.io", event["data"]["to"]
  end

  def test_header_lookup_works_for_rails_rack_and_plain_hashes_and_binary_bodies
    rack_env = { "HTTP_X_SENDCLIPPER_SIGNATURE_V2" => HEADER, "CONTENT_TYPE" => "application/json" }
    [rack_env, { "X-SendClipper-Signature-V2" => HEADER }, { "x-sendclipper-signature-v2" => [HEADER] }].each do |headers|
      assert_equal "evt_1", verify(BODY.b, headers)["id"]
    end
  end

  def test_during_a_rotation_two_v1_values_are_sent_and_either_one_is_accepted
    other = "a" * 64
    ["t=#{T},v1=#{other},v1=#{SIG}", "t=#{T},v1=#{SIG},v1=#{other}"].each do |header|
      assert_equal "evt_1", verify(BODY, header)["id"]
    end
  end

  def test_a_changed_body_a_wrong_secret_or_a_wrong_signature_is_refused
    refused("signature_mismatch") { verify(BODY.sub("user@", "evil@")) }
    refused("signature_mismatch") { verify(BODY, HEADER, "whsec_other") }
    refused("signature_mismatch") { verify(BODY, "t=#{T},v1=#{"0" * 64}") }
    refused("signature_mismatch") { verify(BODY, "t=#{T},v1=abc") }
  end

  def test_re_encoded_json_fails_because_the_signature_covers_the_raw_bytes
    refused("signature_mismatch") { verify(JSON.pretty_generate(JSON.parse(BODY))) }
  end

  def test_a_parsed_hash_instead_of_the_raw_body_is_refused_with_a_pointer
    err = assert_raises(SendClipper::WebhookVerificationError) { verify(JSON.parse(BODY)) }
    assert_equal "invalid_payload", err.reason
    assert_includes err.message, "raw_post"
  end

  def test_a_timestamp_outside_the_tolerance_is_refused
    refused("timestamp_out_of_tolerance") { SendClipper.verify_webhook(BODY, HEADER, SECRET, now: Time.at(T + 301)) }
    refused("timestamp_out_of_tolerance") { SendClipper.verify_webhook(BODY, HEADER, SECRET, now: Time.at(T - 301)) }
    assert_equal "evt_1", SendClipper.verify_webhook(BODY, HEADER, SECRET, now: Time.at(T + 3600), tolerance: 3600)["id"]
  end

  def test_a_missing_or_malformed_header_is_refused
    refused("missing_header") { verify(BODY, {}) }
    refused("missing_header") { verify(BODY, HEADER, "") }
    refused("malformed_header") { verify(BODY, "v1=#{SIG}") }
    refused("malformed_header") { verify(BODY, "t=#{T}") }
    refused("malformed_header") { verify(BODY, "t=abc,v1=#{SIG}") }
  end

  def test_a_signed_body_that_is_not_json_is_refused
    refused("invalid_payload") { verify("not json", SendClipper.webhook_signature_header(SECRET, "not json", T)) }
  end

  def test_webhook_signature_header_builds_what_verify_accepts
    header = SendClipper.webhook_signature_header(SECRET, BODY, T)
    assert_equal HEADER, header
    assert_equal [T, [SIG]], SendClipper.parse_signature_header(header)
  end

  def test_the_clients_webhooks_verify_is_the_same_check_and_makes_no_request
    c = SendClipper::Client.new("k", transport: ->(_) { raise "no request expected" })
    assert_equal "evt_1", c.webhooks.verify(BODY, HEADER, SECRET, now: Time.at(T))["id"]
  end
end
