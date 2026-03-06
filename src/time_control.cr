require "crystal/system/time"
require "fiber"
require "channel"
require "mutex"

require "./time_control/errors"
require "./time_control/context"
require "./time_control/controller"
require "./time_control/core_ext/crystal/system/time"
require "./time_control/core_ext/crystal/event_loop"
require "./time_control/core_ext/crystal/event_loop/polling"
require "./time_control/core_ext/fiber"

module TimeControl
  VERSION = "0.1.0"

  @@context : Context? = nil

  # :nodoc:
  def self.when_controlling(& : Context ->) : Nil
    ctx = @@context
    return unless ctx
    return if ::Thread.current.same?(ctx.timer_loop_thread)
    yield ctx
  end

  # Enables virtual time control for the duration of the block.
  #
  # Intercepts `sleep`, `select ... when timeout(...)`,
  # `Time.utc`, and `Time.instant` so that time stands still until
  # explicitly advanced via `Controller#advance`.
  #
  # IO operation timeouts (e.g. `read_timeout`, `write_timeout`) are also
  # intercepted on builds that use the Polling event loop (kqueue on macOS/BSD,
  # epoll on Linux). They are not intercepted on LibEvent or IOCP builds.
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
