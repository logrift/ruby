# frozen_string_literal: true

require "logrift/rails"

module Logrift
  class Railtie < Rails::Railtie
    config.logrift = ActiveSupport::OrderedOptions.new
    config.logrift.enabled = false
    config.logrift.url = ENV["LOGRIFT_URL"]
    config.logrift.api_key = ENV["LOGRIFT_API_KEY"]
    config.logrift.service = ENV["LOGRIFT_SERVICE"]
    config.logrift.open_timeout = 1
    config.logrift.read_timeout = 2
    config.logrift.write_timeout = 2

    initializer "logrift.configure_logger", before: :initialize_logger do |app|
      settings = app.config.logrift
      next unless settings.enabled

      app.config.logger = RailsIntegration.logger(
        url: settings.url, api_key: settings.api_key,
        service: settings.service || app.class.module_parent_name,
        level: app.config.log_level || :info, on_error: settings.on_error,
        open_timeout: settings.open_timeout, read_timeout: settings.read_timeout,
        write_timeout: settings.write_timeout
      )
    end
  end
end
