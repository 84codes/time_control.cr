require "crystal/system/time"
require "fiber"
require "channel"
require "mutex"

require "./time_control/context"
require "./time_control/core_ext/crystal/system/time"
require "./time_control/core_ext/crystal/event_loop/polling"
require "./time_control/core_ext/fiber"

module TimeControl
  VERSION = "0.1.0"

  # Controller object yielded by `TimeControl.control`. Used to advance
  # virtual time from within the control block.
  class Remote
    # :nodoc:
    def initialize(@ctx : Context)
    end

    # Advances virtual time by *duration*.
    #
    # Wakes all sleeping fibers and select timeouts that fall within the
    # advanced window, in chronological order. Blocks until all woken fibers
    # have had a chance to run before returning.
    #
    # ```
    # remote.advance(5.seconds)
    # ```
    def advance(duration : Time::Span) : Nil
      Fiber.yield
      @ctx.advance(duration)
    end
  end

  @@context : Context? = nil

  # :nodoc:
  def self.enabled? : Bool
    !@@context.nil?
  end

  # :nodoc:
  def self.context : Context
    @@context || raise "TimeControl is not enabled"
  end

  # :nodoc:
  def self.virtual_now : Time::Instant
    context.virtual_now
  end

  # Enables virtual time control for the duration of the block.
  #
  # Intercepts `sleep`, `select ... when timeout(...)`,
  # `Time.utc`, and `Time.instant` so that time stands still until
  # explicitly advanced via `Remote#advance`.
  #
  # ```
  # TimeControl.control do |remote|
  #   spawn { sleep 5.minutes; puts "done" }
  #   remote.advance(5.minutes)
  # end
  # ```
  def self.control(& : Remote ->) : Nil
    ctx = Context.new
    @@context = ctx

    isolated = Fiber::ExecutionContext::Isolated.new("time-control") do
      ctx.timer_loop_fiber = Fiber.current
      ctx.timer_loop_thread = Thread.current
      ctx.run
    end

    yield Remote.new(ctx)
  ensure
    @@context = nil
    ctx.try &.stop
    isolated.try &.wait
    ctx.try &.clear_timers
    if ctx && ctx.leaked_timer_count > 0
      raise "TimeControl: #{ctx.leaked_timer_count} timer(s) were still pending when the control block exited"
    end
  end
end
