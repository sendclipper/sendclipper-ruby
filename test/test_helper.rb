# frozen_string_literal: true

require "json"
require "uri"
require "minitest/autorun"
require "sendclipper"

# Records each call and answers from a queue.
class FakeTransport
  attr_reader :calls

  def initialize(replies)
    @replies = replies.dup
    @calls = []
  end

  def call(req)
    @calls << req
    raise "unexpected request #{req.method} #{req.url}" if @replies.empty?

    nxt = @replies.shift
    raise nxt if nxt.is_a?(Exception)

    nxt.respond_to?(:call) ? nxt.call(req) : nxt
  end
end

module Helpers
  def json(status, body, headers = {})
    SendClipper::TransportResponse.new(
      status: status,
      headers: { "content-type" => "application/json" }.merge(headers.transform_keys(&:downcase)),
      body: body.nil? ? "" : JSON.generate(body)
    )
  end

  def client(replies, **opts)
    transport = FakeTransport.new(replies)
    slept = []
    c = SendClipper::Client.new(opts.delete(:api_key) || "sc_live_test", base_url: "https://api.test",
                                transport: transport, sleeper: ->(s) { slept << s }, **opts)
    [c, transport, slept]
  end

  def path(req) = URI(req.url).path

  def query(req) = URI.decode_www_form(URI(req.url).query.to_s).to_h

  def body(req) = req.body && JSON.parse(req.body)
end
