# Changelog

## 0.1.0

- HTTP client with single and batch ingestion, HTTPS and bounded timeouts.
- Background batched delivery for the logger adapters (`batch_size` 1000,
  `flush_interval` 10s, `max_buffer` 5000) with fork and shutdown flushing.
- Ruby Logger adapter with structured fields and exception details.
- Opt-in Rails integration with request tags and log silencing.
