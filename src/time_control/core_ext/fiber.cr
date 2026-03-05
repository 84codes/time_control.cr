class Fiber
  # :nodoc:
  def timeout(timeout : Time::Span, select_action : Channel::TimeoutAction) : Nil
    @timeout_select_action = select_action
    if TimeControl.enabled?
      TimeControl.context.add_select_timeout(self, timeout)
    else
      timeout_event.add(timeout)
    end
  end

  # :nodoc:
  def cancel_timeout : Nil
    return unless @timeout_select_action
    @timeout_select_action = nil
    if TimeControl.enabled?
      TimeControl.context.cancel_select_timeout(self)
    else
      @timeout_event.try &.delete
    end
  end
end
