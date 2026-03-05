module Crystal::System::Time
  private def self.clock_gettime(&)
    TimeControl.intercept do |ctx|
      secs, nsecs = ctx.virtual_monotonic
      return LibC::Timespec.new(tv_sec: secs, tv_nsec: nsecs)
    end
    previous_def { yield }
  end

  # :nodoc:
  def self.compute_utc_seconds_and_nanoseconds : {Int64, Int32}
    TimeControl.intercept do |ctx|
      return ctx.virtual_utc
    end
    previous_def
  end
end
