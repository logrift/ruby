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

    def self.logger(client: nil, level: ::Logger::INFO, on_error: nil, **options)
      client ||= Client.new(**options)
      logger = ActiveSupport::Logger.new(LogDevice.new(client, on_error: on_error), level: level)
      logger.formatter = Formatter.new(service: client.service)
      tagged = ActiveSupport::TaggedLogging.new(logger)
      tagged.formatter.singleton_class.prepend(StructuredTags)
      tagged
    end
  end
end
