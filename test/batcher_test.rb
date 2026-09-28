# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

class BatcherTest < Minitest::Test
  def entry(message)
    JSON.generate(message: message, level: "info", service: "test-app", attrs: {}) + "\n"
  end

  def wait_until(timeout = 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk "timed out waiting for condition" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.01
    end
    true
  end

  def test_flush_delivers_buffered_entries_as_one_batch
    client = RecordingClient.new
    batcher = Logrift::Batcher.new(client, batch_size: 1000, flush_interval: 60)
    batcher.push(entry("one"))
    batcher.push(entry("two"))
    assert_equal 0, client.deliveries

    batcher.flush
    assert_equal 1, client.deliveries
    assert_equal %w[one two], client.entries.map { |item| item["message"] }
  ensure
    batcher&.close
  end

  def test_flushes_automatically_when_batch_size_is_reached
    client = RecordingClient.new
    batcher = Logrift::Batcher.new(client, batch_size: 2, flush_interval: 60)
    batcher.push(entry("one"))
    batcher.push(entry("two"))

    assert wait_until { client.deliveries == 1 }
    assert_equal %w[one two], client.entries.map { |item| item["message"] }
  ensure
    batcher&.close
  end

  def test_flushes_after_the_interval
    client = RecordingClient.new
    batcher = Logrift::Batcher.new(client, batch_size: 1000, flush_interval: 0.05)
    batcher.push(entry("one"))

    assert wait_until { client.entries.any? }
  ensure
    batcher&.close
  end

  def test_max_buffer_drops_oldest_entries
    client = BlockingClient.new
    batcher = Logrift::Batcher.new(client, batch_size: 2, max_buffer: 3, flush_interval: 60)
    batcher.push(entry("a"))
    batcher.push(entry("b"))
    client.started.pop

    4.times { |i| batcher.push(entry("extra#{i}")) }

    assert_equal 1, batcher.dropped
    assert_equal 3, batcher.instance_variable_get(:@buffer).size
  ensure
    client&.release
    batcher&.close
  end

  def test_fork_drops_inherited_buffer_and_restarts_worker
    client = RecordingClient.new
    batcher = Logrift::Batcher.new(client, batch_size: 1000, flush_interval: 60)
    batcher.instance_variable_get(:@buffer) << entry("inherited")

    Process.stub(:pid, Process.pid + 1) do
      batcher.push(entry("child"))
    end
    batcher.flush

    assert_equal ["child"], client.entries.map { |item| item["message"] }
    assert_equal 1, batcher.dropped
  ensure
    batcher&.close
  end

  def test_delivery_errors_are_reported
    failures = []
    client = RecordingClient.new
    def client.deliver(_json)
      raise Logrift::TransportError, "down"
    end
    batcher = Logrift::Batcher.new(client, batch_size: 1000, flush_interval: 60,
                                   on_error: ->(error) { failures << error })
    batcher.push(entry("one"))
    batcher.flush

    assert_equal 1, failures.length
    assert_instance_of Logrift::TransportError, batcher.last_error
  ensure
    batcher&.close
  end

  def test_invalid_options
    client = RecordingClient.new
    assert_raises(ArgumentError) { Logrift::Batcher.new(client, batch_size: 0) }
    assert_raises(ArgumentError) { Logrift::Batcher.new(client, flush_interval: 0) }
    assert_raises(ArgumentError) { Logrift::Batcher.new(client, batch_size: 10, max_buffer: 5) }
  end

  class BlockingClient
    def initialize
      @started = Queue.new
      @release = Queue.new
      @blocked = false
    end

    def started
      @started
    end

    def deliver(_json)
      unless @blocked
        @blocked = true
        @started << true
        @release.pop
      end
      true
    end

    def release
      @release << true
    end
  end
end
