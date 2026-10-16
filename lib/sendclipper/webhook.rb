# frozen_string_literal: true

require "json"
require "openssl"

module SendClipper
  # SendClipper's documented tolerance: five minutes.
  WEBHOOK_TOLERANCE_SECONDS = 300
  SIGNATURE_HEADER = "x-sendclipper-signature-v2"

  module_function

  # Verify a webhook delivery and return its parsed event (a Hash).
  #
  # +payload+ is the body EXACTLY as received (+request.raw_post+ in Rails,
  # +request.body.read+ in Rack/Sinatra), never re-encoded JSON. +headers+ is
  # the request's headers (Rails +request.headers+, a Rack env, a Hash) or the
  # X-SendClipper-Signature-V2 value itself.
  #
  # SendClipper signs "#{timestamp}.#{raw_body}" with HMAC-SHA256 and sends
  # X-SendClipper-Signature-V2: t=<seconds>,v1=<hex>[,v1=<hex>]. During a
  # secret rotation there are two v1= values; any match is accepted.
  #
  # Raises SendClipper::WebhookVerificationError when any check fails.
  def verify_webhook(payload, headers, secret, tolerance: WEBHOOK_TOLERANCE_SECONDS, now: nil)
    raise WebhookVerificationError.new("missing_header", "No webhook signing secret was given.") if secret.to_s.empty?
    unless payload.is_a?(String)
      raise WebhookVerificationError.new("invalid_payload",
                                         "payload must be the raw request body as a String, not parsed JSON. " \
                                         "Use request.raw_post in Rails or request.body.read in Rack.")
    end

    header = signature_header_of(headers)
    raise WebhookVerificationError.new("missing_header", "The request carries no X-SendClipper-Signature-V2 header.") if header.to_s.empty?

    timestamp, signatures = parse_signature_header(header)
    if timestamp.nil? || signatures.empty?
      raise WebhookVerificationError.new("malformed_header", "X-SendClipper-Signature-V2 has no t= or no v1= value.")
    end

    drift = ((now || Time.now).to_i - timestamp).abs
    if drift > tolerance
      raise WebhookVerificationError.new("timestamp_out_of_tolerance",
                                         "The delivery was signed #{drift} s from now, outside the #{tolerance} s tolerance.")
    end

    expected = sign_payload(secret, timestamp, payload)
    # ANY match, and every candidate is compared: a rotation sends two.
    matched = signatures.map { |candidate| secure_compare(expected, candidate) }.any?
    raise WebhookVerificationError.new("signature_mismatch", "The signature does not match this secret and body.") unless matched

    event = begin
      JSON.parse(payload.dup.force_encoding("UTF-8"))
    rescue JSON::ParserError
      nil
    end
    raise WebhookVerificationError.new("invalid_payload", "The signed body is not a JSON object.") unless event.is_a?(Hash)

    event
  end

  # hex(HMAC-SHA256(secret, "#{timestamp}.#{raw_body}")). Exported for tests of your own handler.
  def sign_payload(secret, timestamp, raw_body)
    OpenSSL::HMAC.hexdigest("SHA256", secret.to_s, "#{timestamp}.".b + raw_body.to_s.b)
  end

  # Build a valid header for a body, e.g. to test your endpoint locally.
  def webhook_signature_header(secret, raw_body, timestamp = Time.now.to_i)
    "t=#{timestamp},v1=#{sign_payload(secret, timestamp, raw_body)}"
  end

  # [timestamp, [signatures]] from t=<seconds>,v1=<hex>[,v1=<hex>].
  def parse_signature_header(header)
    timestamp = nil
    signatures = []
    header.to_s.split(",").each do |part|
      key, eq, value = part.partition("=")
      next if eq.empty?

      key = key.strip
      value = value.strip
      if key == "t" && value.match?(/\A[0-9]+\z/)
        timestamp = value.to_i
      elsif key == "v1" && !value.empty?
        signatures << value
      end
    end
    [timestamp, signatures]
  end

  def signature_header_of(source)
    return source if source.is_a?(String)
    return nil if source.nil?

    found = []
    if source.respond_to?(:each_pair) || source.respond_to?(:each)
      source.each do |name, value|
        # Rack spells it HTTP_X_SENDCLIPPER_SIGNATURE_V2.
        normalised = name.to_s.downcase.tr("_", "-")
        next unless [SIGNATURE_HEADER, "http-#{SIGNATURE_HEADER}"].include?(normalised)

        Array(value).each { |v| found << v.to_s }
      end
    end
    found.empty? ? nil : found.join(",")
  end

  def secure_compare(a, b)
    return false unless a.bytesize == b.bytesize

    OpenSSL.fixed_length_secure_compare(a, b)
  end
  private_class_method :signature_header_of, :secure_compare
end
