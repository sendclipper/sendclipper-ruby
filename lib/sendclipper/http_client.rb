# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "securerandom"
require "time"
require "uri"

module SendClipper
  # One request as a transport receives it. +timeout+ is in seconds.
  TransportRequest = Struct.new(:method, :url, :headers, :body, :timeout, keyword_init: true)

  # One response as a transport returns it. Header names are lower-case.
  TransportResponse = Struct.new(:status, :headers, :body, keyword_init: true)

  # Raised by a transport when no answer arrived. +timed_out+ marks a timeout.
  class TransportError < StandardError
    attr_reader :timed_out

    def initialize(message, timed_out: false)
      super(message)
      @timed_out = timed_out
    end
  end

  # The default transport: Net::HTTP from the standard library. Redirects
  # are not followed. Anything that responds to +call(TransportRequest)+ and
  # returns a TransportResponse can replace it.
  class NetHttpTransport
    def call(req)
      uri = URI(req.url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = [req.timeout, 10].min
      http.read_timeout = req.timeout
      http.write_timeout = req.timeout
      klass = Net::HTTP.const_get(req.method.capitalize)
      request = klass.new(uri.request_uri)
      req.headers.each { |k, v| request[k] = v }
      request.body = req.body if req.body
      response = http.request(request)
      headers = {}
      response.each_header { |k, v| headers[k.downcase] = v }
      TransportResponse.new(status: response.code.to_i, headers: headers, body: response.body.to_s)
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout => e
      raise TransportError.new(e.message, timed_out: true)
    rescue SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError, EOFError, Net::ProtocolError => e
      raise TransportError, "#{e.class}: #{e.message}"
    end
  end

  # @api private Reach the API through SendClipper::Client's resources.
  class HttpClient
    DEFAULT_BASE_URL = "https://sendclipper.com"
    RETRYABLE_STATUS = [408, 429, 500, 502, 503, 504].freeze
    MAX_RETRY_AFTER = 60.0
    OPTION_KEYS = %i[idempotency_key timeout max_retries headers].freeze

    attr_reader :base_url

    def initialize(api_key: nil, base_url: nil, timeout: 30, max_retries: 2, default_headers: {}, transport: nil, sleeper: nil)
      @api_key = api_key || ENV["SENDCLIPPER_API_KEY"]
      @api_key = nil if @api_key == ""
      raw = base_url || ENV.fetch("SENDCLIPPER_BASE_URL", nil)
      raw = DEFAULT_BASE_URL if raw.nil? || raw.empty?
      @base_url = raw.sub(%r{/+\z}, "").sub(%r{/v1\z}, "")
      @timeout = timeout.to_f
      @max_retries = [max_retries.to_i, 0].max
      @default_headers = default_headers.to_h.transform_keys(&:to_s)
      @transport = transport || NetHttpTransport.new
      @sleeper = sleeper || ->(seconds) { sleep(seconds) if seconds.positive? }
    end

    # The public face of every API method: never raises for an API refusal
    # or a network failure, it answers a Result.
    def call(method, path, query: nil, body: nil, form: nil, as: :json, bearer: nil, options: {})
      data, headers = request(method, path, query: query, body: body, form: form, as: as, bearer: bearer, options: options)
      Result.new(data, nil, headers)
    rescue ApiError => e
      Result.new(nil, ErrorResponse.new(name: e.code, message: e.message, status_code: e.status, detail: e.detail),
                 e.headers.empty? ? nil : e.headers)
    rescue ConnectionError => e
      Result.new(nil, ErrorResponse.new(name: "network_error", message: e.message, status_code: nil), nil)
    end

    # Like #call, but raises SendClipper::ApiError / SendClipper::ConnectionError.
    def request(method, path, query: nil, body: nil, form: nil, as: :json, bearer: nil, options: {})
      unknown = options.keys - OPTION_KEYS
      raise ArgumentError, "Unknown request option #{unknown.first.inspect}. Allowed: #{OPTION_KEYS.join(", ")}." if unknown.any?

      token = bearer || @api_key
      if token.nil? || token.empty?
        raise ApiError.new(401, "api_key_missing",
                           'No SendClipper API key. Pass one to SendClipper::Client.new("sc_live_...") or set SENDCLIPPER_API_KEY.')
      end

      url = "#{@base_url}/v1#{path.start_with?("/") ? path : "/#{path}"}"
      pairs = (query || {}).filter_map do |k, v|
        next if v.nil? || v == ""

        # true/false are written the way the API reads them.
        "#{escape(k.to_s)}=#{escape(v.to_s)}"
      end
      url += "?#{pairs.join("&")}" unless pairs.empty?

      headers = {
        "Authorization" => "Bearer #{token}",
        "Accept" => as == :json ? "application/json" : "*/*",
        "User-Agent" => "sendclipper-ruby/#{VERSION}"
      }.merge(@default_headers).merge((options[:headers] || {}).transform_keys(&:to_s))

      payload = nil
      if form
        payload, headers["Content-Type"] = form
      elsif !body.nil?
        headers["Content-Type"] = "application/json"
        payload = JSON.generate(body.empty? ? {} : body)
      end

      read = %w[GET HEAD].include?(method)
      key = options[:idempotency_key]
      # The API de-duplicates every JSON mutation on this header for 24 hours.
      # A multipart body is not fingerprinted server-side, so it gets no key
      # and is never retried.
      if !read && form.nil?
        headers["Idempotency-Key"] = key.to_s.empty? ? "sc-ruby-#{SecureRandom.uuid}" : key.to_s
      elsif !key.to_s.empty?
        headers["Idempotency-Key"] = key.to_s
      end
      retries = read || headers.key?("Idempotency-Key") ? [(options[:max_retries] || @max_retries).to_i, 0].max : 0
      timeout = (options[:timeout] || @timeout).to_f

      attempt = 0
      loop do
        begin
          res = @transport.call(TransportRequest.new(method: method, url: url, headers: headers, body: payload, timeout: timeout))
        rescue TransportError => e
          if attempt < retries
            @sleeper.call(self.class.backoff(attempt))
            attempt += 1
            next
          end
          message = if e.timed_out
                      "SendClipper did not answer within #{format_seconds(timeout)} s (#{method} #{URI(url).path})."
                    else
                      "Could not reach SendClipper at #{@base_url}: #{e.message}"
                    end
          raise ConnectionError, message
        end

        res_headers = (res.headers || {}).transform_keys { |k| k.to_s.downcase }
        ok = res.status >= 200 && res.status < 300

        if !ok && RETRYABLE_STATUS.include?(res.status) && attempt < retries
          @sleeper.call(retry_after(res_headers) || self.class.backoff(attempt))
          attempt += 1
          next
        end

        unless ok
          err = ApiError.from_response(res.status, res.body.to_s, res_headers)
          # Our own earlier attempt is still running server-side (a timeout
          # that was not a failure). Its result is replayed once it finishes.
          if err.code == "idempotency_key_in_flight" && attempt < retries
            @sleeper.call(retry_after(res_headers) || self.class.backoff(attempt))
            attempt += 1
            next
          end
          raise err
        end

        return [parse(res, res_headers, as), res_headers]
      end
    end

    def self.backoff(attempt)
      base = [8.0, 0.5 * (2**attempt)].min
      (base / 2) + (rand * (base / 2))
    end

    # +multipart/form-data+: fields are [name, value], files [name, filename, type, bytes].
    def self.multipart(fields, files)
      boundary = "----sendclipper#{SecureRandom.hex(12)}"
      q = ->(s) { s.to_s.gsub("\\", "\\\\\\\\").gsub('"', '\\"').tr("\r\n", "  ") }
      out = +"".b
      fields.each do |name, value|
        out << "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{q.call(name)}\"\r\n\r\n".b << value.to_s.b << "\r\n".b
      end
      files.each do |name, filename, type, bytes|
        out << "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{q.call(name)}\"; filename=\"#{q.call(filename)}\"\r\n".b
        out << "Content-Type: #{type}\r\n\r\n".b << bytes.to_s.b << "\r\n".b
      end
      out << "--#{boundary}--\r\n".b
      [out, "multipart/form-data; boundary=#{boundary}"]
    end

    # Percent-encode one path segment.
    def self.seg(value) = escape(value.to_s)

    def self.escape(s) = s.b.gsub(/[^A-Za-z0-9\-._~]/n) { |c| format("%%%02X", c.ord) }

    private

    def escape(s) = self.class.escape(s)

    def parse(res, headers, as)
      body = res.body.to_s
      case as
      when :bytes
        DownloadedFile.new(content: body.b, content_type: headers["content-type"], filename: filename_of(headers["content-disposition"]))
      when :text
        text(body, headers)
      else
        return nil if body.strip.empty?

        begin
          JSON.parse(text(body, headers))
        rescue JSON::ParserError
          text(body, headers)
        end
      end
    end

    def text(body, headers)
      charset = headers["content-type"].to_s[/charset=([\w-]+)/i, 1] || "UTF-8"
      body.dup.force_encoding(charset).encode("UTF-8", invalid: :replace, undef: :replace)
    rescue ArgumentError, Encoding::ConverterNotFoundError
      body.dup.force_encoding("UTF-8").scrub
    end

    def retry_after(headers)
      raw = headers["retry-after"]
      return nil if raw.nil? || raw.empty?

      if raw.match?(/\A\d+(\.\d+)?\z/)
        [raw.to_f, MAX_RETRY_AFTER].min
      else
        at = Time.httpdate(raw)
        [[at - Time.now, 0.0].max, MAX_RETRY_AFTER].min
      end
    rescue ArgumentError
      nil
    end

    def filename_of(disposition)
      return nil if disposition.nil? || disposition.empty?

      if (m = disposition.match(/filename\*\s*=\s*(?:UTF-8'')?([^;]+)/i))
        decoded = m[1].strip.delete('"').gsub(/%([0-9A-Fa-f]{2})/) { Regexp.last_match(1).hex.chr }.force_encoding("UTF-8")
        return decoded if decoded.valid_encoding?
      end
      m = disposition.match(/filename\s*=\s*"?([^";]+)"?/i)
      m && m[1].strip
    end

    def format_seconds(s) = s == s.to_i ? s.to_i.to_s : s.to_s
  end
end
