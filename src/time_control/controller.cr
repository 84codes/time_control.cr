module TimeControl
  # Controller object yielded by `TimeControl.control`. Used to advance
  # virtual time from within the control block.
  class Controller
    # :nodoc:
    def initialize(@ctx : Context)
    end

    # Advances virtual time by *duration*.
    #
    # Wakes all sleeping fibers and select timeouts that fall within the
    # advanced window, in chronological order. Blocks until all woken fibers
    # have had a chance to run before returning.
    #
    # ```
    # controller.advance(5.seconds)
    # ```
    def advance(duration : Time::Span) : Nil
      Fiber.yield
      @ctx.advance(duration)
    end

    # Advances virtual time to the next pending timer entry.
    #
    # Raises if there are no pending timers.
    #
    # ```
    # controller.advance
    # ```
    def advance : Nil
      Fiber.yield
      @ctx.advance
    end
  end
end
