abstract class Crystal::EventLoop::Polling < Crystal::EventLoop
  # :nodoc:
  def sleep(duration : ::Time::Span) : Nil
    if TimeControl.enabled? && duration.total_nanoseconds > 0
      ctx = TimeControl.context
      unless Fiber.current.same?(ctx.timer_loop_fiber)
        ctx.add_sleep(Fiber.current, duration)
        Fiber.suspend
        return
      end
    end
    previous_def
  end
end
