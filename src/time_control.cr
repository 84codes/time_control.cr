require "crystal/system/time"
require "fiber"
require "channel"
require "mutex"

require "./time_control/core_ext/crystal/system/time"
require "./time_control/core_ext/crystal/event_loop/polling"
require "./time_control/core_ext/fiber"

module TimeControl
  VERSION = "0.1.0"

  # Yields a `Remote` that can be used to advance virtual time within the block.
  #
  # While the block is active, `sleep`, `select ... when timeout(...)`,
  # `Time.utc`, and `Time.instant` are intercepted so that time stands still
  # until explicitly advanced via `Remote#advance`.
  #
  # ```
  # TimeControl.control do |remote|
  #   spawn { sleep 5.minutes; puts "done" }
  #   remote.advance(5.minutes)
  # end
  # ```
  def self.control(& : Remote ->) : Nil
    advance_ch = Channel(Time::Span).new
    done_ch = Channel(Nil).new

    mono = Crystal::System::Time.real_monotonic
    @@control_start_monotonic_ns = mono[0] * 1_000_000_000_i64 + mono[1]
    @@virtual_now = Time::Instant.new(mono[0], mono[1])
    @@control_start_instant = @@virtual_now

    utc = Crystal::System::Time.real_compute_utc_seconds_and_nanoseconds
    @@control_start_utc_s = utc[0]
    @@control_start_utc_ns = utc[1]

    @@timers.clear
    @@enabled = true

    ctx = Fiber::ExecutionContext::Isolated.new("time-control") do
      @@timer_loop_fiber = Fiber.current
      @@timer_loop_thread = Thread.current
      timer_loop(advance_ch, done_ch)
    end

    yield Remote.new(advance_ch, done_ch)
  ensure
    @@enabled = false
    @@timer_loop_fiber = nil
    @@timer_loop_thread = nil
    advance_ch.try &.close
    ctx.try &.wait
    @@timers_mutex.synchronize { @@timers.clear }
  end

  # Controller object yielded by `TimeControl.control`. Used to advance
  # virtual time from within the control block.
  class Remote
    # :nodoc:
    def initialize(@advance_ch : Channel(Time::Span), @done_ch : Channel(Nil))
    end

    # Advances virtual time by *duration*.
    #
    # Wakes all sleeping fibers and select timeouts that fall within the
    # advanced window, in chronological order. Blocks until all woken fibers
    # have had a chance to run before returning.
    #
    # ```
    # remote.advance(5.seconds)
    # ```
    def advance(duration : Time::Span) : Nil
      raise "TimeControl is not enabled" unless TimeControl.enabled?
      Fiber.yield
      @advance_ch.send(duration)
      @done_ch.receive
    end
  end

  private enum TimerKind
    Sleep
    SelectTimeout
  end

  private record TimerEntry, fiber : Fiber, wake_at : Time::Instant, kind : TimerKind

  @@enabled : Bool = false
  @@virtual_now : Time::Instant = Time::Instant.new(0_i64, 0_i32)
  @@control_start_instant : Time::Instant = Time::Instant.new(0_i64, 0_i32)
  @@control_start_monotonic_ns : Int64 = 0_i64
  @@control_start_utc_s : Int64 = 0_i64
  @@control_start_utc_ns : Int32 = 0_i32
  @@timers : Array(TimerEntry) = [] of TimerEntry
  @@timers_mutex : Mutex = Mutex.new
  @@timer_loop_fiber : Fiber? = nil
  @@timer_loop_thread : Thread? = nil

  # :nodoc:
  def self.enabled? : Bool
    @@enabled
  end

  # :nodoc:
  def self.virtual_now : Time::Instant
    @@virtual_now
  end

  # :nodoc:
  def self.timer_loop_fiber? : Fiber?
    @@timer_loop_fiber
  end

  # :nodoc:
  def self.timer_loop_thread? : Thread?
    @@timer_loop_thread
  end

  # :nodoc:
  def self.virtual_monotonic : {Int64, Int32}
    elapsed_ns = (@@virtual_now - @@control_start_instant).total_nanoseconds.to_i64
    total_ns = @@control_start_monotonic_ns + elapsed_ns
    {total_ns // 1_000_000_000_i64, (total_ns % 1_000_000_000_i64).to_i32}
  end

  # :nodoc:
  def self.virtual_utc : {Int64, Int32}
    elapsed_ns = (@@virtual_now - @@control_start_instant).total_nanoseconds.to_i64
    total_ns = @@control_start_utc_ns.to_i64 + elapsed_ns
    {@@control_start_utc_s + total_ns // 1_000_000_000_i64, (total_ns % 1_000_000_000_i64).to_i32}
  end

  # :nodoc:
  def self.add_sleep(fiber : Fiber, duration : Time::Span) : Nil
    @@timers_mutex.synchronize do
      insert_timer(TimerEntry.new(fiber, @@virtual_now + duration, TimerKind::Sleep))
    end
  end

  # :nodoc:
  def self.add_select_timeout(fiber : Fiber, duration : Time::Span) : Nil
    @@timers_mutex.synchronize do
      insert_timer(TimerEntry.new(fiber, @@virtual_now + duration, TimerKind::SelectTimeout))
    end
  end

  # :nodoc:
  def self.cancel_select_timeout(fiber : Fiber) : Nil
    @@timers_mutex.synchronize do
      @@timers.reject! { |e| e.fiber.same?(fiber) && e.kind.select_timeout? }
    end
  end

  private def self.enqueue_entry(entry : TimerEntry) : Nil
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

  private def self.timer_loop(advance_ch : Channel(Time::Span), done_ch : Channel(Nil)) : Nil
    while duration = advance_ch.receive?
      target = @@virtual_now + duration

      loop do
        entry = @@timers_mutex.synchronize do
          e = @@timers.first?
          (e && e.wake_at <= target) ? @@timers.shift : nil
        end

        break unless entry

        @@virtual_now = entry.wake_at
        enqueue_entry(entry)
        sleep 1.millisecond # allow the woken fiber to run and register any chained sleep before rechecking
      end

      @@virtual_now = target
      done_ch.send(nil)
    end

    loop do
      entry = @@timers_mutex.synchronize { @@timers.shift? }
      break unless entry
      enqueue_entry(entry)
    end
  end

  private def self.insert_timer(entry : TimerEntry) : Nil
    idx = @@timers.bsearch_index { |e| e.wake_at >= entry.wake_at } || @@timers.size
    @@timers.insert(idx, entry)
  end
end
