# frozen_string_literal: true

require "test_helper"
require "socket"

# The default transport against a real local socket server.
class NetHttpTest < Minitest::Test
  def setup
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @seen = Queue.new
    @thread = Thread.new { serve }
  end

  def teardown
    @thread.kill
    @server.close
  end

  def serve
    loop do
      sock = @server.accept
      Thread.new(sock) { |s| handle(s) }
    end
  rescue IOError
    nil
  end

  def handle(sock)
    request_line = sock.gets.to_s
    headers = {}
    while (line = sock.gets) && line != "\r\n"
      k, v = line.split(":", 2)
      headers[k.strip.downcase] = v.to_s.strip
    end
    body = headers["content-length"] ? sock.read(headers["content-length"].to_i) : ""
    method, target = request_line.split(" ")
    @seen << { method: method, target: target, headers: headers, body: body }
    sleep 2 if target.start_with?("/v1/slow")
    status = target.start_with?("/v1/refuse") ? "422 Unprocessable Entity" : "200 OK"
    payload = JSON.generate({ "echo" => target })
    sock.write "HTTP/1.1 #{status}\r\nContent-Type: application/json\r\nX-Echo: yes\r\n" \
               "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}"
  rescue IOError, Errno::EPIPE, Errno::ECONNRESET
    nil
  ensure
    sock.close
  end

  def client(**opts) = SendClipper::Client.new("sc_live_net", base_url: "http://127.0.0.1:#{@port}", **opts)

  def test_it_sends_method_headers_and_body_and_returns_lower_case_headers
    data, error = client.emails.send(from: "a@acme.io", to: "b@lumen.io", subject: "Grüße", html: "h")
    assert_nil error
    assert_equal "/v1/emails", data["echo"]
    seen = @seen.pop
    assert_equal "POST", seen[:method]
    assert_equal "Bearer sc_live_net", seen[:headers]["authorization"]
    assert_match(/\Asc-ruby-/, seen[:headers]["idempotency-key"])
    assert_equal "Grüße", JSON.parse(seen[:body].force_encoding("UTF-8"))["subject"]
  end

  def test_an_error_status_is_a_result_and_headers_are_lower_case
    result = SendClipper::HttpClient.new(api_key: "k", base_url: "http://127.0.0.1:#{@port}").call("POST", "/refuse", body: {})
    assert_equal 422, result.error.status_code
    assert_equal "yes", result.headers["x-echo"]
  end

  def test_a_timeout_is_reported_as_one
    slow = SendClipper::HttpClient.new(api_key: "k", base_url: "http://127.0.0.1:#{@port}", timeout: 0.3, max_retries: 0).call("GET", "/slow")
    assert_equal "network_error", slow.error.name
    assert_includes slow.error.message, "did not answer within 0.3 s"
  end

  def test_nothing_listening_is_a_connection_error_not_a_timeout
    _, error = SendClipper::Client.new("k", base_url: "http://127.0.0.1:9", max_retries: 0).domains.list
    assert_equal "network_error", error.name
    assert_includes error.message, "Could not reach SendClipper"
  end
end
