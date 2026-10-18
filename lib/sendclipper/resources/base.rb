# frozen_string_literal: true

module SendClipper
  module Resources
    # Every method takes its fields as a Hash or as keyword arguments, and the
    # request options +idempotency_key:+, +timeout:+ (seconds), +max_retries:+
    # and +headers:+ alongside them.
    #
    # Top-level field names may be the API's own (+templateId+) or snake_case
    # (+template_id+); snake_case is turned into the API's camelCase. Values,
    # such as the +variables+ map, are sent exactly as given.
    class Base
      def initialize(http)
        @http = http
      end

      private

      def seg(value) = HttpClient.seg(value)

      # Split keyword arguments into [fields, options].
      def split(params, kw)
        options = kw.slice(*HttpClient::OPTION_KEYS)
        fields = (params || {}).to_h.merge(kw.reject { |k, _| HttpClient::OPTION_KEYS.include?(k) })
        [camelize(fields), options]
      end

      def camelize(fields)
        fields.each_with_object({}) do |(k, v), out|
          next if v.nil?

          out[camel(k)] = v
        end
      end

      def camel(key) = key.to_s.gsub(/_([a-z0-9])/) { Regexp.last_match(1).upcase }

      # The fields of one message (emails.send, sandboxes.send, a batch item):
      # camelized, with each attachment's +content:+ (the file's raw bytes)
      # base64-encoded. +content_base64:+ is content that is already base64,
      # sent as it is.
      def email_fields(fields)
        out = camelize(fields)
        list = out["attachments"]
        out["attachments"] = list.map { |a| attachment_field(a) } if list.is_a?(Array)
        out
      end

      def attachment_field(attachment)
        given = attachment.to_h
        names = given.reject { |_, v| v.nil? }.keys.map(&:to_s)
        if names.include?("content") && (names & %w[content_base64 contentBase64]).any?
          raise ArgumentError, "An attachment takes content: (the file's bytes) or content_base64:, not both"
        end

        given.each_with_object({}) do |(k, v), out|
          next if v.nil?

          case k.to_s
          when "content"
            unless v.is_a?(String)
              raise ArgumentError, "An attachment's content: must be a String of the file's bytes, e.g. File.binread(path)"
            end

            out["content"] = [v].pack("m0")
          when "content_base64", "contentBase64" then out["content"] = v
          else out[camel(k)] = v
          end
        end
      end

      def api_get(path, query: nil, as: :json, options: {})
        @http.call("GET", path, query: query, as: as, options: options)
      end

      def api_post(path, body = {}, options: {}, bearer: nil)
        @http.call("POST", path, body: body, bearer: bearer, options: options)
      end

      def api_patch(path, body, options: {}) = @http.call("PATCH", path, body: body, options: options)

      def api_put(path, body, options: {}) = @http.call("PUT", path, body: body, options: options)

      def api_delete(path, body = nil, options: {}) = @http.call("DELETE", path, body: body, options: options)
    end

    # Iterators over a numbered or a cursor list. They raise ApiError on a
    # refusal, since a loop has no +error+ to hand back.
    module Paging
      module_function

      def numbered(page_size, items_key, stop)
        Enumerator.new do |y|
          page = 1
          loop do
            res = yield(page, page_size).unwrap
            items = res[items_key] || []
            items.each { |item| y << item }
            break if items.empty? || stop.call(res, page, page_size, items)

            page += 1
          end
        end
      end

      def cursor(items_key)
        Enumerator.new do |y|
          cursor = nil
          loop do
            res = yield(cursor).unwrap
            (res[items_key] || []).each { |item| y << item }
            info = res["page"] || {}
            break unless info["hasMore"] && info["cursor"].to_s != ""

            cursor = info["cursor"]
          end
        end
      end
    end
  end
end
