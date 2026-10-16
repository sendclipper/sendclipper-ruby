# frozen_string_literal: true

require "json"

module SendClipper
  # Base class for everything this SDK raises on purpose.
  class Error < StandardError; end

  # The API answered with a non-2xx status. +code+ is the API's own
  # machine-readable reason (+domain_not_verified+, +template_variables_missing+,
  # +rate_limited+, ...) and is the field to branch on; the message is a
  # sentence meant for a person.
  class ApiError < Error
    attr_reader :status, :code, :detail, :headers

    def initialize(status, code, message, detail = nil, headers = {})
      super(message)
      @status = status
      @code = code
      @detail = detail
      @headers = headers || {}
    end

    # The API answers refusals in two shapes: the house envelope
    # { error: { code, message, detail? } } and Nest's default
    # { statusCode, message: string | string[], error } (request validation).
    def self.from_response(status, text, headers = {})
      parsed = begin
        JSON.parse(text)
      rescue JSON::ParserError, TypeError
        nil
      end
      obj = parsed.is_a?(Hash) ? parsed : {}

      env = obj["error"]
      return from_envelope(status, env, headers) if env.is_a?(Hash)

      msg = obj["message"]
      return from_envelope(status, msg["error"], headers) if msg.is_a?(Hash) && msg["error"].is_a?(Hash)
      return new(status, "validation_failed", msg.map(&:to_s).join("; "), msg, headers) if msg.is_a?(Array)
      return new(status, code_for_status(status), msg, nil, headers) if msg.is_a?(String)

      snippet = text.to_s.strip[0, 300]
      new(status, code_for_status(status), snippet.empty? ? "HTTP #{status}" : snippet, nil, headers)
    end

    def self.from_envelope(status, env, headers)
      code = env["code"].to_s
      message = env["message"].to_s
      detail = env.key?("detail") ? env["detail"] : env["details"]
      new(status, code.empty? ? code_for_status(status) : code, message.empty? ? "HTTP #{status}" : message, detail, headers)
    end

    def self.code_for_status(status)
      {
        400 => "bad_request", 401 => "unauthorized", 403 => "forbidden", 404 => "not_found",
        409 => "conflict", 413 => "payload_too_large", 429 => "rate_limited"
      }.fetch(status, "http_#{status}")
    end
    private_class_method :from_envelope
  end

  # The request never got an answer: DNS, TLS, a reset socket or the timeout.
  class ConnectionError < Error; end

  # SendClipper.verify_webhook refused a delivery. +reason+ says which check
  # failed: +missing_header+, +malformed_header+, +timestamp_out_of_tolerance+,
  # +signature_mismatch+ or +invalid_payload+.
  class WebhookVerificationError < Error
    attr_reader :reason

    def initialize(reason, message)
      super(message)
      @reason = reason
    end
  end
end
