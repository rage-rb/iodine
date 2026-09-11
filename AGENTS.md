# Intro

High-performance C web server used as the runtime for [Rage](https://github.com/rage-rb/rage), a fiber-based Ruby framework.

# Main Components

- ext/iodine/fio.[ch] - reactor + base library (spinlocks, atomics, linked lists, strings)
- ext/iodine/fiobj_str.[ch], fio_ary.[ch], fio_data.[ch] - fio data structures
- ext/iodine/iodine_caller.[ch] - calling Ruby from C
- ext/iodine/iodine_http.[ch] - HTTP server, `rack.upgrade` handling
- ext/iodine/iodine_defer.[ch], iodine_pubsub.[ch] - Iodine Ruby API
- ext/iodine/scheduler.[ch] - Rage fiber scheduler hooks
- ext/iodine/iodine_worker_pool.[ch] - Ruby 4.0+ thread pool for `blocking_operation_wait`

## `__http_defer__`

`[:__http_defer__, fiber]` is a private contract between `Rage::FiberWrapper` and `iodine_http.c`:

1. Rage schedules each request in a fiber. If application code yields for non-blocking I/O, the Rack call returns `[:__http_defer__, fiber]`
2. Iodine pauses the HTTP request, and subscribes to the process-local pub/sub channel
3. When the fiber finishes, Rage publishes to that channel to resume the request

# rack.upgrade (WebSocket/SSE)

Iodine supports WebSocket/SSE. The upgrade flow:

1. Rage sets `env['rack.upgrade?']` to `:websocket`/`:sse` and `env['rack.upgrade'] = CallbackHandler`
2. Iodine invokes handler callbacks (`on_open`, `on_message`, `on_close`)

See ext/iodine/iodine_http.c and ext/iodine/iodine_connection.c for implementation.

# Threading

Rage runs Iodine single-threaded; parallelization uses forked processes. New code can exploit this for simplicity, but should remain thread-safe to respect existing Iodine patterns.

# Rules

## 1. Think First
State assumptions. Surface tradeoffs. If unclear, ask - don't guess.

## 2. Simplicity
Minimum code for the problem. No speculative features, no premature abstractions, no handling impossible cases. If 200 lines could be 50, rewrite.

## 3. Surgical Changes
Touch only what's needed. Match existing style. Remove only orphans YOUR changes created. Every changed line should trace to the request.

## 4. Verify
Define success criteria upfront. Transform vague asks into testable goals ("fix bug" → "write failing test, make it pass").
