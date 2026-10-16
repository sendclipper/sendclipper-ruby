# frozen_string_literal: true

module SendClipper
  module Resources
    class Domains < Base
      def list(**options) = api_get("/domains", options: options)

      # Register a sending domain (name:, region: "us-east-1" | "eu-west-1" | "us-west-2").
      # Next: #records, publish them, then #verify.
      def create(params = nil, **kw)
        body, options = split(params, kw)
        api_post("/domains", body, options: options)
      end

      # The DNS records to publish, each with its current status.
      def records(id, **options) = api_get("/domains/#{seg(id)}/records", options: options)

      # Check DNS now instead of waiting for the background check.
      def verify(id, **options) = api_post("/domains/#{seg(id)}/verify", nil, options: options)

      # Start receiving mail on this domain. Adds receiving records; never blocks sending.
      def enable_receiving(id, **options) = api_post("/domains/#{seg(id)}/receiving", nil, options: options)

      def disable_receiving(id, **options) = api_delete("/domains/#{seg(id)}/receiving", options: options)

      # Move a domain to another region. Refused (+region_immutable+) once it holds messages.
      def set_region(id, region, **options) = api_patch("/domains/#{seg(id)}/region", { "region" => region }, options: options)

      # What deleting the domain would take with it.
      def deletion_preview(id, **options) = api_get("/domains/#{seg(id)}/deletion", options: options)

      def remove(id, **options) = api_delete("/domains/#{seg(id)}", options: options)
    end
  end
end
