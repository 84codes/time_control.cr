# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

The `-Dexecution_context` flag is required for all compilation and testing.

```sh
crystal spec -Dexecution_context                        # run all tests
crystal spec spec/time_control_spec.cr -Dexecution_context  # run a single spec file
shards install                                          # install dependencies
```

## Architecture

A Crystal shard (library) that hijacks Crystal's event loop to control time in specs. Requires Crystal >= 1.19.1 and the `-Dexecution_context` compile flag.

### How it works

`TimeControl.control { |remote| ... }` enables fake time for the duration of the block. The block receives a `Remote` object used to call `remote.advance(duration)`.

When enabled:
- `Crystal::EventLoop::Polling#sleep` is monkey-patched to intercept non-zero sleeps: sleeping fibers are registered in a virtual timer queue (`@@timers`) instead of the real event loop, then suspended via `Fiber.suspend`.
- `Fiber#timeout` and `Fiber#cancel_timeout` are monkey-patched to intercept `select ... when timeout(...)`.
- A `Fiber::ExecutionContext::Isolated` runs a dedicated timer thread (`timer_loop`). When `advance(N)` is called, the timer thread processes all virtual timers with `wake_at <= virtual_now + N` in order, enqueuing sleeping fibers back into their original execution contexts.
- After each batch of woken fibers, the timer thread waits 1ms (using a real sleep, since the timer loop fiber is tracked via `@@timer_loop_fiber` and excluded from interception) to allow chained sleeps to register before rechecking.

### Public API

Only two methods are part of the public API and should have Crystal doc comments:
- `TimeControl.control` — the main entry point
- `Remote#advance` — advances virtual time

Everything else is marked `# :nodoc:`. Do not add doc comments to internal methods, patch methods, or `@@` class variables.
