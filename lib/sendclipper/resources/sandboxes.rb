# frozen_string_literal: true

require "time"

module SendClipper
  module Resources
    class Sandboxes < Base
      attr_reader :messages

      def initialize(http)
        super
        @messages = SandboxMessages.new(http)
      end

      def list(**options) = api_get("/sandboxes", options: options)

      def get(id, **options) = api_get("/sandboxes/#{seg(id)}", options: options)

      # Fields: name, project_label, color (#rrggbb).
      def create(params = nil, **kw)
        body, options = split(params, kw)
        api_post("/sandboxes", body, options: options)
      end

      # Renaming never changes the address or the credentials.
      def update(id, params = nil, **kw)
        body, options = split(params, kw)
        api_patch("/sandboxes/#{seg(id)}", body, options: options)
      end

      # Deletes the sandbox and every message in it.
      def remove(id, **options) = api_delete("/sandboxes/#{seg(id)}", options: options)

      # SMTP host, port, username and password to point a project at.
      def credentials(id, **options) = api_get("/sandboxes/#{seg(id)}/credentials", options: options)

      # Replace BOTH the SMTP password and the +sc_sbx_+ token. The token is shown only here.
      def reset_credentials(id, **options) = api_post("/sandboxes/#{seg(id)}/credentials", nil, options: options)

      # Send to a sandbox through its JSON door, with the sandbox's own
      # +sc_sbx_...+ token. Same fields as emails.send (reply_to and attachments
      # included); nothing is delivered.
      def send(sandbox_token, params = nil, **kw)
        body, options = split(params, kw)
        api_post("/sandbox/emails", email_fields(body), options: options, bearer: sandbox_token)
      end
    end

    class SandboxMessages < Base
      # Fields: search, limit.
      def list(sandbox_id, params = nil, **kw)
        query, options = split(params, kw)
        api_get("/sandboxes/#{seg(sandbox_id)}/messages", query: query, options: options)
      end

      def get(sandbox_id, message_id, **options) = api_get("/sandboxes/#{seg(sandbox_id)}/messages/#{seg(message_id)}", options: options)

      # The message's raw MIME source.
      def raw(sandbox_id, message_id, **options)
        @http.call("GET", "/sandboxes/#{seg(sandbox_id)}/messages/#{seg(message_id)}/raw", as: :text, options: options)
      end

      def remove(sandbox_id, message_id, **options) = api_delete("/sandboxes/#{seg(sandbox_id)}/messages/#{seg(message_id)}", options: options)

      # Empty the sandbox. { "deleted" => n }.
      def clear(sandbox_id, **options) = api_delete("/sandboxes/#{seg(sandbox_id)}/messages", options: options)

      # { "updated" => n }.
      def mark_all_read(sandbox_id, **options) = api_post("/sandboxes/#{seg(sandbox_id)}/read-all", nil, options: options)

      # Poll until a message arrives that the block accepts (default: any
      # message trapped after this call started). Handy in end-to-end tests.
      # +timeout:+ and +interval:+ are seconds; on timeout +error.name+ is "timeout".
      #
      #   msg, error = client.sandboxes.messages.wait_for(box["id"]) { |m| m["subject"] == "Hi" }
      def wait_for(sandbox_id, timeout: 30, interval: 1, &match)
        started = Time.now
        deadline = started + timeout
        match ||= lambda do |m|
          Time.iso8601(m["trappedAt"].to_s) >= started - 1
        rescue ArgumentError
          false
        end
        loop do
          page = list(sandbox_id, limit: 50)
          return page unless page.ok?

          found = (page.data || []).find { |m| match.call(m) }
          return get(sandbox_id, found["id"]) if found

          if Time.now >= deadline
            return Result.new(nil, ErrorResponse.new(name: "timeout", status_code: nil,
                                                     message: "No matching message reached sandbox #{sandbox_id} within #{timeout} s."), nil)
          end
          sleep(interval) if interval.positive?
        end
      end
    end
  end
end
