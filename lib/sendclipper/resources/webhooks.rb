# frozen_string_literal: true

module SendClipper
  module Resources
    class Webhooks < Base
      attr_reader :dispatches

      def initialize(http)
        super
        @dispatches = WebhookDispatches.new(http)
      end

      def list(**options) = api_get("/webhook-endpoints", options: options)

      # Fields: url, events, allow_insecure_http. The response carries the
      # signing "secret" once: store it.
      def create(params = nil, **kw)
        body, options = split(params, kw)
        api_post("/webhook-endpoints", body, options: options)
      end

      def update(id, params = nil, **kw)
        body, options = split(params, kw)
        api_patch("/webhook-endpoints/#{seg(id)}", body, options: options)
      end

      def remove(id, **options) = api_delete("/webhook-endpoints/#{seg(id)}", options: options)

      # A new secret. The old one keeps signing alongside it for the grace window.
      def rotate_secret(id, **options) = api_post("/webhook-endpoints/#{seg(id)}/rotate-secret", nil, options: options)

      # Recent delivery attempts. Fields: endpoint_id, final_only, limit.
      def deliveries(params = nil, **kw)
        query, options = split(params, kw)
        api_get("/webhook-deliveries", query: query, options: options)
      end

      # Verify a delivery's signature and return the parsed event. Makes no
      # request. Same as SendClipper.verify_webhook.
      def verify(payload, headers, secret, **kw) = SendClipper.verify_webhook(payload, headers, secret, **kw)
    end

    class WebhookDispatches < Base
      # Undelivered events: dead letters by default, or state: "retrying".
      # Fields: state, endpoint_id, cursor, limit.
      def list(params = nil, **kw)
        query, options = split(params, kw)
        api_get("/webhook-dispatches", query: query, options: options)
      end

      def each(params = nil, **kw, &block)
        query, options = split(params, kw)
        query.delete("cursor")
        enum = Paging.cursor("data") { |c| api_get("/webhook-dispatches", query: query.merge("cursor" => c), options: options) }
        block ? enum.each(&block) : enum
      end

      def get(id, **options) = api_get("/webhook-dispatches/#{seg(id)}", options: options)

      # One more immediate attempt for a dead-lettered event.
      def replay(id, **options) = api_post("/webhook-dispatches/#{seg(id)}/replay", nil, options: options)

      # Replay every dead letter (optionally of one endpoint), up to the server's cap.
      def replay_all(params = nil, **kw)
        body, options = split(params, kw)
        api_post("/webhook-dispatches/replay-all", body, options: options)
      end
    end
  end
end
