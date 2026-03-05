# TimeControl

A Crystal shard for controlling time in specs. Intercepts `sleep`,
`select ... when timeout(...)`, `Time.utc`, and `Time.instant` so that
time stands still until explicitly advanced — making specs that involve
timeouts and scheduled work run instantly without real waiting.

Requires Crystal >= 1.19.1 and the `-Dexecution_context` compile flag.

## Installation

Add the dependency to your `shard.yml`:

```yaml
dependencies:
  time_control:
    github: 84codes/time_control.cr
```

Then run `shards install`.

## Usage

```crystal
require "time_control"
```

Wrap your spec in `TimeControl.control` and use `controller.advance` to move
virtual time forward. All fibers sleeping or waiting on a timeout are woken
in chronological order as time advances.

`controller.advance(duration)` advances by a fixed amount. `controller.advance` (no
argument) advances exactly to the next pending timer, which is useful when you
don't want to hard-code durations in your spec.

### Controlling sleep

```crystal
it "processes a job after its scheduled delay" do
  results = Channel(String).new

  TimeControl.control do |controller|
    spawn do
      sleep 5.minutes
      results.send("job done")
    end

    # Nothing has happened yet — real time hasn't moved
    controller.advance(5.minutes)

    results.receive.should eq("job done")
  end
end
```

### Controlling select timeouts

```crystal
it "times out when no message arrives in time" do
  ch = Channel(String).new
  result = Channel(Symbol).new

  TimeControl.control do |controller|
    spawn do
      select
      when ch.receive
        result.send(:received)
      when timeout(1.second)
        result.send(:timed_out)
      end
    end

    controller.advance(1.second)
    result.receive.should eq(:timed_out)
  end
end
```

### Controlling Time.utc and Time.instant

`Time.utc` and `Time.instant` are frozen at the moment `control` is entered
and only advance when `controller.advance` is called.

```crystal
it "stamps events with virtual time" do
  TimeControl.control do |controller|
    t0 = Time.utc

    spawn do
      sleep 30.seconds
      # Time.utc here reflects exactly when the fiber woke — t0 + 30s
    end

    controller.advance(1.minute)
    (Time.utc - t0).should eq(1.minute)
  end
end
```

### Advancing to the next timer

`controller.advance` (no argument) advances exactly to the next pending timer.
Useful when the exact delay doesn't matter to the spec:

```crystal
it "retries after the backoff period" do
  attempts = Channel(Int32).new(2)

  TimeControl.control do |controller|
    spawn do
      attempts.send(1)
      sleep 30.seconds  # backoff — exact value doesn't matter to the spec
      attempts.send(2)
    end

    attempts.receive.should eq(1)
    controller.advance           # skip the backoff, whatever it is
    attempts.receive.should eq(2)
  end
end
```

### Pending timers

If the `control` block exits while virtual timers are still pending (i.e.
fibers are sleeping beyond the last `advance`), a `TimeControl::PendingTimersError`
is raised. This catches specs that forget to advance past all scheduled work.

## How it works

### Monkey patches

**`Crystal::EventLoop` subclasses — `sleep`**
The event loop's `sleep` is the single point where all fiber sleeps bottom
out, regardless of whether the caller used `sleep 1.second`, `Channel#receive`
with a timeout, or any other higher-level API. Patching it here means no
call-site changes are needed in user code. A compile-time macro iterates
`Crystal::EventLoop.all_subclasses` and patches every subclass that defines
its own `sleep`, so the correct implementation is covered no matter which
event loop backend is compiled in.

**`Fiber#timeout` and `Fiber#cancel_timeout`**
These are the internal hooks Crystal uses for `select … when timeout(…)`.
Patching them registers (or removes) a virtual select-timeout entry instead
of arming the real event loop timer, so timeout branches fire at the right
virtual instant.

**`Crystal::System::Time.clock_gettime`**
All monotonic time reads — including `Time::Instant.now` and the durations
used internally by the scheduler — go through this private method. Returning
a virtual `Timespec` here makes `Time.instant` and `sleep` duration tracking
reflect virtual time rather than wall-clock time.

**`Crystal::System::Time.compute_utc_seconds_and_nanoseconds`**
Patching this makes `Time.utc` return the virtual UTC time derived from the
same virtual offset, so timestamps created inside a `control` block are
consistent with the advanced clock.

### Isolated execution context

`TimeControl.control` starts a dedicated `Fiber::ExecutionContext::Isolated`
— a single-threaded execution context that owns the timer loop. Using an
isolated context is important for two reasons:

1. **Thread identity.** The timer loop thread must be distinguishable from all
   other threads so that the monkey patches can let it bypass interception.
   The timer loop calls `sleep` (real sleep, to yield between batches of woken
   fibers) and reads real monotonic time during `Context` initialisation; both
   would recurse infinitely if intercepted. The patches check
   `Thread.current.same?(ctx.timer_loop_thread)` and fall through to the
   original implementation when on that thread.

2. **Controlled scheduling.** An isolated context has its own scheduler and
   runs independently of the default execution context. This means `advance`
   can block the calling fiber on a channel receive while the timer loop
   processes woken fibers without either side starving the other.

When a fiber calls `sleep` or registers a `select … when timeout(…)`, the
monkey patch suspends it and records a virtual timer entry. When
`controller.advance(duration)` is called, it sends the duration over a channel to
the timer loop fiber, which wakes all entries whose `wake_at <= virtual_now +
duration` in chronological order. After each woken fiber is enqueued, the
timer loop does a real 1 ms sleep to give the fiber a chance to run and
register any chained sleep before the loop rechecks. Once all timers in the
window are processed, `virtual_now` is set to the target and a done signal is
sent back to the caller.

## License

MIT
