--- What is running right now, so the menu bar can say so.
---
--- A count, because two jobs overlap all the time here — a click that opens an
--- app's window while the timer reads the state — and the first to finish must
--- not clear the mark while the second is still going.
---
--- A deadline as well, because a finish lost to an error somewhere else would
--- otherwise leave the mark up for the rest of the session. Past its deadline a
--- job is assumed gone and the icon goes back to reporting what it knows: a
--- mark that heals itself beats one that has to be believed.
---
--- No timers and no Hammerspoon. `now` is passed in, the same way
--- `autoconnect.plan` gets it.

local work = {}

--- How long one job may hold the mark before it is assumed lost. Long enough
--- for the slowest thing here — opening an app's window and clicking a row in
--- it — and short enough that a lost job is a blip rather than a permanent
--- spinner.
work.LIFETIME = 20

--- When to look again once the Mac wakes, and which of those looks may start
--- something.
---
--- Waking is not a network. Wi-Fi associates seconds after the screen comes
--- back, so a single read at the moment of the wake event reads a machine with
--- no route, reports every tunnel as down, and spends an autoconnect attempt on
--- a connection that could not possibly have come up. The early looks therefore
--- only report; the one allowed to bring a tunnel up happens once there is
--- something to bring it up over.
work.WAKE_READS = {
  { after = 2 },
  { after = 6 },
  { after = 15, autoconnect = true },
}

--- How long after one fresh start the next one is treated as the same event.
---
--- Long enough to cover `WAKE_READS`, so a wake and the unlock that follows it
--- cannot both run the schedule and both clear the failure record. A second
--- clearing would drop the cooldown that had just been spent, and hand the same
--- connection a second attempt inside the minute it is supposed to wait.
work.FRESH_START_DEBOUNCE = 20

--- Is this wake or unlock far enough from the last one to count as its own
--- fresh start?
---
--- Waking a locked Mac produces both events, seconds apart, in whichever order
--- the person types their password. They are one arrival and are worth one
--- schedule.
--- @param lastAt number|nil when the last fresh start was handled
--- @param now number seconds
--- @return boolean
function work.freshStart(lastAt, now)
  if type(lastAt) ~= "number" or type(now) ~= "number" then
    return true
  end
  return (now - lastAt) >= work.FRESH_START_DEBOUNCE
end

--- @return table owned by the caller, passed back to every function here
function work.new()
  return { count = 0 }
end

--- Claim the mark for one job.
--- @param state table|nil
--- @param now number seconds
--- @param lifetime number|nil seconds, defaults to work.LIFETIME
--- @return table|nil state
function work.begin(state, now, lifetime)
  if not state then
    return nil
  end
  state.count = (state.count or 0) + 1
  state.deadline = math.max(state.deadline or 0, now + (lifetime or work.LIFETIME))
  return state
end

--- Release it again. Never below zero: a finish without a begin is a bug in the
--- caller, and a negative count would swallow the next real job.
--- @param state table|nil
--- @return table|nil state
function work.finish(state)
  if not state then
    return nil
  end
  state.count = math.max((state.count or 0) - 1, 0)
  if state.count == 0 then
    state.deadline = nil
  end
  return state
end

--- Whether anything is running. Asking is what expires a job that never
--- finished, so this is the one place the state can go back to idle on its own.
--- @param state table|nil
--- @param now number seconds
--- @return boolean
function work.busy(state, now)
  if not state or (state.count or 0) <= 0 then
    return false
  end
  if state.deadline and now >= state.deadline then
    state.count = 0
    state.deadline = nil
    return false
  end
  return true
end

return work
