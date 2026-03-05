class Fiber
  # :nodoc:
  def timeout(timeout : Time::Span, select_action : Channel::TimeoutAction) : Nil
    if TimeControl.enabled?
      @timeout_select_action = select_action
      TimeControl.add_select_timeout(self, timeout)
    else
      @timeout_select_action = select_action
      timeout_event.add(timeout)
    end
  end

  # :nodoc:
  def cancel_timeout : Nil
    if TimeControl.enabled?
      return unless @timeout_select_action
      @timeout_select_action = nil
      TimeControl.cancel_select_timeout(self)
    else
      return unless @timeout_select_action
      @timeout_select_action = nil
      @timeout_event.try &.delete
    end
  end
end
