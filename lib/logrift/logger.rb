# frozen_string_literal: true

require "logger"
require "logrift/batcher"

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
    def initialize(client, on_error: nil, batch: true, batch_size: Batcher::DEFAULT_BATCH_SIZE,
                   flush_interval: Batcher::DEFAULT_FLUSH_INTERVAL, max_buffer: Batcher::DEFAULT_MAX_BUFFER)
      @client = client
      @on_error = on_error || ->(error) { $stderr.puts("logrift: #{error.message}") }
      @last_error = nil
      @batcher = if batch
        Batcher.new(client, on_error: @on_error, batch_size: batch_size,
                    flush_interval: flush_interval, max_buffer: max_buffer)
      end
    end

    def last_error
      @batcher ? @batcher.last_error : @last_error
    end

    def write(json)
      if @batcher
        @batcher.push(json)
      else
        @client.deliver(json)
        @last_error = nil
      end
      json.bytesize
    rescue Error => error
      @last_error = error
      report(error)
      0
    end

    def close
      @batcher&.close
    end

    def flush
      @batcher&.flush
    end

    private

    def report(error)
      @on_error.call(error)
    rescue StandardError
      $stderr.puts("logrift: error handler failed")
    end
  end

  class Logger < ::Logger
    attr_reader :client

    def initialize(client: nil, level: ::Logger::INFO, on_error: nil,
                   batch: true, batch_size: Batcher::DEFAULT_BATCH_SIZE,
                   flush_interval: Batcher::DEFAULT_FLUSH_INTERVAL,
                   max_buffer: Batcher::DEFAULT_MAX_BUFFER, **options)
      @client = client || Client.new(**options)
      @device = LogDevice.new(@client, on_error: on_error, batch: batch, batch_size: batch_size,
                              flush_interval: flush_interval, max_buffer: max_buffer)
      super(@device, level: level)
      self.formatter = Formatter.new(service: @client.service)
    end

    # Delivers buffered entries immediately instead of waiting for the next flush.
    def flush
      @device.flush
      self
    end
  end
end
