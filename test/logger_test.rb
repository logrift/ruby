# frozen_string_literal: true

require "test_helper"

class LoggerTest < Minitest::Test
  def setup
    @client = RecordingClient.new
    @logger = Logrift::Logger.new(client: @client)
  end

  def teardown
    @logger.close
  end

  def test_all_severities
    @logger.level = :debug
    %i[debug info warn error fatal unknown].each { |level| @logger.public_send(level, "hello") }
    @logger.flush
    assert_equal %w[debug info warn error fatal info], @client.entries.map { |entry| entry["level"] }
    assert_equal "test-app", @client.entries.first["service"]
    assert_match(/Z\z/, @client.entries.first["time"])
  end

  def test_lazy_block_and_filtering
    @logger.debug { flunk "filtered block should not run" }
    @logger.info { "lazy" }
    @logger.flush
    assert_equal ["lazy"], @client.entries.map { |entry| entry["message"] }
  end

  def test_structured_fields_and_progname
    @logger.progname = "worker"
    payload = { message: "finished", duration_ms: 42 }
    @logger.info(payload)
    @logger.flush
    entry = @client.entries.last
    assert_equal "finished", entry["message"]
    assert_equal({ "duration_ms" => 42, "progname" => "worker" }, entry["attrs"])
    assert_equal({ message: "finished", duration_ms: 42 }, payload)
  end

  def test_exception_details
    exception = RuntimeError.new("boom")
    exception.set_backtrace(["app/job.rb:1"])
    @logger.error(exception)
    @logger.flush
    entry = @client.entries.last
    assert_equal "boom", entry["message"]
    assert_equal "RuntimeError", entry["attrs"]["exception"]
    assert_equal ["app/job.rb:1"], entry["attrs"]["backtrace"]
  end

  def test_entries_are_delivered_in_a_single_batch
    @logger.info("one")
    @logger.info("two")
    assert_equal 0, @client.deliveries
    @logger.flush
    assert_equal 1, @client.deliveries
    assert_equal %w[one two], @client.entries.map { |entry| entry["message"] }
  end

  def test_delivery_failures_are_reported_without_raising
    failures = []
    client = RecordingClient.new
    def client.deliver(_json)
      raise Logrift::HTTPError, 401
    end
    logger = Logrift::Logger.new(client: client, on_error: ->(error) { failures << error })
    assert logger.info("hello")
    assert logger.flush
    assert_equal 401, failures.first.status
  ensure
    logger&.close
  end

  def test_failing_error_handler_does_not_break_logging
    client = RecordingClient.new
    def client.deliver(_json)
      raise Logrift::TransportError, "unavailable"
    end
    logger = Logrift::Logger.new(client: client, on_error: ->(_error) { raise "oops" })
    _out, err = capture_io do
      assert logger.info("hello")
      logger.flush
    end
    assert_includes err, "error handler failed"
  ensure
    logger&.close
  end

  def test_shared_logger_across_threads
    threads = 4.times.map { |n| Thread.new { 10.times { @logger.info("thread #{n}") } } }
    threads.each(&:join)
    @logger.flush
    assert_equal 40, @client.entries.length
  end
end
