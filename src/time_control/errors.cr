module TimeControl
  # Base class for all `TimeControl` errors.
  abstract class Error < ::Exception
  end

  # Raised when a `TimeControl` operation is attempted outside of a
  # `TimeControl.control` block.
  class NotEnabledError < Error
  end

  # Raised when the `TimeControl.control` block exits with virtual timers
  # still pending, indicating that not all scheduled sleeps or timeouts
  # were advanced past.
  #
  # The number of pending timers is available via `#count`.
  class PendingTimersError < Error
    # Returns the number of timers that were still pending.
    getter count : Int32

    def initialize(@count : Int32)
      super("#{@count} timer(s) were still pending when the control block exited")
    end
  end
end
