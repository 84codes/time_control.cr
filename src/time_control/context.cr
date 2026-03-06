module TimeControl
  private class Context
    # Seconds between Crystal's epoch (0001-01-01 UTC) and the Unix epoch (1970-01-01 UTC).
    # `compute_utc_seconds_and_nanoseconds` returns Crystal-epoch seconds, while
    # `Time#to_unix` returns Unix-epoch seconds, so this offset bridges the two.
    UNIX_TO_CRYSTAL_EPOCH = 62135596800_i64
    private enum TimerKind
      Sleep
      SelectTimeout
      IoTimeoutWakeup
    end

    private record TimerEntry, fiber : Fiber, wake_at : Time::Instant, kind : TimerKind

    getter virtual_now : Time::Instant
    property timer_loop_thread : Thread?
    getter leaked_timer_count : Int32 = 0

    @advance_ch : Channel(Time::Span)
    @done_ch : Channel(Nil)
    @timer_inserted_ch : Channel(Nil)
    @advance_target : Time::Instant?

    @control_start_instant : Time::Instant
    @control_start_monotonic_ns : Int64
    @control_start_utc_s : Int64
    @control_start_utc_ns : Int32
    @timers : Array(TimerEntry)
    @timers_mutex : Mutex

    def initialize(start_time : Time? = nil)
      @advance_ch = Channel(Time::Span).new
      @done_ch = Channel(Nil).new
      @timer_inserted_ch = Channel(Nil).new(1)

      mono = Crystal::System::Time.monotonic
      @control_start_monotonic_ns = mono[0] * 1_000_000_000_i64 + mono[1]
      @virtual_now = Time::Instant.new(mono[0], mono[1])
      @control_start_instant = @virtual_now

      if st = start_time
        @control_start_utc_s = st.to_unix + UNIX_TO_CRYSTAL_EPOCH
        @control_start_utc_ns = st.nanosecond.to_i32
      else
        utc = Crystal::System::Time.compute_utc_seconds_and_nanoseconds
        @control_start_utc_s = utc[0]
        @control_start_utc_ns = utc[1]
      end

      @timers = [] of TimerEntry
      @timers_mutex = Mutex.new
    end

    def virtual_monotonic : {Int64, Int32}
      total_ns = @control_start_monotonic_ns + elapsed_ns
      {total_ns // 1_000_000_000_i64, (total_ns % 1_000_000_000_i64).to_i32}
    end

    def virtual_utc : {Int64, Int32}
      total_ns = @control_start_utc_ns.to_i64 + elapsed_ns
      {@control_start_utc_s + total_ns // 1_000_000_000_i64, (total_ns % 1_000_000_000_i64).to_i32}
    end

    def add_sleep(fiber : Fiber, duration : Time::Span) : Nil
      notify = @timers_mutex.synchronize do
        insert_timer(TimerEntry.new(fiber, @virtual_now + duration, TimerKind::Sleep))
      end
      notify_run_loop if notify
    end

    def add_select_timeout(fiber : Fiber, duration : Time::Span) : Nil
      notify = @timers_mutex.synchronize do
        insert_timer(TimerEntry.new(fiber, @virtual_now + duration, TimerKind::SelectTimeout))
      end
      notify_run_loop if notify
    end

    def add_io_timeout(wake_at : Time::Instant) : Nil
      notify = @timers_mutex.synchronize do
        insert_timer(TimerEntry.new(Fiber.current, wake_at, TimerKind::IoTimeoutWakeup))
      end
      notify_run_loop if notify
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

    def advance : Nil
      wake_at = next_wake_at || raise "no pending timers"
      advance(wake_at - @virtual_now)
    end

    def stop : Nil
      @advance_ch.close
    end

    def run : Nil
      while duration = @advance_ch.receive?
        target = @virtual_now + duration
        @timers_mutex.synchronize { @advance_target = target }

        loop do
          entry = @timers_mutex.synchronize do
            e = @timers.first?
            (e && e.wake_at <= target) ? @timers.shift : nil
          end

          if entry
            @virtual_now = entry.wake_at
            enqueue_entry(entry)
            sleep 1.millisecond # allow the woken fiber to run and register any chained timer
          else
            # Block until a chained timer is inserted within target, or give up after 1ms.
            # This closes the race where a fiber in another thread registers a timer just
            # after the loop checked @timers but before it would break.
            select
            when @timer_inserted_ch.receive
              # a new timer was inserted within target — re-check
            when timeout(1.millisecond)
              break
            end
          end
        end

        @timers_mutex.synchronize { @advance_target = nil }
        @virtual_now = target
        @done_ch.send(nil)
      end

      loop do
        entry = @timers_mutex.synchronize { @timers.shift? }
        break unless entry
        next if entry.kind.io_timeout_wakeup? # not a stuck fiber; just an interrupt trigger for the event loop
        @leaked_timer_count += 1
        enqueue_entry(entry)
      end
    end

    private def next_wake_at : Time::Instant?
      @timers_mutex.synchronize { @timers.first?.try &.wake_at }
    end

    private def elapsed_ns : Int64
      (@virtual_now - @control_start_instant).total_nanoseconds.to_i64
    end

    private def notify_run_loop : Nil
      select
      when @timer_inserted_ch.send(nil)
      else
      end
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
      in .io_timeout_wakeup?
        # Wake the blocking kqueue/epoll wait in the fiber's event loop. This
        # causes it to call process_timers, which checks deadlines against the
        # virtual clock (already advanced) and fires IO::TimeoutError on the
        # waiting fiber.
        entry.fiber.execution_context.event_loop.interrupt
      end
    end

    # Inserts the entry into the sorted @timers array and returns true if the
    # run loop should be notified (i.e. an advance is active and this timer
    # falls within its target window).
    private def insert_timer(entry : TimerEntry) : Bool
      idx = @timers.bsearch_index { |e| e.wake_at > entry.wake_at } || @timers.size
      @timers.insert(idx, entry)
      # Return true if the run loop should be notified: an advance is in
      # progress and this timer falls within its target window, meaning the
      # loop may be blocking on @timer_inserted_ch waiting for exactly this.
      !!(t = @advance_target) && entry.wake_at <= t
    end
  end
end
