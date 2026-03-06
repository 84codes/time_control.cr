require "./spec_helper"

describe TimeControl do
  describe "virtual Time.now and Time.instant" do
    it "freezes Time.utc while no time is advanced" do
      TimeControl.control do |_controller|
        t0 = Time.utc
        Fiber.yield
        (Time.utc - t0).should eq(Time::Span.zero)
      end
    end

    it "freezes Time.instant while no time is advanced" do
      TimeControl.control do |_controller|
        t0 = Time.instant
        Fiber.yield
        (Time.instant - t0).should eq(Time::Span.zero)
      end
    end

    it "advances Time.utc by the duration passed to controller.advance" do
      TimeControl.control do |controller|
        t0 = Time.utc
        controller.advance(5.seconds)
        (Time.utc - t0).should eq(5.seconds)
      end
    end

    it "advances Time.instant by the duration passed to controller.advance" do
      TimeControl.control do |controller|
        t0 = Time.instant
        controller.advance(5.seconds)
        (Time.instant - t0).should eq(5.seconds)
      end
    end

    it "Time.utc reflects the virtual instant at which a sleeping fiber wakes" do
      result = Channel(Time).new

      TimeControl.control do |controller|
        t0 = Time.utc
        spawn do
          sleep 3.seconds
          result.send(Time.utc)
        end

        controller.advance(5.seconds)
        woke_at = result.receive
        (woke_at - t0).should eq(3.seconds)
      end
    end

    it "Time.instant reflects the virtual instant at which a sleeping fiber wakes" do
      result = Channel(Time::Span).new

      TimeControl.control do |controller|
        t0 = Time.instant
        spawn do
          sleep 3.seconds
          result.send(Time.instant - t0)
        end

        controller.advance(5.seconds)
        result.receive.should eq(3.seconds)
      end
    end
  end

  it "advances time past a sleeping fiber" do
    result = Channel(Time::Instant).new

    TimeControl.control do |controller|
      spawn do
        sleep 1.second
        result.send(Time.instant)
      end

      controller.advance(2.seconds)
      woke_at = result.receive

      (woke_at - Time.instant).total_seconds.should be_close(-1.0, 0.001)
    end
  end

  it "advance with no args advances to the next pending timer" do
    TimeControl.control do |controller|
      t0 = Time.instant
      spawn { sleep 3.seconds }

      controller.advance
      (Time.instant - t0).should eq(3.seconds)
    end
  end

  it "advance with no args raises when there are no pending timers" do
    TimeControl.control do |controller|
      expect_raises(Exception, "no pending timers") do
        controller.advance
      end
    end
  end

  it "wakes fibers in time order" do
    order = Channel(Int32).new(3)
    done = Channel(Nil).new

    TimeControl.control do |controller|
      spawn { sleep 2.seconds; order.send(2) }
      spawn { sleep 1.second; order.send(1) }
      spawn do
        sleep 3.seconds
        order.send(3)
        done.send(nil)
      end

      controller.advance(3.seconds)
      done.receive

      order.receive.should eq(1)
      order.receive.should eq(2)
      order.receive.should eq(3)
    end
  end

  it "handles select timeout" do
    ch = Channel(Int32).new
    result = Channel(Symbol).new

    TimeControl.control do |controller|
      spawn do
        select
        when ch.receive
          result.send(:received)
        when timeout(1.second)
          result.send(:timed_out)
        end
      end

      controller.advance(2.seconds)
      result.receive.should eq(:timed_out)
    end
  end

  it "does not fire select timeout when channel delivers first" do
    ch = Channel(Int32).new
    result = Channel(Symbol).new

    TimeControl.control do |_controller|
      spawn do
        select
        when ch.receive
          result.send(:received)
        when timeout(1.second)
          result.send(:timed_out)
        end
      end

      ch.send(42)
      result.receive.should eq(:received)
    end
  end

  it "cancels a pending virtual timeout when the channel delivers before the timeout expires" do
    ch = Channel(Int32).new
    result = Channel(Symbol).new

    TimeControl.control do |controller|
      spawn do
        select
        when ch.receive
          result.send(:received)
        when timeout(2.seconds)
          result.send(:timed_out)
        end
      end

      controller.advance(1.second)
      ch.send(42)
      result.receive.should eq(:received)

      controller.advance(2.seconds)

      select
      when result.receive
        fail "timeout fired after channel had already delivered"
      else
      end
    end
  end

  it "handles chained sleeps within a single advance" do
    steps = Channel(Int32).new(2)

    TimeControl.control do |controller|
      spawn do
        sleep 1.second
        steps.send(1)
        sleep 1.second
        steps.send(2)
      end

      controller.advance(2.seconds)
      steps.receive.should eq(1)
      steps.receive.should eq(2)
    end
  end

  it "raises if timers are still pending when the control block exits" do
    ex = expect_raises(TimeControl::PendingTimersError, /1 timer\(s\) were still pending/) do
      TimeControl.control do |_controller|
        spawn { sleep 1.second }
        Fiber.yield
      end
    end
    ex.count.should eq(1)
  end

  describe "IO timeouts" do
    it "fires read_timeout when virtual time advances past it" do
      r, w = IO.pipe
      result = Channel(Symbol).new

      TimeControl.control do |controller|
        spawn do
          r.read_timeout = 2.seconds
          begin
            r.read(Bytes.new(1))
            result.send(:read)
          rescue IO::TimeoutError
            result.send(:timed_out)
          end
        end

        controller.advance(3.seconds)
        result.receive.should eq(:timed_out)
      end
      w.close
      r.close
    end

    it "does not fire read_timeout when data arrives before the deadline" do
      r, w = IO.pipe
      result = Channel(Symbol).new

      TimeControl.control do |_controller|
        spawn do
          r.read_timeout = 5.seconds
          buf = Bytes.new(1)
          begin
            r.read(buf)
            result.send(:read)
          rescue IO::TimeoutError
            result.send(:timed_out)
          end
        end

        w.write(Bytes[42])
        result.receive.should eq(:read)
        w.close
        r.close
      end
    end

    it "fires read_timeout at the correct virtual time" do
      r, w = IO.pipe
      result = Channel(Time::Span).new

      TimeControl.control do |controller|
        t0 = Time.instant
        spawn do
          r.read_timeout = 3.seconds
          begin
            r.read(Bytes.new(1))
          rescue IO::TimeoutError
            result.send(Time.instant - t0)
          end
        end

        controller.advance(5.seconds)
        elapsed = result.receive
        elapsed.should be_close(3.seconds, 10.milliseconds)
        w.close
        r.close
      end
    end

    it "advance with no args advances to the next IO timeout" do
      r, w = IO.pipe
      result = Channel(Symbol).new

      TimeControl.control do |controller|
        t0 = Time.instant
        spawn do
          r.read_timeout = 2.seconds
          begin
            r.read(Bytes.new(1))
          rescue IO::TimeoutError
            result.send(:timed_out)
          end
        end

        controller.advance
        (Time.instant - t0).should eq(2.seconds)
        result.receive.should eq(:timed_out)
        w.close
        r.close
      end
    end
  end

  describe "real time moves fast" do
    it "a long sleep returns near-instantly in real time" do
      t0 = Time.instant
      TimeControl.control do |controller|
        spawn { sleep 1.hour }
        controller.advance(1.hour)
      end
      (Time.instant - t0).should be_close(Time::Span.zero, 1.second)
    end

    it "many long sleeps return near-instantly in real time" do
      t0 = Time.instant
      TimeControl.control do |controller|
        10.times { spawn { sleep 1.hour } }
        controller.advance(1.hour)
      end
      (Time.instant - t0).should be_close(Time::Span.zero, 1.second)
    end
  end

  it "does not advance virtual time for sleep(0)" do
    TimeControl.control do |_controller|
      t0 = Time.instant
      t0_utc = Time.utc
      sleep 0.seconds
      Time.instant.should eq(t0)
      Time.utc.should eq(t0_utc)
    end
  end

  describe "nested spawns with nested timeouts" do
    it "inner spawn completes before the outer spawn that spawned it" do
      results = Channel(String).new(2)

      TimeControl.control do |controller|
        spawn do
          sleep 1.second
          spawn do
            sleep 1.second
            results.send("inner")
          end
          sleep 2.seconds
          results.send("outer")
        end

        controller.advance(3.seconds)
        results.receive.should eq("inner")
        results.receive.should eq("outer")
      end
    end

    it "wakes a chain of spawned fibers each sleeping in sequence" do
      # Each level wakes, spawns the next level, then the next level sleeps.
      # advance(3s) must process all three timers registered at different times
      # during the advance itself.
      results = Channel(Int32).new(3)

      TimeControl.control do |controller|
        spawn do
          sleep 1.second
          results.send(1)
          spawn do
            sleep 1.second
            results.send(2)
            spawn do
              sleep 1.second
              results.send(3)
            end
          end
        end

        controller.advance(3.seconds)

        results.receive.should eq(1)
        results.receive.should eq(2)
        results.receive.should eq(3)
      end
    end

    it "handles a select timeout that spawns a fiber with its own select timeout" do
      # Outer fiber times out at 1s and spawns an inner fiber with a 1s timeout.
      # The inner timeout must fire when we advance to t=2s.
      outer_result = Channel(Symbol).new
      inner_result = Channel(Symbol).new
      trigger = Channel(Int32).new

      TimeControl.control do |controller|
        spawn do
          select
          when trigger.receive
            outer_result.send(:received)
          when timeout(1.second)
            outer_result.send(:timed_out)
            spawn do
              select
              when trigger.receive
                inner_result.send(:received)
              when timeout(1.second)
                inner_result.send(:timed_out)
              end
            end
          end
        end

        controller.advance(1.seconds)
        outer_result.receive.should eq(:timed_out)

        controller.advance(1.seconds)
        inner_result.receive.should eq(:timed_out)
      end
    end

    it "handles mixed sleep and select timeout across spawn levels" do
      results = Channel(String).new(3)
      trigger = Channel(Nil).new

      TimeControl.control do |controller|
        spawn do
          sleep 1.second
          results.send("outer slept")

          spawn do
            select
            when trigger.receive
              results.send("inner received")
            when timeout(1.second)
              results.send("inner timed out")
            end
          end
        end

        controller.advance(1.seconds)
        results.receive.should eq("outer slept")

        controller.advance(1.seconds)
        results.receive.should eq("inner timed out")
      end
    end
  end

  describe "start_time" do
    it "accepts a Time object and sets initial Time.utc" do
      start = Time.utc(2030, 6, 15, 12, 0, 0)
      TimeControl.control(start) do |_controller|
        Time.utc.should eq(start)
      end
    end

    it "accepts an ISO 8601 datetime string with Z suffix" do
      TimeControl.control("2030-06-15T12:00:00Z") do |_controller|
        Time.utc.should eq(Time.utc(2030, 6, 15, 12, 0, 0))
      end
    end

    it "accepts a datetime string without timezone (assumed UTC)" do
      TimeControl.control("2030-06-15T12:00:00") do |_controller|
        Time.utc.should eq(Time.utc(2030, 6, 15, 12, 0, 0))
      end
    end

    it "accepts a date-only string (midnight UTC)" do
      TimeControl.control("2030-06-15") do |_controller|
        Time.utc.should eq(Time.utc(2030, 6, 15, 0, 0, 0))
      end
    end

    it "accepts a time-only string with today's real date" do
      today = Time.utc
      TimeControl.control("09:30:00") do |_controller|
        t = Time.utc
        t.year.should eq(today.year)
        t.month.should eq(today.month)
        t.day.should eq(today.day)
        t.hour.should eq(9)
        t.minute.should eq(30)
        t.second.should eq(0)
      end
    end

    it "accepts a time-only string without seconds" do
      TimeControl.control("09:30") do |_controller|
        t = Time.utc
        t.hour.should eq(9)
        t.minute.should eq(30)
        t.second.should eq(0)
      end
    end

    it "advances Time.utc correctly from a custom start time" do
      start = Time.utc(2030, 1, 1, 0, 0, 0)
      TimeControl.control(start) do |controller|
        controller.advance(1.hour)
        Time.utc.should eq(Time.utc(2030, 1, 1, 1, 0, 0))
      end
    end

    it "raises ArgumentError for an unparseable string" do
      expect_raises(ArgumentError) do
        TimeControl.control("not a time") { }
      end
    end
  end
end
