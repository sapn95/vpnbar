local statusitem = require("vpnbar.statusitem")

local BARTENDER = "com.surteesstudios.Bartender"

--- GlobalProtect running under launchd with no menu-bar item, which is what
--- 2026-11-13 looked like from the boot until the evening.
local function swallowed()
  return { { app = "GlobalProtect", running = true, item = false } }
end

local function present()
  return { { app = "GlobalProtect", running = true, item = true } }
end

local managers = { [BARTENDER] = "Bartender 7" }

describe("statusitem.MANAGERS", function()
  it("is data: a name and a bundle id per manager, and no process name", function()
    assert.is_true(#statusitem.MANAGERS >= 1)
    for _, manager in ipairs(statusitem.MANAGERS) do
      assert.is_string(manager.name)
      assert.is_string(manager.bundle)
      assert.is_nil(manager.process, "the process name carries the version; the adapter reads it")
    end
    assert.same({ name = "Bartender", bundle = BARTENDER }, statusitem.MANAGERS[1])
  end)

  it("is what the plan reads, so a second manager is a row", function()
    local saved = statusitem.MANAGERS
    statusitem.MANAGERS = { { name = "Other", bundle = "ch.example.other" } }
    local memory = { since = { GlobalProtect = 0 } }
    local ok, action = pcall(statusitem.plan, swallowed(), { ["ch.example.other"] = "Other" }, memory, 100)
    statusitem.MANAGERS = saved
    assert.is_true(ok, tostring(action))
    assert.equals("restart", action.verb)
    assert.equals("ch.example.other", action.manager.bundle)
    assert.equals("Other", action.process)
  end)
end)

describe("statusitem.plan", function()
  it("does nothing while the item is there", function()
    local memory = {}
    assert.is_nil(statusitem.plan(present(), managers, memory, 1000))
    assert.is_nil(memory.since.GlobalProtect)
  end)

  it("gives a missing item a grace period first", function()
    local memory = {}
    assert.is_nil(statusitem.plan(swallowed(), managers, memory, 1000))
    assert.equals(1000, memory.since.GlobalProtect)
    assert.is_nil(statusitem.plan(swallowed(), managers, memory, 1000 + statusitem.GRACE - 1))
  end)

  it("restarts the manager that is running once the grace is over", function()
    local memory = {}
    statusitem.plan(swallowed(), managers, memory, 1000)
    local action = statusitem.plan(swallowed(), managers, memory, 1000 + statusitem.GRACE)
    assert.same({
      verb = "restart",
      app = "GlobalProtect",
      manager = statusitem.MANAGERS[1],
      process = "Bartender 7",
      seconds = statusitem.GRACE,
    }, action)
  end)

  it("counts the grace from when the item went, not from an earlier time it was gone", function()
    local memory = {}
    statusitem.plan(swallowed(), managers, memory, 1000)
    statusitem.plan(present(), managers, memory, 1030)
    assert.is_nil(statusitem.plan(swallowed(), managers, memory, 1050))
    assert.is_nil(statusitem.plan(swallowed(), managers, memory, 1050 + statusitem.GRACE - 1))
    assert.equals("restart", statusitem.plan(swallowed(), managers, memory, 1050 + statusitem.GRACE).verb)
  end)

  it("does not hold an agent that is not running to having an item", function()
    local memory = {}
    local stopped = { { app = "GlobalProtect", running = false, item = false } }
    assert.is_nil(statusitem.plan(stopped, managers, memory, 1000))
    assert.is_nil(statusitem.plan(stopped, managers, memory, 1000 + 10 * statusitem.GRACE))
    assert.is_nil(memory.since.GlobalProtect)
  end)

  it("restarts the same manager at most once in ten minutes", function()
    assert.equals(600, statusitem.RESTART_EVERY)
    local memory = {}
    statusitem.plan(swallowed(), managers, memory, 1000)
    local first = statusitem.plan(swallowed(), managers, memory, 1060)
    assert.equals("restart", first.verb)
    statusitem.restarted(memory, first.manager, 1060)
    for now = 1070, 1060 + statusitem.RESTART_EVERY - 1, 10 do
      local action = statusitem.plan(swallowed(), managers, memory, now)
      assert.is_true(action == nil or action.verb ~= "restart", "restarted again at " .. now)
    end
    assert.equals("restart", statusitem.plan(swallowed(), managers, memory, 1060 + statusitem.RESTART_EVERY).verb)
  end)

  it("keeps the limit per manager when the item comes back in between", function()
    local memory = {}
    statusitem.plan(swallowed(), managers, memory, 1000)
    statusitem.restarted(memory, statusitem.MANAGERS[1], 1060)
    statusitem.plan(present(), managers, memory, 1070)
    statusitem.plan(swallowed(), managers, memory, 1080)
    local action = statusitem.plan(swallowed(), managers, memory, 1080 + statusitem.GRACE)
    assert.is_true(action == nil or action.verb ~= "restart")
  end)

  it("says so once when the restart did not bring the item back", function()
    local memory = {}
    statusitem.plan(swallowed(), managers, memory, 1000)
    statusitem.restarted(memory, statusitem.MANAGERS[1], 1060)
    assert.is_nil(statusitem.plan(swallowed(), managers, memory, 1060 + statusitem.GRACE - 1))
    local action = statusitem.plan(swallowed(), managers, memory, 1060 + statusitem.GRACE)
    assert.equals("report", action.verb)
    assert.equals(statusitem.MANAGERS[1], action.manager)
    assert.is_nil(statusitem.plan(swallowed(), managers, memory, 1060 + statusitem.GRACE + 10))
  end)

  it("only reports when no known manager is running, and only once", function()
    local memory = {}
    statusitem.plan(swallowed(), {}, memory, 1000)
    local action = statusitem.plan(swallowed(), {}, memory, 1000 + statusitem.GRACE)
    assert.same({ verb = "report", app = "GlobalProtect", manager = nil, seconds = statusitem.GRACE }, action)
    assert.is_nil(statusitem.plan(swallowed(), {}, memory, 1000 + statusitem.GRACE + 10))
    assert.is_nil(statusitem.plan(swallowed(), nil, memory, 1000 + 100 * statusitem.GRACE))
  end)

  it("reports again for the next occurrence", function()
    local memory = {}
    statusitem.plan(swallowed(), {}, memory, 1000)
    assert.equals("report", statusitem.plan(swallowed(), {}, memory, 1100).verb)
    statusitem.plan(present(), {}, memory, 1200)
    statusitem.plan(swallowed(), {}, memory, 1300)
    assert.equals("report", statusitem.plan(swallowed(), {}, memory, 1400).verb)
  end)

  it("ignores a manager whose process has no name", function()
    local memory = { since = { GlobalProtect = 0 } }
    assert.equals("report", statusitem.plan(swallowed(), { [BARTENDER] = "" }, memory, 1000).verb)
  end)

  it("says when the item is back, once, so the connection can be tried now", function()
    local memory = {}
    statusitem.plan(swallowed(), managers, memory, 1000)
    statusitem.plan(swallowed(), managers, memory, 1060)
    assert.same({ verb = "returned", app = "GlobalProtect" }, statusitem.plan(present(), managers, memory, 1068))
    assert.is_nil(statusitem.plan(present(), managers, memory, 1078))
  end)

  it("does not announce an item that was only missing for a moment", function()
    local memory = {}
    statusitem.plan(swallowed(), managers, memory, 1000)
    assert.is_nil(statusitem.plan(present(), managers, memory, 1010))
  end)

  it("does not call an agent that stopped an item that came back", function()
    local memory = {}
    statusitem.plan(swallowed(), managers, memory, 1000)
    local stopped = { { app = "GlobalProtect", running = false, item = false } }
    assert.is_nil(statusitem.plan(stopped, managers, memory, 1100))
  end)

  it("does nothing while nobody is there, and acts on the first look after", function()
    local memory = {}
    statusitem.plan(swallowed(), managers, memory, 1000)
    assert.is_nil(statusitem.plan(swallowed(), managers, memory, 5000, { away = true }))
    assert.is_nil(statusitem.plan(swallowed(), {}, memory, 5000, { away = true }))
    assert.equals("restart", statusitem.plan(swallowed(), managers, memory, 5010, { away = false }).verb)
  end)

  it("does nothing while everything is switched off", function()
    local memory = {}
    statusitem.plan(swallowed(), managers, memory, 1000)
    assert.is_nil(statusitem.plan(swallowed(), managers, memory, 5000, { paused = true }))
  end)

  it("hands back one action when two clients are missing their item", function()
    local memory = {}
    local two = {
      { app = "One", running = true, item = false },
      { app = "Two", running = true, item = false },
    }
    statusitem.plan(two, {}, memory, 1000)
    assert.equals("One", statusitem.plan(two, {}, memory, 1100).app)
    assert.equals("Two", statusitem.plan(two, {}, memory, 1110).app)
    assert.is_nil(statusitem.plan(two, {}, memory, 1120))
    assert.is_nil(statusitem.plan(nil, {}, memory, 1130))
  end)
end)

describe("statusitem.restartCommand", function()
  local command = statusitem.restartCommand({ name = "Bartender", bundle = BARTENDER }, "Bartender 7")

  it("quits by bundle id, waits for the process by name, and opens by bundle id", function()
    assert.equals(
      [[/usr/bin/osascript -e 'tell application id "com.surteesstudios.Bartender" to quit']]
        .. [[ ; n=0 ; while [ "$n" -lt 20 ] && /usr/bin/pgrep -x 'Bartender 7' >/dev/null ;]]
        .. [[ do /bin/sleep 0.5 ; n=$((n+1)) ; done]]
        .. [[ ; ! /usr/bin/pgrep -x 'Bartender 7' >/dev/null && /usr/bin/open -b 'com.surteesstudios.Bartender']],
      command
    )
  end)

  it("touches no launchd service: restarting the agent would be a disconnect", function()
    assert.is_nil(command:find("launchctl", 1, true))
    assert.is_nil(command:find("pkill", 1, true))
  end)
end)

describe("statusitem.explain", function()
  it("names the client, the time and what was tried", function()
    assert.equals(
      "GlobalProtect has had no menu-bar item for 2 minutes, so vpnbar cannot press Connect in it."
        .. " Restarting Bartender did not bring it back.",
      statusitem.explain({ app = "GlobalProtect", seconds = 130, manager = statusitem.MANAGERS[1] })
    )
  end)

  it("says that nothing it knows is running", function()
    assert.equals(
      "GlobalProtect has had no menu-bar item for 1 minute, so vpnbar cannot press Connect in it."
        .. " No menu-bar manager that vpnbar knows is running.",
      statusitem.explain({ app = "GlobalProtect", seconds = 60 })
    )
  end)
end)
