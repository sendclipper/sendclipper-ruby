# frozen_string_literal: true

module SendClipper
  # What an API refusal or a network failure looks like.
  #
  # +name+ is SendClipper's machine-readable code (+domain_not_verified+,
  # +validation_failed+, +rate_limited+, +network_error+, ...), +message+ a
  # sentence for a person, +status_code+ the HTTP status (+nil+ when no
  # answer arrived) and +detail+ any code-specific facts.
  ErrorResponse = Struct.new(:name, :message, :status_code, :detail, keyword_init: true) do
    def to_s = "#{name}: #{message}"
  end

  # Every API method returns one. Exactly one of +data+ and +error+ is set.
  # It destructures to +data, error+:
  #
  #   data, error = client.emails.send(from: "...", to: "...", subject: "Hi", html: "<p>Hi</p>")
  class Result
    attr_reader :data, :error, :headers

    def initialize(data, error, headers)
      @data = data
      @error = error
      # Response headers with lower-case names, or nil when no answer arrived.
      @headers = headers
      freeze
    end

    def ok? = error.nil?

    # +data+, or raise the error as a SendClipper::ApiError.
    def unwrap
      return data if error.nil?

      raise ApiError.new(error.status_code || 0, error.name, error.message, error.detail, headers || {})
    end
    alias value! unwrap

    def to_ary = [data, error]

    def deconstruct = [data, error]

    def deconstruct_keys(_keys) = { data: data, error: error, headers: headers }

    def inspect = error ? "#<SendClipper::Result error=#{error.to_h}>" : "#<SendClipper::Result data=#{data.inspect}>"
  end

  # What a download returns.
  DownloadedFile = Struct.new(:content, :content_type, :filename, keyword_init: true)
end
