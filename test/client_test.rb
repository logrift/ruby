# frozen_string_literal: true

require "test_helper"

class ClientTest < Minitest::Test
  include HTTPFixture

  def test_single_entry_authentication_and_proxy_prefix
    with_server do |url, requests|
      client = Logrift::Client.new(url: "#{url}/logs/", api_key: "lr_secret")
      assert_equal 1, client.ingest(message: "hello", attrs: { status: 200 })
      line, headers, body = requests.pop
      assert_equal "POST /logs/api/logs HTTP/1.1\r\n", line
      assert_equal "Bearer lr_secret", headers["authorization"]
      assert_equal "application/json", headers["content-type"]
      assert_equal "logrift-ruby/0.1.0", headers["user-agent"]
      assert_equal [{ "message" => "hello", "attrs" => { "status" => 200 } }], body
      refute_includes client.inspect, "lr_secret"
    end
  end

  def test_batch
    with_server do |url, requests|
      client = Logrift::Client.new(url: url, api_key: "key")
      assert_equal 2, client.ingest([{ msg: "one" }, { msg: "two" }])
      assert_equal 2, requests.pop.last.length
    end
  end

  def test_log_builds_canonical_record
    with_server do |url, requests|
      client = Logrift::Client.new(url: url, api_key: "key", service: "api")
      client.log("boom", level: :error, time: Time.utc(2026, 9, 28), status: 500)
      entry = requests.pop.last.first
      assert_equal "2026-09-28T00:00:00.000000Z", entry["time"]
      assert_equal "error", entry["level"]
      assert_equal "api", entry["service"]
      assert_equal "boom", entry["message"]
      assert_equal({ "status" => 500 }, entry["attrs"])
    end
  end

  def test_empty_batch_and_invalid_payloads
    client = Logrift::Client.new(url: "http://127.0.0.1:1", api_key: "key")
    assert_equal 0, client.ingest([])
    [nil, "text", [nil], [{}, "bad"]].each do |payload|
      assert_raises(ArgumentError) { client.ingest(payload) }
    end
  end

  def test_invalid_configuration
    ["file:///tmp/logs", "http://user:secret@example.org", "http://example.org?q=x", "http://example.org#x", "bad"].each do |url|
      assert_raises(ArgumentError) { Logrift::Client.new(url: url, api_key: "key") }
    end
    [nil, " ", "key\n"].each do |key|
      assert_raises(ArgumentError) { Logrift::Client.new(url: "http://localhost", api_key: key) }
    end
    [0, -1, Float::INFINITY].each do |timeout|
      assert_raises(ArgumentError) { Logrift::Client.new(url: "http://localhost", api_key: "key", read_timeout: timeout) }
    end
  end

  def test_http_errors_include_status
    [401, 413, 500, 302].each do |status|
      with_server(status: status) do |url, _requests|
        client = Logrift::Client.new(url: url, api_key: "key")
        error = assert_raises(Logrift::HTTPError) { client.ingest(msg: "hi") }
        assert_equal status, error.status
      end
    end
  end

  def test_timeout
    with_server(delay: 0.2) do |url, _requests|
      client = Logrift::Client.new(url: url, api_key: "secret", read_timeout: 0.02)
      error = assert_raises(Logrift::TransportError) { client.ingest(msg: "hi") }
      refute_includes error.message, "secret"
      assert_nil error.cause
    end
  end

  def test_connection_refused
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    client = Logrift::Client.new(url: "http://127.0.0.1:#{port}", api_key: "key")
    assert_raises(Logrift::TransportError) { client.ingest(msg: "hi") }
  end
end
