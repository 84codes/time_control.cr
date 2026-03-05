module Crystal::System::Time
  private def self.clock_gettime(&)
    if TimeControl.enabled?
      ctx = TimeControl.context
      unless ::Thread.current.same?(ctx.timer_loop_thread)
        secs, nsecs = ctx.virtual_monotonic
        return LibC::Timespec.new(tv_sec: secs, tv_nsec: nsecs)
      end
    end
    previous_def { yield }
  end

  # :nodoc:
  def self.compute_utc_seconds_and_nanoseconds : {Int64, Int32}
    if TimeControl.enabled?
      ctx = TimeControl.context
      return ctx.virtual_utc unless ::Thread.current.same?(ctx.timer_loop_thread)
    end
    previous_def
  end
end
