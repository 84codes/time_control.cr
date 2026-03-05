abstract class Crystal::EventLoop::Polling < Crystal::EventLoop
  # :nodoc:
  def sleep(duration : ::Time::Span) : Nil
    ctx = TimeControl.context
    if ctx && duration.total_nanoseconds > 0 && !Fiber.current.same?(ctx.timer_loop_fiber)
      ctx.add_sleep(Fiber.current, duration)
      Fiber.suspend
    else
      previous_def
    end
  end
end
