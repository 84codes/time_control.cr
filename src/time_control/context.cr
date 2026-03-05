module TimeControl
  # :nodoc:
  class Context
    private enum TimerKind
      Sleep
      SelectTimeout
    end

    private record TimerEntry, fiber : Fiber, wake_at : Time::Instant, kind : TimerKind

    property virtual_now : Time::Instant
    property timer_loop_fiber : Fiber?
    property timer_loop_thread : Thread?
    getter leaked_timer_count : Int32 = 0

    @advance_ch : Channel(Time::Span)
    @done_ch : Channel(Nil)

    @control_start_instant : Time::Instant
    @control_start_monotonic_ns : Int64
    @control_start_utc_s : Int64
    @control_start_utc_ns : Int32
    @timers : Array(TimerEntry)
    @timers_mutex : Mutex

    def initialize
      @advance_ch = Channel(Time::Span).new
      @done_ch = Channel(Nil).new

      mono = Crystal::System::Time.monotonic
      @control_start_monotonic_ns = mono[0] * 1_000_000_000_i64 + mono[1]
      @virtual_now = Time::Instant.new(mono[0], mono[1])
      @control_start_instant = @virtual_now

      utc = Crystal::System::Time.compute_utc_seconds_and_nanoseconds
      @control_start_utc_s = utc[0]
      @control_start_utc_ns = utc[1]

      @timers = [] of TimerEntry
      @timers_mutex = Mutex.new
    end

    def virtual_monotonic : {Int64, Int32}
      elapsed_ns = (@virtual_now - @control_start_instant).total_nanoseconds.to_i64
      total_ns = @control_start_monotonic_ns + elapsed_ns
      {total_ns // 1_000_000_000_i64, (total_ns % 1_000_000_000_i64).to_i32}
    end

    def virtual_utc : {Int64, Int32}
      elapsed_ns = (@virtual_now - @control_start_instant).total_nanoseconds.to_i64
      total_ns = @control_start_utc_ns.to_i64 + elapsed_ns
      {@control_start_utc_s + total_ns // 1_000_000_000_i64, (total_ns % 1_000_000_000_i64).to_i32}
    end

    def add_sleep(fiber : Fiber, duration : Time::Span) : Nil
      @timers_mutex.synchronize do
        insert_timer(TimerEntry.new(fiber, @virtual_now + duration, TimerKind::Sleep))
      end
    end

    def add_select_timeout(fiber : Fiber, duration : Time::Span) : Nil
      @timers_mutex.synchronize do
        insert_timer(TimerEntry.new(fiber, @virtual_now + duration, TimerKind::SelectTimeout))
      end
    end

    def cancel_select_timeout(fiber : Fiber) : Nil
      @timers_mutex.synchronize do
        @timers.reject! { |e| e.fiber.same?(fiber) && e.kind.select_timeout? }
      end
    end

    def advance(duration : Time::Span) : Nil
      @advance_ch.send(duration)
      @done_ch.receive
    end

    def stop : Nil
      @advance_ch.close
    end

    def run : Nil
      while duration = @advance_ch.receive?
        target = @virtual_now + duration

        loop do
          entry = @timers_mutex.synchronize do
            e = @timers.first?
            (e && e.wake_at <= target) ? @timers.shift : nil
          end

          break unless entry

          @virtual_now = entry.wake_at
          enqueue_entry(entry)
          sleep 1.millisecond # allow the woken fiber to run and register any chained sleep before rechecking
        end

        @virtual_now = target
        @done_ch.send(nil)
      end

      loop do
        entry = @timers_mutex.synchronize { @timers.shift? }
        break unless entry
        @leaked_timer_count += 1
        enqueue_entry(entry)
      end
    end

    def clear_timers : Nil
      @timers_mutex.synchronize { @timers.clear }
    end

    private def enqueue_entry(entry : TimerEntry) : Nil
      case entry.kind
      in .sleep?
        entry.fiber.enqueue
      in .select_timeout?
        if select_action = entry.fiber.timeout_select_action
          entry.fiber.timeout_select_action = nil
          entry.fiber.enqueue if select_action.time_expired?
        end
      end
    end

    private def insert_timer(entry : TimerEntry) : Nil
      idx = @timers.bsearch_index { |e| e.wake_at >= entry.wake_at } || @timers.size
      @timers.insert(idx, entry)
    end
  end
end
