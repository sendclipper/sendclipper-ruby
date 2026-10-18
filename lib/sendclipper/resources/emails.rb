# frozen_string_literal: true

module SendClipper
  module Resources
    class Emails < Base
      # Send one message. Returns once SendClipper accepted it (status +queued+);
      # delivery is reported later through #get and webhooks.
      #
      #   client.emails.send(from: "hello@send.acme.io", to: "ada@lumen.io", subject: "Hi", html: "<p>Hi</p>")
      #
      # Every call carries an Idempotency-Key, so the SDK's own retries never
      # send twice. Pass +idempotency_key:+ to make YOUR retries safe too.
      #
      # +reply_to:+ is one address or a list of up to 10. +attachments:+ is a
      # list of { filename:, content:, content_type: }, where +content:+ is the
      # file's raw bytes (File.binread("invoice.pdf")) and the SDK base64-encodes
      # it; pass +content_base64:+ instead when you already hold base64.
      def send(params = nil, **kw)
        body, options = split(params, kw)
        api_post("/emails", email_fields(body), options: options)
      end

      # Same as client.batch.send.
      def send_batch(emails, **options) = Batch.post(@http, emails, options)

      # One message with its body and event timeline.
      def get(id, **options) = api_get("/emails/#{seg(id)}", options: options)

      # One page of the sent-mail log, newest first. Fields: search, status,
      # domain, broadcast_id, from, to, page, page_size.
      def list(params = nil, **kw)
        query, options = split(params, kw)
        get_list("/emails", query, options)
      end

      # Every message matching the fields, page after page (an Enumerator).
      def each(params = nil, **kw, &block)
        query, options = split(params, kw)
        size = (query["pageSize"] || 100).to_i
        stop = ->(res, page, page_size, items) { items.length < page_size || page * page_size >= res["total"].to_i }
        enum = Paging.numbered(size, "items", stop) do |page, page_size|
          get_list("/emails", query.merge("page" => page, "pageSize" => page_size), options)
        end
        block ? enum.each(&block) : enum
      end

      # Counts per status.
      def stats(**options) = get_list("/emails/stats/summary", nil, options)

      private

      def get_list(path, query, options) = @http.call("GET", path, query: query, options: options)
    end

    class Batch < Base
      # Up to 500 messages in one request (one recipient each). Every item is
      # accepted or refused on its own; a refused item costs its siblings nothing.
      # An item takes +reply_to:+; an item with +attachments:+ is refused
      # (+attachments_not_batchable+), so send those messages on their own.
      def send(emails, **options) = self.class.post(@http, emails, options)

      # @api private
      def self.post(http, emails, options)
        fields = new(http)
        items = emails.map { |e| fields.__send__(:email_fields, e.to_h) }
        http.call("POST", "/emails/batch", body: { "emails" => items }, options: options)
      end
    end
  end
end
