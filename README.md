# Logrift for Ruby

Ruby client and Rails logger for [Logrift](https://github.com/logrift/server),
the self-hosted log collector. Ruby 3.1+; Rails integration supports Rails 7.2+
and 8.x (with the Ruby version required by Rails).

## Install

Until the first RubyGems release, add to your Gemfile:

```ruby
gem "logrift", github: "logrift/ruby", branch: "main"
```

Run `bundle install`. Create a project in your Logrift server and save its
**project ingest key**. Use the instance's base URL, including any reverse proxy
path prefix; the client appends `/api/logs`. Use HTTPS for remote servers.

## Rails

Set your deployment's environment variables:

```sh
LOGRIFT_URL=https://logs.example.com
LOGRIFT_API_KEY=lr_your_project_key
LOGRIFT_SERVICE=my-rails-app
```

Enable the logger in `config/environments/production.rb`:

```ruby
config.logrift.enabled = true
config.log_tags = [:request_id]
config.log_level = :info
```

The gem's Railtie configures the logger before Rails initializes its framework
loggers. Configure it in `config/application.rb` or an environment file, rather
than `config/initializers`, which runs after logger initialization. Merely
installing the gem does not replace your existing logger.

```ruby
Rails.logger.info("Order submitted")
Rails.logger.info(message: "Order submitted", order_id: order.id, amount: order.total)
Rails.logger.error(exception)
Rails.logger.tagged("checkout") { Rails.logger.warn("Payment delayed") }
```

Request tags are stored in `attrs.tags`; structured fields and exception
backtraces stay searchable. Standard Rails log silencing and thread-local levels
are supported. Filter sensitive data before logging it.

All settings can be set explicitly:

```ruby
config.logrift.url = ENV.fetch("LOGRIFT_URL")
config.logrift.api_key = Rails.application.credentials.dig(:logrift, :api_key)
config.logrift.service = "shop"
config.logrift.open_timeout = 1
config.logrift.read_timeout = 2
config.logrift.write_timeout = 2
config.logrift.batch_size = 1000
config.logrift.flush_interval = 10
config.logrift.max_buffer = 5000
config.logrift.on_error = ->(error) { $stderr.puts(error.message) }
```

An error handler must use a separate destination to avoid recursive logging.

To configure a logger manually, use `Logrift::RailsIntegration.logger` from
`require "logrift/rails"` with the same client options. To also retain local output,
Rails 7.2+ provides `ActiveSupport::BroadcastLogger`:

```ruby
remote = Logrift::RailsIntegration.logger(
  url: ENV.fetch("LOGRIFT_URL"), api_key: ENV.fetch("LOGRIFT_API_KEY"), service: "shop"
)
local = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new($stdout))
config.logger = ActiveSupport::BroadcastLogger.new(local, remote)
```

## Ruby Logger

```ruby
require "logrift"

logger = Logrift::Logger.new(
  url: "http://127.0.0.1:8787", api_key: ENV.fetch("LOGRIFT_API_KEY"), service: "worker"
)
logger.level = :info
logger.info(message: "Job complete", job_id: 42, duration_ms: 120)
logger.debug { "Expensive debug message" }
```

## Direct client and batches

```ruby
client = Logrift::Client.new(
  url: "http://127.0.0.1:8787", api_key: ENV.fetch("LOGRIFT_API_KEY"), service: "worker"
)
client.log("Job complete", level: :info, job_id: 42)
client.ingest(message: "A native Logrift entry", level: "warn", service: "worker")
client.ingest([
  { message: "First", level: "info", service: "worker", attrs: { job_id: 1 } },
  { message: "Second", level: "error", service: "worker", attrs: { job_id: 2 } }
]) # => 2 accepted entries
```

`ingest` sends native entries as supplied; it does not add the client's service
or timestamp. `log` and the logger adapters build the canonical schema for you.
Empty batches return zero without making a request. The direct client raises
`Logrift::HTTPError` (with `status`) for non-success responses and
`Logrift::TransportError` for connection and timeout errors.

## Delivery behavior

The `Logger` and Rails integration buffer formatted entries in memory and
deliver them to the collector from a background thread, so logging does not
block the caller on the network. A batch is sent every `flush_interval`
(default 10 seconds) or as soon as `batch_size` entries (default 1000) are
buffered. The buffer is bounded by `max_buffer` entries (default 5000); when it
is full the oldest entries are dropped and counted in `dropped`. Buffered
entries are flushed on `close` and at process exit, and a forked child discards
entries inherited from the parent and starts its own worker. Pass `batch: false`
to deliver each entry synchronously instead.

The `Client` delivers each `ingest`/`log` call immediately. Connections use
Ruby's TLS certificate verification, with 1 second connect and 2 second
read/write timeouts by default. There are no automatic retries or persistent
connections; the client can be shared across threads and used after a fork.

Delivery is best-effort, without disk buffering or a delivery guarantee: entries
can be delayed up to `flush_interval` and are lost if the process exits or the
collector is unavailable before they are flushed. Logger delivery errors are
reported to stderr (or `on_error`) and never raise into an application request.
For high-volume workloads that need durability, use an explicit client batch or
a local log collector.

## Development

```sh
bundle install
bundle exec rake
gem build logrift.gemspec
```

CI tests Ruby 3.1/3.3 with Rails 7.2 and Ruby 3.4 with Rails 8.0/8.1. Tests cover
the HTTP wire protocol, batch ingestion, error handling, logger semantics,
structured request tags and Rails integration.

Licensed under MIT.
