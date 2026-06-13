module TimeControl
  # Base class for all `TimeControl` errors.
  abstract class Error < ::Exception
  end

  # Raised when the `TimeControl.control` block exits with virtual timers
  # still pending, indicating that not all scheduled sleeps or timeouts
  # were advanced past.
  #
  # The number of pending timers is available via `#count` and the names of
  # the fibers that owned them via `#fiber_names`.
  class PendingTimersError < Error
    # Returns the number of timers that were still pending.
    getter count : Int32

    # Returns the names of the fibers whose timers were still pending.
    getter fiber_names : Array(String)

    def initialize(@fiber_names : Array(String))
      @count = @fiber_names.size
      super("#{@count} timer(s) were still pending when the control block exited: #{@fiber_names.join(", ")}")
    end
  end
end
