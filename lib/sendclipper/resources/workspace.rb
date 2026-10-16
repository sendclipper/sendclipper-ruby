# frozen_string_literal: true

module SendClipper
  module Resources
    class Workspace < Base
      # The workspace this key belongs to.
      def get(**options) = api_get("/workspace", options: options)
    end

    class ApiKeys < Base
      # The workspace's keys, masked. Keys are created and revoked in the dashboard only.
      def list(**options) = api_get("/api-keys", options: options)
    end

    class Automations < Base
      # Start a Live automation with a +manual+ trigger for one contact.
      def enroll(automation_id, email, **options)
        api_post("/automations/#{seg(automation_id)}/enrollments", { "email" => email }, options: options)
      end
    end
  end
end
