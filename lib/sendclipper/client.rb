# frozen_string_literal: true

module SendClipper
  # The SendClipper API client.
  #
  #   client = SendClipper::Client.new("sc_live_...") # or Client.new: reads SENDCLIPPER_API_KEY
  #   data, error = client.emails.send(from: "hello@acme.io", to: "ada@lumen.io", subject: "Hi", html: "<p>Hi</p>")
  class Client
    attr_reader :emails, :batch, :domains, :templates, :sandboxes, :webhooks, :contacts,
                :audiences, :suppressions, :mailboxes, :automations, :workspace, :api_keys

    # +api_key+ defaults to SENDCLIPPER_API_KEY. +base_url:+ defaults to
    # SENDCLIPPER_BASE_URL, then https://sendclipper.com (no /v1). +timeout:+ is
    # per attempt, in seconds. +max_retries:+ is how often a network error, a
    # 429 or a 5xx is retried; a write is only retried with an
    # Idempotency-Key, which the SDK adds to every JSON write, so a retried
    # send can never go out twice. +transport:+ replaces the Net::HTTP sender.
    def initialize(api_key = nil, base_url: nil, timeout: 30, max_retries: 2, default_headers: {}, transport: nil, sleeper: nil)
      @http = HttpClient.new(api_key: api_key, base_url: base_url, timeout: timeout, max_retries: max_retries,
                             default_headers: default_headers, transport: transport, sleeper: sleeper)
      @emails = Resources::Emails.new(@http)
      @batch = Resources::Batch.new(@http)
      @domains = Resources::Domains.new(@http)
      @templates = Resources::Templates.new(@http)
      @sandboxes = Resources::Sandboxes.new(@http)
      @webhooks = Resources::Webhooks.new(@http)
      @contacts = Resources::Contacts.new(@http)
      @audiences = Resources::Audiences.new(@http)
      @suppressions = Resources::Suppressions.new(@http)
      @mailboxes = Resources::Mailboxes.new(@http)
      @automations = Resources::Automations.new(@http)
      @workspace = Resources::Workspace.new(@http)
      @api_keys = Resources::ApiKeys.new(@http)
    end

    # The API origin requests go to, without /v1.
    def base_url = @http.base_url

    def inspect = "#<SendClipper::Client base_url=#{base_url.inspect}>"
  end
end
