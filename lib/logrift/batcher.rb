# frozen_string_literal: true

require "thread"

module Logrift
  # Buffers formatted log entries and delivers them to the collector in batches
  # from a background thread, so logging never blocks the caller on the network.
  #
  # Delivery is best-effort: entries are held in memory until a flush and are
  # lost if the process exits before they are delivered.
  class Batcher
    DEFAULT_BATCH_SIZE = 5000
    DEFAULT_FLUSH_INTERVAL = 30
    DEFAULT_MAX_BUFFER = 20_000

    attr_reader :dropped, :last_error

    def initialize(client, on_error: nil, batch_size: DEFAULT_BATCH_SIZE,
                   flush_interval: DEFAULT_FLUSH_INTERVAL, max_buffer: DEFAULT_MAX_BUFFER)
      @client = client
      @on_error = on_error || ->(error) { $stderr.puts("logrift: #{error.message}") }
      @batch_size = positive_integer(batch_size, "batch_size")
      @flush_interval = positive_number(flush_interval, "flush_interval")
      @max_buffer = positive_integer(max_buffer, "max_buffer")
      raise ArgumentError, "max_buffer must be greater than or equal to batch_size" if @max_buffer < @batch_size

      @buffer = []
      @dropped = 0
      @last_error = nil
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @deliver_mutex = Mutex.new
      @notified = false
      @stopping = false
      @pid = Process.pid
      @thread = nil
      at_exit { close }
    end

    # Appends a pre-formatted JSON entry. Returns the number of bytes accepted.
    def push(json)
      @mutex.synchronize do
        ensure_worker
        @buffer << json
        trim
        if @buffer.size >= @batch_size
          @notified = true
          @condition.signal
        end
      end
      json.bytesize
    rescue StandardError => error
      report(error)
      0
    end

    # Delivers buffered entries now, on the calling thread.
    def flush
      batch = @mutex.synchronize { @buffer.shift(@buffer.size) }
      deliver(batch) unless batch.empty?
      self
    end

    # Delivers remaining entries and stops the background worker.
    def close
      thread = nil
      @mutex.synchronize do
        @stopping = true
        @condition.broadcast
        thread = @thread
      end
      begin
        thread&.join(join_timeout)
      rescue StandardError
        # The runtime may already be shutting down; fall through to a final flush.
      end
      flush
      @mutex.synchronize { @thread = nil }
      self
    end

    private

    def ensure_worker
      return if @thread&.alive? && @pid == Process.pid

      # A forked child inherits the buffer but not the worker thread. Drop the
      # inherited entries to avoid delivering them twice and start a new worker.
      if @pid != Process.pid
        @dropped += @buffer.size
        @buffer.clear
        @pid = Process.pid
      end

      @stopping = false
      @thread = Thread.new { run }
      @thread.name = "logrift-delivery"
    end

    def run
      loop do
        batch = []
        stop = false
        begin
          @mutex.synchronize do
            stop = @stopping
            unless stop || @notified
              @condition.wait(@mutex, @flush_interval)
              stop = @stopping
            end
            @notified = false
            batch = @buffer.shift(@buffer.size)
          end
          deliver(batch) unless batch.empty?
        rescue StandardError => error
          report(error)
        end
        break if stop
      end
    end

    def deliver(batch)
      @deliver_mutex.synchronize { @client.deliver("[#{batch.join(',')}]") }
      @last_error = nil
    rescue Error => error
      @last_error = error
      report(error)
    end

    def trim
      return if @buffer.size <= @max_buffer

      excess = @buffer.size - @max_buffer
      @buffer.shift(excess)
      @dropped += excess
    end

    def report(error)
      @on_error.call(error)
    rescue StandardError
      $stderr.puts("logrift: error handler failed")
    end

    def join_timeout
      @flush_interval + 10
    end

    def positive_integer(value, name)
      number = Integer(value)
      raise ArgumentError unless number.positive?
      number
    rescue TypeError, ArgumentError
      raise ArgumentError, "#{name} must be a positive integer"
    end

    def positive_number(value, name)
      number = Float(value)
      raise ArgumentError unless number.positive?
      number
    rescue TypeError, ArgumentError
      raise ArgumentError, "#{name} must be a positive number"
    end
  end
end
