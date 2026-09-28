# frozen_string_literal: true

require "logger"

module Logrift
  class Formatter < ::Logger::Formatter
    def initialize(service: nil)
      @service = service
    end

    def call(severity, time, progname, message)
      format_entry(severity, time, progname, message)
    end

    def format_entry(severity, time, progname, message, tags: [])
      attrs = {}
      case message
      when Hash
        attrs = message.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
        message = attrs.delete("message") || attrs.delete("msg") || ""
      when Exception
        attrs = { "exception" => message.class.name, "backtrace" => message.backtrace }
        message = message.message
      end
      attrs["progname"] = progname if progname
      attrs["tags"] = tags.map(&:to_s) unless tags.empty?
      level = severity == "ANY" ? "info" : severity.downcase
      JSON.generate(time: time.getutc.iso8601(6), level: level,
                    service: @service, message: message.to_s, attrs: attrs) + "\n"
    end
  end

  # Logger's log device catches write errors, so fail-open handling belongs here.
  class LogDevice
    attr_reader :last_error

    def initialize(client, on_error: nil)
      @client = client
      @on_error = on_error || ->(error) { $stderr.puts("logrift: #{error.message}") }
    end

    def write(json)
      @client.deliver(json)
      @last_error = nil
      json.bytesize
    rescue Error => error
      @last_error = error
      begin
        @on_error.call(error)
      rescue StandardError
        $stderr.puts("logrift: error handler failed")
      end
      0
    end

    def close; end
    def flush; end
  end

  class Logger < ::Logger
    attr_reader :client

    def initialize(client: nil, level: ::Logger::INFO, on_error: nil, **options)
      @client = client || Client.new(**options)
      super(LogDevice.new(@client, on_error: on_error), level: level)
      self.formatter = Formatter.new(service: @client.service)
    end
  end
end
