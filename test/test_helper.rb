# frozen_string_literal: true

require "minitest/autorun"
require "socket"
require "logrift"

class RecordingClient
  attr_reader :entries, :service

  def initialize
    @entries = []
    @service = "test-app"
  end

  def deliver(json)
    @entries << JSON.parse(json)
    true
  end
end

module HTTPFixture
  def with_server(status: 202, delay: 0)
    server = TCPServer.new("127.0.0.1", 0)
    requests = Queue.new
    worker = Thread.new do
      socket = server.accept
      headers = {}
      first_line = socket.gets
      while (line = socket.gets) && line != "\r\n"
        name, value = line.split(":", 2)
        headers[name.downcase] = value.strip
      end
      body = socket.read(headers.fetch("content-length").to_i)
      requests << [first_line, headers, JSON.parse(body)]
      sleep delay
      socket.write("HTTP/1.1 #{status} Response\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
    rescue IOError, SystemCallError
      # A timeout test may close its socket before the fixture responds.
    ensure
      socket&.close
    end
    yield "http://127.0.0.1:#{server.addr[1]}", requests
  ensure
    server&.close
    worker&.kill
    worker&.join
  end
end
