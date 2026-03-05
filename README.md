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
    github: spuun/time_control.cr
```

Then run `shards install`.

## Usage

```crystal
require "time_control"
```

Wrap your spec in `TimeControl.control` and use `remote.advance` to move
virtual time forward. All fibers sleeping or waiting on a timeout are woken
in chronological order as time advances.

### Controlling sleep

```crystal
it "processes a job after its scheduled delay" do
  results = Channel(String).new

  TimeControl.control do |remote|
    spawn do
      sleep 5.minutes
      results.send("job done")
    end

    # Nothing has happened yet — real time hasn't moved
    remote.advance(5.minutes)

    results.receive.should eq("job done")
  end
end
```

### Controlling select timeouts

```crystal
it "times out when no message arrives in time" do
  ch = Channel(String).new
  result = Channel(Symbol).new

  TimeControl.control do |remote|
    spawn do
      select
      when ch.receive
        result.send(:received)
      when timeout(1.second)
        result.send(:timed_out)
      end
    end

    remote.advance(1.second)
    result.receive.should eq(:timed_out)
  end
end
```

### Controlling Time.utc and Time.instant

`Time.utc` and `Time.instant` are frozen at the moment `control` is entered
and only advance when `remote.advance` is called.

```crystal
it "stamps events with virtual time" do
  TimeControl.control do |remote|
    t0 = Time.utc

    spawn do
      sleep 30.seconds
      # Time.utc here reflects exactly when the fiber woke — t0 + 30s
    end

    remote.advance(1.minute)
    (Time.utc - t0).should eq(1.minute)
  end
end
```

### Pending timers

If the `control` block exits while virtual timers are still pending (i.e.
fibers are sleeping beyond the last `advance`), a `TimeControl::PendingTimersError`
is raised. This catches specs that forget to advance past all scheduled work.

## License

MIT
