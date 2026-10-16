# frozen_string_literal: true

require "json"

module SendClipper
  module Resources
    class Contacts < Base
      # Fields: audience_id, status, page, page_size.
      def list(params = nil, **kw)
        query, options = split(params, kw)
        api_get("/contacts", query: query, options: options)
      end

      # Every contact, page after page (an Enumerator).
      def each(params = nil, **kw, &block)
        query, options = split(params, kw)
        size = (query["pageSize"] || 200).to_i
        stop = ->(res, page, _size, _items) { page >= res["totalPages"].to_i }
        enum = Paging.numbered(size, "items", stop) do |page, page_size|
          api_get("/contacts", query: query.merge("page" => page, "pageSize" => page_size), options: options)
        end
        block ? enum.each(&block) : enum
      end

      # Fields: name, email, audience_id, status.
      def create(params = nil, **kw)
        body, options = split(params, kw)
        api_post("/contacts", body, options: options)
      end

      # Import a CSV or vCard file. Importing never suppresses anyone.
      #
      #   client.contacts.import(file: File.read("contacts.csv"), filename: "contacts.csv", on_duplicate: "update")
      #
      # The filename's extension picks the parser. Other fields: audience_id,
      # new_audience, create_audiences, mapping.
      def import(file:, filename: "contacts.csv", **kw)
        fields, options = split(nil, kw)
        @http.call("POST", "/contacts/import", form: import_form(file, filename, fields), options: options)
      end

      # What an import would do, without importing.
      def import_preview(file:, filename: "contacts.csv", **options)
        @http.call("POST", "/contacts/import/preview", form: import_form(file, filename, {}), options: options)
      end

      # Every contact as CSV (re-importable) or vCard 4.0 (format: "vcf").
      def export(params = nil, **kw)
        query, options = split(params, kw)
        @http.call("GET", "/contacts/export", query: query, as: :text, options: options)
      end

      private

      def import_form(file, filename, fields)
        type = filename.to_s.downcase.end_with?(".vcf") ? "text/vcard" : "text/csv"
        parts = fields.filter_map do |k, v|
          next if v.nil? || v == ""

          [k, k == "mapping" ? JSON.generate(v) : v.to_s]
        end
        HttpClient.multipart(parts, [["file", filename.to_s, type, file]])
      end
    end

    class Audiences < Base
      # { "audiences" => [...], "totalContacts" => n }.
      def list(**options) = api_get("/audiences", options: options)
    end

    class Suppressions < Base
      # Fields: q (address search), reason, cursor, limit.
      def list(params = nil, **kw)
        query, options = split(params, kw)
        api_get("/suppressions", query: query, options: options)
      end

      def each(params = nil, **kw, &block)
        query, options = split(params, kw)
        query.delete("cursor")
        enum = Paging.cursor("data") { |c| api_get("/suppressions", query: query.merge("cursor" => c), options: options) }
        block ? enum.each(&block) : enum
      end

      # Stop all mail to an address (reason +manual+). Fields: email, note.
      # "created" is false when the address was already suppressed; "row" is
      # the entry either way.
      def create(params = nil, **kw)
        body, options = split(params, kw)
        api_post("/suppressions", body, options: options)
      end

      # Lift a suppression. +reason+ (10+ characters) is recorded. Complaint and
      # provider suppressions cannot be removed (+suppression_not_removable+).
      def remove(id, reason, **options) = api_delete("/suppressions/#{seg(id)}", { "reason" => reason }, options: options)

      # The list as CSV. Fields: q, reason.
      def export(params = nil, **kw)
        query, options = split(params, kw)
        query = query.reject { |k, _| %w[cursor limit].include?(k) }
        @http.call("GET", "/suppressions/export", query: query, as: :text, options: options)
      end
    end
  end
end
