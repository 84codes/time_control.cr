require "crystal/system/time"
require "fiber"
require "channel"
require "mutex"

require "./time_control/errors"
require "./time_control/context"
require "./time_control/controller"
require "./time_control/core_ext/crystal/system/time"
require "./time_control/core_ext/crystal/event_loop"
require "./time_control/core_ext/fiber"

module TimeControl
  VERSION = "0.1.0"

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
