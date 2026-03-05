require "./spec_helper"

describe TimeControl do
  describe "virtual Time.now and Time.instant" do
    it "freezes Time.utc while no time is advanced" do
      TimeControl.control do |_remote|
        t0 = Time.utc
        Fiber.yield
        (Time.utc - t0).should eq(Time::Span.zero)
      end
    end

    it "freezes Time.instant while no time is advanced" do
      TimeControl.control do |_remote|
        t0 = Time.instant
        Fiber.yield
        (Time.instant - t0).should eq(Time::Span.zero)
      end
    end

    it "advances Time.utc by the duration passed to remote.advance" do
      TimeControl.control do |remote|
        t0 = Time.utc
        remote.advance(5.seconds)
        (Time.utc - t0).should eq(5.seconds)
      end
    end

    it "advances Time.instant by the duration passed to remote.advance" do
      TimeControl.control do |remote|
        t0 = Time.instant
        remote.advance(5.seconds)
        (Time.instant - t0).should eq(5.seconds)
      end
    end

    it "Time.utc reflects the virtual instant at which a sleeping fiber wakes" do
      result = Channel(Time).new

      TimeControl.control do |remote|
        t0 = Time.utc
        spawn do
          sleep 3.seconds
          result.send(Time.utc)
        end

        remote.advance(5.seconds)
        woke_at = result.receive
        (woke_at - t0).should eq(3.seconds)
      end
    end

    it "Time.instant reflects the virtual instant at which a sleeping fiber wakes" do
      result = Channel(Time::Span).new

      TimeControl.control do |remote|
        t0 = Time.instant
        spawn do
          sleep 3.seconds
          result.send(Time.instant - t0)
        end

        remote.advance(5.seconds)
        result.receive.should eq(3.seconds)
      end
    end
  end


  it "advances time past a sleeping fiber" do
    result = Channel(Time::Instant).new

    TimeControl.control do |remote|
      spawn do
        sleep 1.second
        result.send(TimeControl.virtual_now)
      end

      remote.advance(2.seconds)
      woke_at = result.receive

      (woke_at - TimeControl.virtual_now).total_seconds.should be_close(-1.0, 0.001)
    end
  end

  it "wakes fibers in time order" do
    order = Channel(Int32).new(3)
    done = Channel(Nil).new

    TimeControl.control do |remote|
      spawn { sleep 2.seconds; order.send(2) }
      spawn { sleep 1.second; order.send(1) }
      spawn do
        sleep 3.seconds
        order.send(3)
        done.send(nil)
      end

      remote.advance(3.seconds)
      done.receive

      order.receive.should eq(1)
      order.receive.should eq(2)
      order.receive.should eq(3)
    end
  end

  it "handles select timeout" do
    ch = Channel(Int32).new
    result = Channel(Symbol).new

    TimeControl.control do |remote|
      spawn do
        select
        when ch.receive
          result.send(:received)
        when timeout(1.second)
          result.send(:timed_out)
        end
      end

      remote.advance(2.seconds)
      result.receive.should eq(:timed_out)
    end
  end

  it "does not fire select timeout when channel delivers first" do
    ch = Channel(Int32).new
    result = Channel(Symbol).new

    TimeControl.control do |_remote|
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

    TimeControl.control do |remote|
      spawn do
        select
        when ch.receive
          result.send(:received)
        when timeout(2.seconds)
          result.send(:timed_out)
        end
      end

      remote.advance(1.second)
      ch.send(42)
      result.receive.should eq(:received)

      remote.advance(2.seconds)

      select
      when result.receive
        fail "timeout fired after channel had already delivered"
      else
      end
    end
  end

  it "handles chained sleeps within a single advance" do
    steps = Channel(Int32).new(2)

    TimeControl.control do |remote|
      spawn do
        sleep 1.second
        steps.send(1)
        sleep 1.second
        steps.send(2)
      end

      remote.advance(2.seconds)
      steps.receive.should eq(1)
      steps.receive.should eq(2)
    end
  end

  it "raises NotEnabledError when accessed outside a control block" do
    expect_raises(TimeControl::NotEnabledError) do
      TimeControl.virtual_now
    end
  end

  it "raises if timers are still pending when the control block exits" do
    expect_raises(TimeControl::PendingTimersError, /1 timer\(s\) were still pending/) do
      TimeControl.control do |_remote|
        spawn { sleep 1.second }
        Fiber.yield
      end
    end
  end

  describe "real time moves fast" do
    it "a long sleep returns near-instantly in real time" do
      t0 = Time.instant
      TimeControl.control do |remote|
        spawn { sleep 1.hour }
        remote.advance(1.hour)
      end
      (Time.instant - t0).should be_close(Time::Span.zero, 1.second)
    end

    it "many long sleeps return near-instantly in real time" do
      t0 = Time.instant
      TimeControl.control do |remote|
        10.times { spawn { sleep 1.hour } }
        remote.advance(1.hour)
      end
      (Time.instant - t0).should be_close(Time::Span.zero, 1.second)
    end
  end

  it "does not advance virtual time for sleep(0)" do
    TimeControl.control do |_remote|
      t0 = TimeControl.virtual_now
      sleep 0.seconds
      TimeControl.virtual_now.should eq(t0)
    end
  end

  describe "nested spawns with nested timeouts" do
    it "inner spawn completes before the outer spawn that spawned it" do
      results = Channel(String).new(2)

      TimeControl.control do |remote|
        spawn do
          sleep 1.second
          spawn do
            sleep 1.second
            results.send("inner")
          end
          sleep 2.seconds
          results.send("outer")
        end

        remote.advance(3.seconds)
        results.receive.should eq("inner")
        results.receive.should eq("outer")
      end
    end


    it "wakes a chain of spawned fibers each sleeping in sequence" do
      # Each level wakes, spawns the next level, then the next level sleeps.
      # advance(3s) must process all three timers registered at different times
      # during the advance itself.
      results = Channel(Int32).new(3)

      TimeControl.control do |remote|
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

        remote.advance(3.seconds)

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

      TimeControl.control do |remote|
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

        remote.advance(1.seconds)
        outer_result.receive.should eq(:timed_out)

        remote.advance(1.seconds)
        inner_result.receive.should eq(:timed_out)
      end
    end

    it "handles mixed sleep and select timeout across spawn levels" do
      results = Channel(String).new(3)
      trigger = Channel(Nil).new

      TimeControl.control do |remote|
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

        remote.advance(1.seconds)
        results.receive.should eq("outer slept")

        remote.advance(1.seconds)
        results.receive.should eq("inner timed out")
      end
    end
  end
end
