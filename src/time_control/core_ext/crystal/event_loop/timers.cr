{% if Crystal::EventLoop.all_subclasses.any? { |subclass| subclass.name == "Crystal::EventLoop::Polling" } %}
  class Crystal::PointerPairingHeap(T)
    # :nodoc:
    #
    # Read-only traversal of every node in the heap, in unspecified order.
    def time_control_each(& : Pointer(T) ->) : Nil
      node = @head
      return if node.null?

      stack = [node]
      until stack.empty?
        n = stack.pop
        yield n
        child = n.value.heap_child?
        stack << child unless child.null?
        sibling = n.value.heap_next?
        stack << sibling unless sibling.null?
      end
    end
  end

  struct Crystal::EventLoop::Timers(T)
    # :nodoc:
    def time_control_each(& : Pointer(T) ->) : Nil
      @heap.time_control_each { |event| yield event }
    end
  end
{% end %}
