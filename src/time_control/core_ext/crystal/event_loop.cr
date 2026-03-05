# Patch every Crystal::EventLoop subclass that defines sleep so we intercept
# it regardless of which event loop implementation is used in a given build.
{% for subclass in Crystal::EventLoop.all_subclasses %}
  {% if subclass.methods.any? { |m| m.name == "sleep" } %}
    class {{ subclass.id }}
      # :nodoc:
      def sleep(duration : ::Time::Span) : Nil
        if duration.total_nanoseconds > 0
          TimeControl.intercept do |ctx|
            ctx.add_sleep(Fiber.current, duration)
            Fiber.suspend
            return
          end
        end
        previous_def
      end
    end
  {% end %}
{% end %}
