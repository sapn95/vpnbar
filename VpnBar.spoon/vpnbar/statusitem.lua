--- A client whose menu-bar item is gone, and what to do about it.
---
--- GlobalProtect is driven through its menu-bar item: the panel opens from it,
--- and Connect is in the panel
--- ([ADR 0001](../../docs/adr/0001-globalprotect-is-not-a-scutil-vpn.md)).
--- Measured on 2026-11-13: from the boot at 13:46 and for the whole day the
--- agent ran, macOS allowed its item, and `AXExtrasMenuBar` was nil, so every
--- press answered `GlobalProtect has no menu-bar item`. Bartender 7 had the item in
--- its Hide list and no longer listed it. Quitting Bartender and opening it
--- again brought the item back within 8 seconds. The same on 2026-11-10, for
--- eight minutes ([ADR 0048](../../docs/adr/0048-an-agent-that-stays-loaded.md)).
---
--- Pure, like the planner: the adapter measures, calls `plan` on every refresh
--- with a memory table it owns, and gets back at most one thing to do.

local backends = require("vpnbar.backends")

local statusitem = {}

--- The menu-bar managers vpnbar knows how to restart, in the order they are
--- tried. Data, so that a second one is a row and not a branch.
---
--- Named by bundle id, which a new version does not change. The process is
--- called `Bartender 7` today, so it is not named here at all: the adapter
--- reads the pid of the running application and follows that.
statusitem.MANAGERS = {
  { name = "Bartender", bundle = "com.surteesstudios.Bartender" },
}

--- Seconds an agent may run without its item before that counts as missing.
---
--- An agent that has just started has no item for a moment, and a restart of
--- the manager itself takes the items away and brings them back. A minute is
--- past both: on 2026-11-13 the item was back 8 seconds after Bartender was
--- opened again.
statusitem.GRACE = 60

--- The shortest gap between two restarts of the same manager.
---
--- A restart reshuffles the whole menu bar in front of whoever is looking at
--- it. Once is a repair. Every refresh would be a fault of its own, and an item
--- that a restart did not bring back is not brought back by the next one. So
--- there is also one restart per occurrence: the item has to come back, or the
--- occurrence end, before the manager is restarted for it again.
statusitem.RESTART_EVERY = 600

--- How long the manager gets to quit, as a count of half seconds.
---
--- Thirty seconds. The restart runs as a task beside Hammerspoon, so the wait
--- holds nothing up, and a manager that took longer than a short wait would
--- otherwise go after the wait had given up and not be opened again.
statusitem.QUIT_TRIES = 60

--- Quit a menu-bar manager, wait for it to go, and open it again.
---
--- Asked to quit by bundle id through AppleScript, which is how it was done by
--- hand when it worked. The wait is bounded, and the manager is only opened
--- again once its process has gone: `open` on a manager that is still running
--- brings its settings window to the front and restarts nothing.
--- @param manager table { name = string, bundle = string }
---
--- The process is followed by its pid, not by its name: the name Hammerspoon
--- reports is the localised application name, which need not be the name of
--- the executable, and a wait on a name nothing has ends at once.
--- @param pid number the pid of its running process
--- @return string command
function statusitem.restartCommand(manager, pid)
  local running = ("/bin/kill -0 %d 2>/dev/null"):format(math.tointeger(pid) or 0)
  return table.concat({
    "/usr/bin/osascript -e " .. backends.shellQuote(('tell application id "%s" to quit'):format(manager.bundle)),
    ('n=0 ; while [ "$n" -lt %d ] && %s ; do /bin/sleep 0.5 ; n=$((n+1)) ; done'):format(
      statusitem.QUIT_TRIES,
      running
    ),
    ("! %s && /usr/bin/open -b %s"):format(running, backends.shellQuote(manager.bundle)),
  }, " ; ")
end

--- Record that a manager was restarted.
--- @param memory table owned by the caller
--- @param manager table
--- @param now number seconds
function statusitem.restarted(memory, manager, now)
  memory.restarted = memory.restarted or {}
  memory.restarted[manager.bundle] = now
end

--- The first known manager that is running, with the pid of its process.
--- @param running table|nil { [bundle] = pid }
--- @return table|nil manager, number|nil pid
local function runningManager(running)
  for _, manager in ipairs(statusitem.MANAGERS) do
    local value = type(running) == "table" and running[manager.bundle] or nil
    local pid = type(value) == "number" and math.tointeger(value) or nil
    if pid and pid > 0 then
      return manager, pid
    end
  end
  return nil, nil
end

--- What, if anything, to do about a client that runs without its item.
---
--- At most one action per call:
---
--- - `restart`: a known manager is running, and it has not been restarted in
---   the last `RESTART_EVERY` seconds. The agent itself is never restarted for
---   this. `launchctl kickstart -k` on it did not bring the item back on
---   2026-11-13, and stopping the agent is a disconnect that costs a login
---   ([ADR 0033](../../docs/adr/0033-stopping-an-agent-that-launchd-restarts.md)).
--- - `report`: nothing here can bring the item back, so somebody is told, once
---   per occurrence. Either no known manager is running, or the one that is
---   was restarted and the item stayed away.
--- - `returned`: the item is back after having been missing, so the adapter
---   can try the connection now and not after a backoff earned by presses
---   that had nothing to press.
---
--- Nothing while nobody is there. No press is made into a locked screen
--- anyway ([ADR 0042](../../docs/adr/0042-nothing-happens-while-nobody-is-there.md)),
--- so an item nobody will use can wait, and a night with a missing item would
--- otherwise be a manager restarted six times an hour. Nothing while
--- everything is switched off either
--- ([ADR 0041](../../docs/adr/0041-everything-means-everything.md)).
---
--- @param observations table list of { app = string, running = boolean, item = boolean }:
---   one per client that needs an item, with what launchd says about its agent
---   and whether the item is there
--- @param running table|nil { [bundle] = pid } for the managers that run
--- @param memory table owned by the caller
--- @param now number seconds
--- @param context table|nil { away = boolean, paused = boolean }
--- @return table|nil { verb = "restart"|"report"|"returned", app, manager, pid, seconds }
function statusitem.plan(observations, running, memory, now, context)
  memory.since = memory.since or {}
  memory.reported = memory.reported or {}
  memory.restarted = memory.restarted or {}
  context = context or {}

  local action
  for _, seen in ipairs(observations or {}) do
    local app = seen.app
    if not seen.running or seen.item then
      -- Nothing is missing: the item is there, or there is no running agent to
      -- have one. Either way the occurrence is over.
      local wasMissing = memory.since[app] ~= nil and now - memory.since[app] >= statusitem.GRACE
      memory.since[app], memory.reported[app] = nil, nil
      if seen.item and wasMissing then
        action = action or { verb = "returned", app = app }
      end
    elseif context.away then
      -- Not counted while nobody is there. The item cannot be read on a
      -- locked screen, so time spent away says nothing about it, and the
      -- grace starts again from the first look after the return.
      memory.since[app] = nil
    else
      memory.since[app] = memory.since[app] or now
      local seconds = now - memory.since[app]
      if seconds >= statusitem.GRACE and not context.paused then
        local manager, pid = runningManager(running)
        local last = manager and memory.restarted[manager.bundle] or nil
        local spent = last ~= nil and (last >= memory.since[app] or now - last < statusitem.RESTART_EVERY)
        if manager and not spent then
          action = action or { verb = "restart", app = app, manager = manager, pid = pid, seconds = seconds }
        elseif action == nil and not memory.reported[app] and (manager == nil or now - last >= statusitem.GRACE) then
          -- A manager that was restarted gets the same grace the agent got
          -- before the restart is called a failure.
          memory.reported[app] = true
          action = { verb = "report", app = app, manager = manager, seconds = seconds }
        end
      end
    end
  end
  return action
end

--- The sentence for a `report`.
--- @param action table from `plan`
--- @return string
function statusitem.explain(action)
  local minutes = math.max(1, action.seconds // 60)
  local lead = ("%s has had no menu-bar item for %d minute%s, so vpnbar cannot press Connect in it."):format(
    action.app,
    minutes,
    minutes == 1 and "" or "s"
  )
  if action.manager then
    return lead .. (" Restarting %s did not bring it back."):format(action.manager.name)
  end
  return lead .. " No menu-bar manager that vpnbar knows is running."
end

return statusitem
