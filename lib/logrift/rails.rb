# frozen_string_literal: true

require "logrift"
require "active_support"
require "active_support/logger"
require "active_support/tagged_logging"

module Logrift
  module RailsIntegration
    # Preserve Hash messages and exceptions before TaggedLogging stringifies them.
    module StructuredTags
      def call(severity, time, progname, message)
        format_entry(severity, time, progname, message, tags: current_tags)
      end
    end

    def self.logger(client: nil, level: ::Logger::INFO, on_error: nil,
                    batch: true, batch_size: Batcher::DEFAULT_BATCH_SIZE,
                    flush_interval: Batcher::DEFAULT_FLUSH_INTERVAL,
                    max_buffer: Batcher::DEFAULT_MAX_BUFFER, **options)
      client ||= Client.new(**options)
      device = LogDevice.new(client, on_error: on_error, batch: batch, batch_size: batch_size,
                             flush_interval: flush_interval, max_buffer: max_buffer)
      logger = ActiveSupport::Logger.new(device, level: level)
      logger.formatter = Formatter.new(service: client.service)
      tagged = ActiveSupport::TaggedLogging.new(logger)
      tagged.formatter.singleton_class.prepend(StructuredTags)
      tagged.define_singleton_method(:flush) do
        device.flush
        self
      end
      tagged
    end
  end
end
