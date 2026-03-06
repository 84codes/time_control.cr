require "./spec_helper"

describe "TimeControl multi-threaded" do
  it "fires read timeouts across isolated contexts in virtual time order" do
    order = Channel(Int32).new(3)
    pipes = Array.new(3) { IO.pipe }
    contexts = [] of Fiber::ExecutionContext::Isolated

    TimeControl.control do |controller|
      pipes.each_with_index do |(r, _w), i|
        contexts << Fiber::ExecutionContext::Isolated.new("reader-#{i + 1}") do
          r.read_timeout = (i + 1).seconds
          begin
            r.read(Bytes.new(1))
          rescue IO::TimeoutError
            order.send(i + 1)
          end
        end
      end

      controller.advance(3.seconds)

      order.receive.should eq(1)
      order.receive.should eq(2)
      order.receive.should eq(3)
    end

    contexts.each(&.wait)
    pipes.each { |(r, w)| r.close; w.close }
  end

  it "data arriving at virtual 1s prevents a 3s read timeout" do
    r, w = IO.pipe
    result = Channel(Symbol).new
    reader = uninitialized Fiber::ExecutionContext::Isolated
    writer = uninitialized Fiber::ExecutionContext::Isolated

    TimeControl.control do |controller|
      reader = Fiber::ExecutionContext::Isolated.new("reader") do
        r.read_timeout = 3.seconds
        begin
          r.read(Bytes.new(1))
          result.send(:read)
        rescue IO::TimeoutError
          result.send(:timed_out)
        end
      end

      writer = Fiber::ExecutionContext::Isolated.new("writer") do
        sleep 1.second
        w.write(Bytes[42])
      end

      controller.advance(3.seconds)
      result.receive.should eq(:read)
    end

    reader.wait
    writer.wait
    r.close
    w.close
  end

  it "IO timeout chains into a sleep inside the same isolated context" do
    r, w = IO.pipe
    steps = Channel(String).new(2)
    ctx = uninitialized Fiber::ExecutionContext::Isolated

    TimeControl.control do |controller|
      ctx = Fiber::ExecutionContext::Isolated.new("chained") do
        r.read_timeout = 1.second
        begin
          r.read(Bytes.new(1))
        rescue IO::TimeoutError
          steps.send("io timed out")
          sleep 1.second
          steps.send("slept")
        end
      end

      controller.advance(2.seconds)
      steps.receive.should eq("io timed out")
      steps.receive.should eq("slept")
    end
    ctx.wait
    r.close
    w.close
  end

  it "IO timeout and select timeout across isolated contexts both fire in one advance" do
    io_done = Channel(Symbol).new
    select_done = Channel(Symbol).new
    r, w = IO.pipe
    trigger = Channel(Nil).new
    io_ctx = uninitialized Fiber::ExecutionContext::Isolated
    select_ctx = uninitialized Fiber::ExecutionContext::Isolated

    TimeControl.control do |controller|
      io_ctx = Fiber::ExecutionContext::Isolated.new("io-reader") do
        r.read_timeout = 1.second
        begin
          r.read(Bytes.new(1))
        rescue IO::TimeoutError
          io_done.send(:timed_out)
        end
      end

      select_ctx = Fiber::ExecutionContext::Isolated.new("select-waiter") do
        select
        when trigger.receive
          select_done.send(:received)
        when timeout(2.seconds)
          select_done.send(:timed_out)
        end
      end

      controller.advance(2.seconds)
      io_done.receive.should eq(:timed_out)
      select_done.receive.should eq(:timed_out)
    end

    io_ctx.wait
    select_ctx.wait
    r.close
    w.close
  end

  it "many isolated contexts all time out at the same virtual instant" do
    n = 8
    done = Channel(Nil).new(n)
    pipes = Array.new(n) { IO.pipe }
    contexts = [] of Fiber::ExecutionContext::Isolated

    TimeControl.control do |controller|
      pipes.each_with_index do |(r, _w), i|
        contexts << Fiber::ExecutionContext::Isolated.new("reader-#{i}") do
          r.read_timeout = 1.second
          begin
            r.read(Bytes.new(1))
          rescue IO::TimeoutError
            done.send(nil)
          end
        end
      end

      controller.advance(1.second)
      n.times { done.receive }
    end

    contexts.each(&.wait)
    pipes.each { |(r, w)| r.close; w.close }
  end

  it "interleaved sleeps and IO timeouts across isolated contexts resolve at correct virtual times" do
    events = Channel({String, Time::Span}).new(4)
    r1, w1 = IO.pipe
    r2, w2 = IO.pipe
    sleeper1 = uninitialized Fiber::ExecutionContext::Isolated
    io_reader1 = uninitialized Fiber::ExecutionContext::Isolated
    sleeper2 = uninitialized Fiber::ExecutionContext::Isolated
    io_reader2 = uninitialized Fiber::ExecutionContext::Isolated

    TimeControl.control do |controller|
      t0 = Time.instant

      sleeper1 = Fiber::ExecutionContext::Isolated.new("sleeper-1") do
        sleep 1.second
        events.send({"sleeper-1", Time.instant - t0})
      end

      io_reader1 = Fiber::ExecutionContext::Isolated.new("io-reader-1") do
        r1.read_timeout = 2.seconds
        begin
          r1.read(Bytes.new(1))
        rescue IO::TimeoutError
          events.send({"io-reader-1", Time.instant - t0})
        end
      end

      sleeper2 = Fiber::ExecutionContext::Isolated.new("sleeper-2") do
        sleep 3.seconds
        events.send({"sleeper-2", Time.instant - t0})
      end

      io_reader2 = Fiber::ExecutionContext::Isolated.new("io-reader-2") do
        r2.read_timeout = 4.seconds
        begin
          r2.read(Bytes.new(1))
        rescue IO::TimeoutError
          events.send({"io-reader-2", Time.instant - t0})
        end
      end

      controller.advance(4.seconds)

      results = Array.new(4) { events.receive }
      by_name = results.to_h

      by_name["sleeper-1"].should eq(1.second)
      by_name["io-reader-1"].should eq(2.seconds)
      by_name["sleeper-2"].should eq(3.seconds)
      by_name["io-reader-2"].should eq(4.seconds)
    end

    sleeper1.wait
    io_reader1.wait
    sleeper2.wait
    io_reader2.wait
    r1.close; w1.close
    r2.close; w2.close
  end
end
