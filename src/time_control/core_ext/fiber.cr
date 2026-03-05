class Fiber
  # :nodoc:
  def timeout(timeout : Time::Span, select_action : Channel::TimeoutAction) : Nil
    if ctx = TimeControl.context
      @timeout_select_action = select_action
      ctx.add_select_timeout(self, timeout)
    else
      @timeout_select_action = select_action
      timeout_event.add(timeout)
    end
  end

  # :nodoc:
  def cancel_timeout : Nil
    if ctx = TimeControl.context
      return unless @timeout_select_action
      @timeout_select_action = nil
      ctx.cancel_select_timeout(self)
    else
      return unless @timeout_select_action
      @timeout_select_action = nil
      @timeout_event.try &.delete
    end
  end
end
