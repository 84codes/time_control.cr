abstract class Crystal::EventLoop::Polling < Crystal::EventLoop
  # :nodoc:
  def sleep(duration : ::Time::Span) : Nil
    if TimeControl.enabled? && duration.total_nanoseconds > 0 && !Fiber.current.same?(TimeControl.timer_loop_fiber?)
      TimeControl.add_sleep(Fiber.current, duration)
      Fiber.suspend
    else
      previous_def
    end
  end
end
