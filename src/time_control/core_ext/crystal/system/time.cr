module Crystal::System::Time
  # :nodoc:
  def self.real_monotonic : {Int64, Int32}
    tp = clock_gettime { raise RuntimeError.from_errno("clock_gettime()") }
    {tp.tv_sec.to_i64, tp.tv_nsec.to_i32}
  end

  # :nodoc:
  def self.real_compute_utc_seconds_and_nanoseconds : {Int64, Int32}
    ret = LibC.clock_gettime(LibC::CLOCK_REALTIME, out timespec)
    raise RuntimeError.from_errno("clock_gettime") unless ret == 0
    {timespec.tv_sec.to_i64 + UNIX_EPOCH_IN_SECONDS, timespec.tv_nsec.to_i}
  end

  # :nodoc:
  def self.monotonic : {Int64, Int32}
    if TimeControl.enabled? && !::Thread.current.same?(TimeControl.timer_loop_thread?)
      TimeControl.virtual_monotonic
    else
      previous_def
    end
  end

  # :nodoc:
  def self.compute_utc_seconds_and_nanoseconds : {Int64, Int32}
    if TimeControl.enabled? && !::Thread.current.same?(TimeControl.timer_loop_thread?)
      TimeControl.virtual_utc
    else
      previous_def
    end
  end
end
