# frozen_string_literal: true

require "json"
require "net/http"
require "time"
require "uri"

module Logrift
  class Error < StandardError; end
  class TransportError < Error; end
  class HTTPError < Error
    attr_reader :status

    def initialize(status)
      @status = status
      super("Logrift rejected logs (HTTP #{status})")
    end
  end

  class Client
    attr_reader :service

    def initialize(url:, api_key:, service: nil, open_timeout: 1, read_timeout: 2, write_timeout: 2)
      @endpoint = URI.parse(url.to_s)
      unless %w[http https].include?(@endpoint.scheme) && @endpoint.host &&
             !@endpoint.userinfo && !@endpoint.query && !@endpoint.fragment
        raise ArgumentError, "url must be an HTTP(S) base URL without credentials, query or fragment"
      end
      @endpoint.path = "#{@endpoint.path.sub(%r{/+\z}, '')}/api/logs"
      @api_key = api_key.to_s
      raise ArgumentError, "api_key must be present and contain no newlines" if @api_key.strip.empty? || @api_key.match?(/[\r\n]/)

      @service = service
      @timeouts = [open_timeout, read_timeout, write_timeout].map do |value|
        number = Float(value)
        raise ArgumentError, "timeouts must be finite and positive" unless number.finite? && number.positive?
        number
      end
    rescue URI::InvalidURIError
      raise ArgumentError, "url must be a valid HTTP(S) base URL"
    end

    # Returns the number of entries accepted. Entries use Logrift's native schema.
    def ingest(entries)
      batch = entries.is_a?(Hash) ? [entries] : entries
      unless batch.is_a?(Array) && batch.all? { |entry| entry.is_a?(Hash) }
        raise ArgumentError, "entries must be a Hash or an Array of Hashes"
      end
      return 0 if batch.empty?

      deliver(JSON.generate(batch))
      batch.length
    end

    def log(message, level: :info, time: Time.now, **attrs)
      ingest({ time: time.getutc.iso8601(6), level: level.to_s.downcase,
               service: service, message: message.to_s, attrs: attrs })
    end

    # A fresh connection per delivery keeps the client safe across threads and forks.
    def deliver(json)
      request = Net::HTTP::Post.new(@endpoint.request_uri)
      request["Authorization"] = "Bearer #{@api_key}"
      request["Content-Type"] = "application/json"
      request["User-Agent"] = "logrift-ruby/#{VERSION}"
      request.body = json
      http = Net::HTTP.new(@endpoint.host, @endpoint.port, nil)
      http.use_ssl = @endpoint.scheme == "https"
      http.open_timeout, http.read_timeout, http.write_timeout = @timeouts
      http.max_retries = 0
      response = http.start { |connection| connection.request(request) }
      raise HTTPError, response.code.to_i unless response.is_a?(Net::HTTPSuccess)
      true
    rescue Timeout::Error, SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse => error
      # Do not expose endpoints, credentials, response bodies or request data.
      raise TransportError, "Logrift delivery failed (#{error.class})", cause: nil
    end

    def inspect
      "#<#{self.class} service=#{service.inspect}>"
    end
  end
end
