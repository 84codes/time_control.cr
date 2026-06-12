{% if Crystal::EventLoop.all_subclasses.any? { |subclass| subclass.name == "Crystal::EventLoop::Polling" } %}
  abstract class Crystal::EventLoop::Polling
    # :nodoc:
    protected def add_timer(event : Crystal::EventLoop::Polling::Event*) : Nil
      if wake_at = event.value.wake_at?
        if event.value.type.io_read? || event.value.type.io_write?
          TimeControl.when_controlling do |ctx|
            ctx.add_io_timeout(wake_at)
          end
        end
      end
      previous_def
    end

    # :nodoc:
    #
    # Removes every sleep and select-timeout timer currently registered on this
    # loop and returns them so they can be re-registered on the virtual clock.
    # IO-operation timeouts are left in place (they're tied to a live IO wait).
    def time_control_extract_pending_timers
      extracted = [] of {Fiber, Time::Instant, Crystal::EventLoop::Polling::Event*, Crystal::EventLoop::Polling::Event::Type}
      @timers_lock.sync do
        @timers.time_control_each do |event|
          type = event.value.type
          if (type.sleep? || type.select_timeout?) && (wake_at = event.value.wake_at?)
            extracted << {event.value.fiber, wake_at, event, type}
          end
        end
        # Raw delete + re-arm under the lock: delete_timer would re-take the
        # non-reentrant @timers_lock.
        extracted.each { |entry| @timers.delete(entry[2]) }
        system_set_timer(@timers.next_ready?)
      end
      extracted
    end
  end

  module TimeControl
    # :nodoc:
    #
    # Adopts fibers already sleeping or waiting on a select timeout on the real
    # event loop when control starts, across all execution contexts, so they're
    # governed by the virtual clock instead of waking in real time.
    def self.adopt_pending_timers(ctx : Context) : Nil
      seen = Set(UInt64).new
      Fiber::ExecutionContext.each do |execution_context|
        event_loop = execution_context.event_loop
        next unless event_loop.is_a?(Crystal::EventLoop::Polling)
        next unless seen.add?(event_loop.object_id)

        event_loop.time_control_extract_pending_timers.each do |(fiber, wake_at, event, type)|
          case type
          when .sleep?
            ctx.adopt_sleep(fiber, wake_at, -> { event.value.timed_out!; fiber.enqueue })
          when .select_timeout?
            ctx.adopt_select_timeout(fiber, wake_at)
          end
        end
      end
    end
  end
{% end %}
