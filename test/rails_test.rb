# frozen_string_literal: true

require "test_helper"
require "rails"
require "logrift/railtie"
require "open3"
require "rbconfig"

class RailsTest < Minitest::Test
  def setup
    @client = RecordingClient.new
    @logger = Logrift::RailsIntegration.logger(client: @client)
  end

  def teardown
    @logger.close
  end

  def test_nested_tags_preserve_structured_fields_and_do_not_leak
    @logger.tagged("request-123") do
      @logger.tagged("job") { @logger.info(message: "done", status: 200) }
    end
    @logger.info("outside")
    @logger.flush
    entry = @client.entries.first
    assert_equal "done", entry["message"]
    assert_equal 200, entry["attrs"]["status"]
    assert_equal ["request-123", "job"], entry["attrs"]["tags"]
    refute @client.entries.last["attrs"].key?("tags")
  end

  def test_tags_without_a_block
    tagged = @logger.tagged("job")
    tagged.error(RuntimeError.new("boom"))
    @logger.flush
    assert_equal "RuntimeError", @client.entries.last["attrs"]["exception"]
    assert_equal ["job"], @client.entries.last["attrs"]["tags"]
    @logger.info("outside")
    @logger.flush
    refute @client.entries.last["attrs"].key?("tags")
  end

  def test_silencing_and_thread_local_levels
    @logger.silence { @logger.info("hidden"); @logger.error("visible") }
    @logger.flush
    assert_equal ["visible"], @client.entries.map { |entry| entry["message"] }
    @logger.info("normal")
    @logger.flush
    assert_equal "normal", @client.entries.last["message"]
  end

  def test_tags_are_isolated_across_threads
    threads = 3.times.map do |n|
      Thread.new { @logger.tagged("request-#{n}") { @logger.info("#{n}") } }
    end
    threads.each(&:join)
    @logger.flush
    @client.entries.each { |entry| assert_equal ["request-#{entry['message']}"], entry["attrs"]["tags"] }
  end

  def test_railtie_is_opt_in
    assert_equal false, Logrift::Railtie.config.logrift.enabled
  end

  def test_railtie_configures_logger_before_rails_logger_initialization
    settings = ActiveSupport::OrderedOptions.new
    settings.enabled = true
    settings.url = "http://127.0.0.1:8787"
    settings.api_key = "key"
    settings.service = "app"
    settings.open_timeout = 1
    settings.read_timeout = 2
    settings.write_timeout = 2
    config = ActiveSupport::OrderedOptions.new
    config.logrift = settings
    config.log_level = :warn
    app = Struct.new(:config).new(config)
    initializer = Logrift::Railtie.initializers.find { |item| item.name == "logrift.configure_logger" }
    assert_equal :initialize_logger, initializer.before
    initializer.run(app)
    assert_equal ::Logger::WARN, app.config.logger.level
    assert_respond_to app.config.logger, :tagged
    assert_respond_to app.config.logger, :silence
  end

  def test_real_rails_application_boot_and_request_logging
    script = <<~'RUBY'
      require "rails"
      require "action_controller/railtie"
      require "logrift"
      require "tmpdir"
      ENTRIES = []
      class Logrift::Client
        def deliver(json)
          parsed = JSON.parse(json)
          ENTRIES.concat(parsed.is_a?(Array) ? parsed : [parsed])
          true
        end
      end
      class RubyClientTestApp < Rails::Application
        config.root = Dir.mktmpdir("logrift-rails-app")
        config.eager_load = false
        config.secret_key_base = "test-secret-key-base" * 4
        config.hosts.clear
        config.logrift.enabled = true
        config.logrift.url = "http://localhost:8787"
        config.logrift.api_key = "test-key"
        config.logrift.service = "boot-test"
        config.log_tags = [:request_id]
      end
      RubyClientTestApp.initialize!
      Rails.application.routes.draw do
        get "/check", to: ->(_env) {
          Rails.logger.info(message: "request complete", order_id: 42)
          [200, { "content-type" => "text/plain" }, ["ok"]]
        }
      end
      status, _headers, body = Rails.application.call(
        Rack::MockRequest.env_for("/check", "HTTP_X_REQUEST_ID" => "request-123")
      )
      body.close if body.respond_to?(:close)
      Rails.logger.flush
      puts JSON.generate(status: status, entries: ENTRIES)
    RUBY
    out, err, result = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script)
    assert result.success?, err
    payload = JSON.parse(out)
    assert_equal 200, payload["status"]
    entry = payload["entries"].find { |item| item["message"] == "request complete" }
    refute_nil entry
    assert_equal "boot-test", entry["service"]
    assert_equal 42, entry["attrs"]["order_id"]
    assert_equal ["request-123"], entry["attrs"]["tags"]
  end

  def test_manual_rails_integration_can_be_loaded_without_booting_rails
    script = <<~'RUBY'
      require "logrift/rails"
      client = Struct.new(:service, :entries).new("manual", [])
      def client.deliver(json)
        parsed = JSON.parse(json)
        entries.concat(parsed.is_a?(Array) ? parsed : [parsed])
      end
      logger = Logrift::RailsIntegration.logger(client: client)
      logger.tagged("manual-tag") { logger.info("hello") }
      logger.flush
      puts JSON.generate(client.entries)
    RUBY
    out, err, result = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script)
    assert result.success?, err
    assert_equal ["manual-tag"], JSON.parse(out).first.dig("attrs", "tags")
  end
end
