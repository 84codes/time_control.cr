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
  # An optional *start_time* sets the initial value of `Time.utc` inside the
  # block. Without it, virtual UTC starts at the real wall-clock time.
  #
  # ```
  # TimeControl.control do |controller|
  #   spawn { sleep 5.minutes; puts "done" }
  #   controller.advance(5.minutes)
  # end
  #
  # TimeControl.control(Time.utc(2030, 1, 1)) do |controller|
  #   Time.utc.year # => 2030
  # end
  #
  # TimeControl.control("2030-01-01T09:00:00Z") do |controller|
  #   Time.utc.hour # => 9
  # end
  # ```
  def self.control(& : Controller ->) : Nil
    control(Context.new) { |controller| yield controller }
  end

  def self.control(start_time : Time, & : Controller ->) : Nil
    control(Context.new(start_time)) { |controller| yield controller }
  end

  def self.control(start_time : String, & : Controller ->) : Nil
    control(parse_start_time(start_time)) { |controller| yield controller }
  end

  private def self.parse_start_time(str : String) : Time
    begin
      return Time::Format::ISO_8601_DATE_TIME.parse(str)
    rescue Time::Format::Error
    end

    {"%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d"}.each do |fmt|
      begin
        return Time.parse_utc(str, fmt)
      rescue Time::Format::Error
      end
    end

    today = Time.utc
    {"%H:%M:%S", "%H:%M"}.each do |fmt|
      begin
        t = Time.parse_utc(str, fmt)
        return Time.utc(today.year, today.month, today.day, t.hour, t.minute, t.second)
      rescue Time::Format::Error
      end
    end

    raise ArgumentError.new("Cannot parse #{str.inspect} as a date, time, or datetime")
  end

  private def self.control(ctx : Context, & : Controller ->) : Nil
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
