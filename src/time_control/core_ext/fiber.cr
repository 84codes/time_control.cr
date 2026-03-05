class Fiber
  # :nodoc:
  def timeout(timeout : Time::Span, select_action : Channel::TimeoutAction) : Nil
    @timeout_select_action = select_action
    TimeControl.intercept do |ctx|
      ctx.add_select_timeout(self, timeout)
      return
    end
    timeout_event.add(timeout)
  end

  # :nodoc:
  def cancel_timeout : Nil
    return unless @timeout_select_action
    @timeout_select_action = nil
    TimeControl.intercept do |ctx|
      ctx.cancel_select_timeout(self)
      return
    end
    @timeout_event.try &.delete
  end
end
