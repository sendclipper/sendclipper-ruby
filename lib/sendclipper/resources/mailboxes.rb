# frozen_string_literal: true

module SendClipper
  module Resources
    class Mailboxes < Base
      attr_reader :messages

      def initialize(http)
        super
        @messages = MailboxMessages.new(http)
      end

      # Fields: include_archived.
      def list(params = nil, **kw)
        query, options = split(params, kw)
        api_get("/mailboxes", query: query, options: options)
      end

      def get(id, **options) = api_get("/mailboxes/#{seg(id)}", options: options)

      # A new address on a receiving domain. Fields: domain_id, local_part,
      # display_name, color, catch_all.
      def create(params = nil, **kw)
        body, options = split(params, kw)
        api_post("/mailboxes", body, options: options)
      end

      def update(id, params = nil, **kw)
        body, options = split(params, kw)
        api_patch("/mailboxes/#{seg(id)}", body, options: options)
      end

      # Archives the address. Its mail is kept.
      def archive(id, **options) = api_delete("/mailboxes/#{seg(id)}", options: options)
    end

    class MailboxMessages < Base
      # Mail filed under one address. Reading never marks anything read.
      # Fields: folder, search, label, limit, cursor.
      def list(mailbox_id, params = nil, **kw)
        query, options = split(params, kw)
        api_get("/mailboxes/#{seg(mailbox_id)}/messages", query: query, options: options)
      end

      def each(mailbox_id, params = nil, **kw, &block)
        query, options = split(params, kw)
        query.delete("cursor")
        enum = Paging.cursor("items") do |c|
          api_get("/mailboxes/#{seg(mailbox_id)}/messages", query: query.merge("cursor" => c), options: options)
        end
        block ? enum.each(&block) : enum
      end

      def get(mailbox_id, message_id, **options) = api_get("/mailboxes/#{seg(mailbox_id)}/messages/#{seg(message_id)}", options: options)

      # Download one attachment: a DownloadedFile with content, content_type and filename.
      def attachment(mailbox_id, message_id, attachment_id, **options)
        api_get("/mailboxes/#{seg(mailbox_id)}/messages/#{seg(message_id)}/parts/#{seg(attachment_id)}",
                query: { "download" => 1 }, as: :bytes, options: options)
      end
    end
  end
end
