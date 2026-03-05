require "crystal/system/time"
require "fiber"
require "channel"
require "mutex"

require "./time_control/context"
require "./time_control/core_ext/crystal/system/time"
require "./time_control/core_ext/crystal/event_loop"
require "./time_control/core_ext/fiber"

module TimeControl
  VERSION = "0.1.0"

  # Base class for all `TimeControl` errors.
  abstract class Error < ::Exception
  end

  # Raised when a `TimeControl` operation is attempted outside of a
  # `TimeControl.control` block.
  class NotEnabledError < Error
  end

  # Raised when the `TimeControl.control` block exits with virtual timers
  # still pending, indicating that not all scheduled sleeps or timeouts
  # were advanced past.
  #
  # The number of pending timers is available via `#count`.
  class PendingTimersError < Error
    # Returns the number of timers that were still pending.
    getter count : Int32

    def initialize(@count : Int32)
      super("#{@count} timer(s) were still pending when the control block exited")
    end
  end

  # Controller object yielded by `TimeControl.control`. Used to advance
  # virtual time from within the control block.
  class Controller
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

    # Advances virtual time to the next pending timer entry.
    #
    # Raises if there are no pending timers.
    #
    # ```
    # remote.advance
    # ```
    def advance : Nil
      Fiber.yield
      wake_at = @ctx.next_wake_at || raise "no pending timers"
      @ctx.advance(wake_at - @ctx.virtual_now)
    end
  end

  @@context : Context? = nil

  # :nodoc:
  def self.enabled? : Bool
    !@@context.nil?
  end

  # :nodoc:
  def self.context : Context
    @@context || raise NotEnabledError.new("TimeControl is not enabled")
  end

  # :nodoc:
  def self.intercept(& : Context ->) : Nil
    ctx = @@context
    return unless ctx
    return if ::Thread.current.same?(ctx.timer_loop_thread)
    yield ctx
  end

  # :nodoc:
  def self.virtual_now : Time::Instant
    context.virtual_now
  end

  # Enables virtual time control for the duration of the block.
  #
  # Intercepts `sleep`, `select ... when timeout(...)`,
  # `Time.utc`, and `Time.instant` so that time stands still until
  # explicitly advanced via `Controller#advance`.
  #
  # ```
  # TimeControl.control do |remote|
  #   spawn { sleep 5.minutes; puts "done" }
  #   remote.advance(5.minutes)
  # end
  # ```
  def self.control(& : Controller ->) : Nil
    ctx = Context.new
    @@context = ctx

    isolated = Fiber::ExecutionContext::Isolated.new("time-control") do
      ctx.timer_loop_thread = Thread.current
      ctx.run
    end

    yield Controller.new(ctx)
  ensure
    @@context = nil
    ctx.try &.stop
    isolated.try &.wait
    if ctx && ctx.leaked_timer_count > 0
      raise PendingTimersError.new(ctx.leaked_timer_count)
    end
  end
end
