# AGENTS.md

A Crystal shard (library) that hijacks Crystal's event loop to control time in specs. Requires Crystal >= 1.19.1 and the `-Dexecution_context` compile flag.

## Code Style

After editing any `.cr` file, format it with:

```sh
crystal tool format <file>
```

## Build & Test Commands

The `-Dexecution_context` flag is required for all compilation and testing.

```sh
crystal spec -Dexecution_context                            # run all tests
crystal spec spec/time_control_spec.cr -Dexecution_context  # run a single spec file
ameba                                                       # lint
shards install                                              # install dependencies
```

## Architecture

`TimeControl.control { |controller| ... }` enables fake time for the duration of the block. The block receives a `Controller` object used to call `controller.advance(duration)`.

When enabled:
- All `Crystal::EventLoop` subclasses that define `sleep` are monkey-patched via a compile-time macro to intercept non-zero sleeps: sleeping fibers are registered in a virtual timer queue inside `Context` instead of the real event loop, then suspended via `Fiber.suspend`.
- `Fiber#timeout` and `Fiber#cancel_timeout` are monkey-patched to intercept `select ... when timeout(...)`.
- `Crystal::System::Time.clock_gettime` is monkey-patched to return virtual monotonic time; `Crystal::System::Time.compute_utc_seconds_and_nanoseconds` is patched to return virtual UTC time.
- A `Fiber::ExecutionContext::Isolated` runs a dedicated timer thread. When `advance(N)` is called, the timer thread processes all virtual timers with `wake_at <= virtual_now + N` in order, enqueuing sleeping fibers back into their original execution contexts.
- After each batch of woken fibers, the timer thread waits 1ms (real sleep — the timer loop thread is tracked on `Context` and excluded from interception via `TimeControl.when_controlling`) to allow chained sleeps to register before rechecking.
- If the control block exits with timers still pending, `PendingTimersError` is raised.

## Public API

- `TimeControl.control` — the main entry point
- `Controller#advance(duration)` — advances virtual time by a fixed amount
- `Controller#advance` — advances virtual time to the next pending timer
- `TimeControl::Error`, `TimeControl::PendingTimersError` — error classes

Everything else is marked `# :nodoc:` or `private`. Do not add doc comments to internal methods, patch methods, or instance variables.
