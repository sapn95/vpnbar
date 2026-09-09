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
