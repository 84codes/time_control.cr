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
  end
{% end %}
