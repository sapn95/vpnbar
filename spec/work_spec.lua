local work = require("vpnbar.work")

describe("work", function()
  it("starts idle", function()
    assert.is_false(work.busy(work.new(), 0))
  end)

  it("is busy from the first claim to the last release", function()
    local state = work.new()
    work.begin(state, 100)
    assert.is_true(work.busy(state, 100))
    work.finish(state)
    assert.is_false(work.busy(state, 100))
  end)

  it("stays busy while a second job is still running", function()
    -- The case this exists for: a click opens an app's window while the timer
    -- reads the state. The read finishing first must not clear the mark for the
    -- click, which is the longer of the two.
    local state = work.new()
    work.begin(state, 100)
    work.begin(state, 100)
    work.finish(state)
    assert.is_true(work.busy(state, 100))
    work.finish(state)
    assert.is_false(work.busy(state, 100))
  end)

  it("gives up on a job that never finished", function()
    local state = work.new()
    work.begin(state, 100, 20)
    assert.is_true(work.busy(state, 119))
    assert.is_false(work.busy(state, 120))
  end)

  it("forgets the expired job rather than expiring it again for ever", function()
    local state = work.new()
    work.begin(state, 100, 20)
    assert.is_false(work.busy(state, 200))
    -- Whatever went missing is gone, so the next real job is timed from now and
    -- not against a deadline it never asked for.
    work.begin(state, 300, 20)
    assert.is_true(work.busy(state, 310))
  end)

  it("takes the longest deadline of the jobs in flight", function()
    local state = work.new()
    work.begin(state, 100, 5)
    work.begin(state, 100, 60)
    assert.is_true(work.busy(state, 150))
  end)

  it("never counts below zero, so a stray release cannot hide the next job", function()
    local state = work.new()
    work.finish(state)
    work.finish(state)
    work.begin(state, 100)
    assert.is_true(work.busy(state, 100))
  end)

  it("treats no state at all as idle", function()
    assert.is_false(work.busy(nil, 0))
    assert.is_nil(work.begin(nil, 0))
    assert.is_nil(work.finish(nil))
  end)

  describe("WAKE_READS", function()
    it("looks several times, in order, over the first quarter minute", function()
      local previous = 0
      for _, read in ipairs(work.WAKE_READS) do
        assert.is_true(read.after > previous)
        previous = read.after
      end
      assert.is_true(#work.WAKE_READS > 1)
      assert.is_true(previous <= 30)
    end)

    it("only lets the last look start something", function()
      -- Waking is not a network. An early look reports; the one that may bring
      -- a tunnel up waits until there is something to bring it up over.
      for index, read in ipairs(work.WAKE_READS) do
        if index < #work.WAKE_READS then
          assert.is_not_true(read.autoconnect)
        else
          assert.is_true(read.autoconnect)
        end
      end
    end)

    it("comes back well inside a job's lifetime", function()
      -- Every read is claimed at the moment of the wake, so the last one has to
      -- land before the deadline expires it or the mark would go out early.
      assert.is_true(work.WAKE_READS[#work.WAKE_READS].after < work.LIFETIME)
    end)
  end)
end)
describe("work.freshStart", function()
  it("is a fresh start when nothing has happened yet", function()
    assert.is_true(work.freshStart(nil, 1000))
  end)

  it("swallows the unlock that follows a wake, because they are one arrival", function()
    assert.is_false(work.freshStart(1000, 1003), "three seconds later is the same person waking up")
    assert.is_false(work.freshStart(1000, 1000 + work.FRESH_START_DEBOUNCE - 1))
  end)

  it("lets the next real one through once the schedule has had its time", function()
    assert.is_true(work.freshStart(1000, 1000 + work.FRESH_START_DEBOUNCE))
    assert.is_true(work.freshStart(1000, 5000))
  end)

  it("covers the whole wake schedule, so both events cannot run it twice", function()
    local last = work.WAKE_READS[#work.WAKE_READS].after
    assert.is_true(work.FRESH_START_DEBOUNCE >= last, "debounce outlasts the last wake read")
  end)

  it("says yes rather than swallowing one when the clock makes no sense", function()
    assert.is_true(work.freshStart("nonsense", 1000))
    assert.is_true(work.freshStart(1000, nil))
  end)

  -- os.time is wall clock, and a correction lands across a wake, which is the
  -- moment this gets asked. Reading a jump backwards as quiet would suppress
  -- every wake and unlock for as far back as the clock went.
  it("treats a clock that went backwards as a fresh start, not as quiet", function()
    assert.is_true(work.freshStart(1000, 990))
    assert.is_true(work.freshStart(1000, 1000 - 86400))
  end)
end)

describe("work.withinFreshStart", function()
  it("is the window the last fresh start opened", function()
    assert.is_true(work.withinFreshStart(1000, 1000))
    assert.is_true(work.withinFreshStart(1000, 1000 + work.FRESH_START_DEBOUNCE - 1))
    assert.is_false(work.withinFreshStart(1000, 1000 + work.FRESH_START_DEBOUNCE))
  end)

  it("covers every wake read, which is the point of it", function()
    local last = work.WAKE_READS[#work.WAKE_READS].after
    assert.is_true(work.withinFreshStart(1000, 1000 + last))
  end)

  it("is false before any fresh start, and across a clock that went backwards", function()
    assert.is_false(work.withinFreshStart(nil, 1000))
    assert.is_false(work.withinFreshStart(1000, 990))
    assert.is_false(work.withinFreshStart("nonsense", 1000))
  end)

  it("is the other side of freshStart", function()
    for _, since in ipairs({ 0, 5, 19, 20, 21, 500 }) do
      assert.not_equals(
        work.freshStart(1000, 1000 + since),
        work.withinFreshStart(1000, 1000 + since),
        "since=" .. since
      )
    end
  end)
end)
