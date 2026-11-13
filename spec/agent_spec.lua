local backends = require("vpnbar.backends")
local statusitem = require("vpnbar.statusitem")

--- The commands here are run, not only read. A string that looks right says
--- nothing about what a shell does with it, and the fault these were written
--- for was one of order: a `bootstrap` that ran while launchd was still taking
--- the old service down (ADR 0048).
---
--- Nothing on this machine is touched. Every program the command names is
--- swapped for a stand-in in a temporary directory before it runs, the spec
--- refuses to run a command that still names a real one, and the agent it is
--- built for does not exist: a label and an application name nobody has.
-- The plist is a file the setup writes into the temporary directory, because
-- the commands ask whether it is there before they stop anything.
local AGENT = { label = "ch.example.vpnbar-spec", plist = "" }
local APP = "vpnbar-spec-app"
local MANAGER = { name = "Spec Manager", bundle = "ch.example.vpnbar-spec-manager" }
local MANAGER_PID = 4711

local REAL = {
  "/bin/launchctl",
  "/usr/bin/pgrep",
  "/usr/bin/pkill",
  "/bin/sleep",
  "/usr/bin/id",
  "/usr/bin/osascript",
  "/usr/bin/open",
  "/bin/kill",
}

--- launchd, as far as these commands can tell. State is files in `$FAKE`:
--- `loaded` while the service is there, `going` with the number of `print`s it
--- survives after a `bootout`, `proc/<name>` for every process `pgrep`
--- would find, `proc/<pid>` for the manager `kill -0` asks after, and
--- `disabled` for a service `print-disabled` names as disabled.
local STAND_INS = {
  launchctl = [[
echo "launchctl $1" >> "$FAKE/log"
case "$1" in
  print-disabled)
    printf 'disabled services = {\n'
    [ -f "$FAKE/disabled" ] && printf '\t"%s" => disabled\n' "$FAKE_LABEL"
    printf '}\n'
    ;;
  bootout)
    [ -f "$FAKE/loaded" ] || exit 3
    cp "$FAKE/linger" "$FAKE/going"
    ;;
  print)
    if [ -f "$FAKE/going" ]; then
      left="$(cat "$FAKE/going")"
      if [ "$left" -le 0 ]; then
        rm -f "$FAKE/going" "$FAKE/loaded" "$FAKE/proc/$FAKE_APP"
      else
        echo $((left - 1)) > "$FAKE/going"
      fi
    fi
    [ -f "$FAKE/loaded" ] || { echo "Could not find service" >&2; exit 113; }
    if [ -f "$FAKE/never-runs" ]; then
      printf '\tstate = waiting\n'
    else
      printf '\tstate = running\n\tpid = 4242\n'
    fi
    ;;
  bootstrap)
    if [ -f "$FAKE/loaded" ]; then
      echo "refused: still loaded" >> "$FAKE/log"
      exit 37
    fi
    left="$(cat "$FAKE/refusals" 2>/dev/null || echo 0)"
    if [ "$left" -gt 0 ]; then
      echo $((left - 1)) > "$FAKE/refusals"
      echo "refused: input/output error" >> "$FAKE/log"
      exit 5
    fi
    touch "$FAKE/loaded" "$FAKE/proc/$FAKE_APP"
    ;;
esac
]],
  pgrep = [[
for last in "$@"; do :; done
[ -f "$FAKE/proc/$last" ]
]],
  pkill = [[
for last in "$@"; do :; done
echo "pkill $1 $last" >> "$FAKE/log"
[ -f "$FAKE/unkillable" ] || rm -f "$FAKE/proc/$last"
]],
  sleep = [[
echo "sleep $1" >> "$FAKE/log"
]],
  id = [[
echo 501
]],
  osascript = [[
echo "osascript $2" >> "$FAKE/log"
[ -f "$FAKE/wont-quit" ] || [ -f "$FAKE/quit-after" ] || rm -f "$FAKE/proc/$FAKE_MANAGER"
]],
  open = [[
echo "open $*" >> "$FAKE/log"
touch "$FAKE/proc/$FAKE_MANAGER"
]],
  -- Only `kill -0 <pid>`. A manager told to quit slowly keeps answering for
  -- the number of looks in `quit-after`.
  kill = [[
if [ -f "$FAKE/quit-after" ]; then
  left="$(cat "$FAKE/quit-after")"
  if [ "$left" -le 0 ]; then
    rm -f "$FAKE/quit-after" "$FAKE/proc/$2"
  else
    echo $((left - 1)) > "$FAKE/quit-after"
  fi
fi
[ -f "$FAKE/proc/$2" ]
]],
}

local function write(path, contents)
  local file = assert(io.open(path, "w"))
  file:write(contents)
  file:close()
end

local function read(path)
  local file = io.open(path, "r")
  if not file then
    return ""
  end
  local contents = file:read("a")
  file:close()
  return contents
end

local function count(haystack, needle)
  local found, at = 0, 1
  while true do
    local from = haystack:find(needle, at, true)
    if not from then
      return found
    end
    found, at = found + 1, from + 1
  end
end

describe("the agent commands, run against a stand-in for launchd", function()
  local root, dir

  -- The stand-ins are written once and the state they keep is new for every
  -- test: macOS checks a program the first time it runs, and seven fresh ones
  -- per test was most of a second each.
  setup(function()
    local pipe = assert(io.popen("mktemp -d"))
    root = pipe:read("l")
    pipe:close()
    assert.is_truthy(root and root ~= "", "no temporary directory")
    assert(os.execute("mkdir -p " .. backends.shellQuote(root .. "/fakes")))
    for name, body in pairs(STAND_INS) do
      write(root .. "/fakes/" .. name, "#!/bin/sh\n" .. body)
    end
    assert(os.execute("chmod +x " .. backends.shellQuote(root .. "/fakes") .. "/*"))
    AGENT.plist = root .. "/vpnbar spec.plist"
  end)

  teardown(function()
    os.execute("rm -rf " .. backends.shellQuote(root))
  end)

  before_each(function()
    dir = root .. "/state"
    assert(os.execute("rm -rf " .. backends.shellQuote(dir)))
    assert(os.execute("mkdir -p " .. backends.shellQuote(dir .. "/proc")))
    write(dir .. "/linger", "0\n")
    write(AGENT.plist, "")
  end)

  --- The service is loaded and its process runs.
  local function loaded()
    write(dir .. "/loaded", "")
    write(dir .. "/proc/" .. APP, "")
  end

  --- Run a command with every program in it swapped for its stand-in.
  --- @return boolean ok, string log
  local function run(command)
    for _, real in ipairs(REAL) do
      local standIn = root .. "/fakes/" .. real:match("([^/]+)$")
      -- A function, so that nothing in a temporary path is read as a capture.
      command = command:gsub(real:gsub("%p", "%%%0"), function()
        return standIn
      end)
    end
    -- The stand-ins live in a directory called `fakes`, so a path that still
    -- has `/bin/` before the program is one the swap missed.
    for _, real in ipairs(REAL) do
      assert.is_nil(command:find(real, 1, true), "still names " .. real)
    end
    local env = ("FAKE=%s FAKE_APP=%s FAKE_MANAGER=%d FAKE_LABEL=%s"):format(
      backends.shellQuote(dir),
      backends.shellQuote(APP),
      MANAGER_PID,
      backends.shellQuote(AGENT.label)
    )
    local ok = os.execute(env .. " /bin/sh -c " .. backends.shellQuote(command))
    return ok == true, read(dir .. "/log")
  end

  describe("restarting", function()
    it("does not bootstrap while launchd is still taking the old service down", function()
      -- 2026-11-13: the agent needed two seconds to go and the bootstrap came
      -- after one. Here it survives twelve looks, which is more than the rest
      -- of the command takes, so only the wait gets past it.
      loaded()
      write(dir .. "/linger", "12\n")
      local ok, log = run(backends.bootstrapCommand(AGENT, APP))
      assert.is_true(ok, log)
      assert.equals(0, count(log, "refused"), log)
      assert.equals(1, count(log, "launchctl bootstrap"), log)
      assert.is_truthy(read(dir .. "/loaded") and io.open(dir .. "/loaded"), "the service is loaded again")
    end)

    it("gives up after its count, and loads nothing over a service that never went", function()
      loaded()
      write(dir .. "/linger", "100000\n")
      local ok, log = run(backends.bootstrapCommand(AGENT, APP))
      assert.is_false(ok, log)
      assert.equals(0, count(log, "launchctl bootstrap"), log)
      assert.equals(backends.AGENT_REMOVAL_TRIES, count(log, "sleep 0.5"), log)
    end)

    it("tries the bootstrap again when launchd refuses it", function()
      loaded()
      write(dir .. "/refusals", "2\n")
      local ok, log = run(backends.bootstrapCommand(AGENT, APP))
      assert.is_true(ok, log)
      assert.equals(3, count(log, "launchctl bootstrap"), log)
    end)

    it("stops trying the bootstrap after its count", function()
      loaded()
      write(dir .. "/refusals", "100000\n")
      local ok, log = run(backends.bootstrapCommand(AGENT, APP))
      assert.is_false(ok, log)
      assert.equals(backends.AGENT_BOOTSTRAP_TRIES, count(log, "launchctl bootstrap"), log)
    end)

    it("fails when launchd does not say it runs, whatever the process list says", function()
      -- The fault of 2026-11-13 in one line: a process called GlobalProtect
      -- was there, and launchd had no such service.
      loaded()
      write(dir .. "/never-runs", "")
      local ok, log = run(backends.bootstrapCommand(AGENT, APP))
      assert.is_truthy(io.open(dir .. "/proc/" .. APP), "the stand-in process is there")
      assert.is_false(ok, log)
    end)

    it("starts an agent that was not loaded at all", function()
      local ok, log = run(backends.bootstrapCommand(AGENT, APP))
      assert.is_true(ok, log)
      assert.equals(1, count(log, "launchctl bootstrap"), log)
    end)
  end)

  describe("quitting", function()
    it("waits for launchd to drop the service before it says so", function()
      loaded()
      write(dir .. "/linger", "12\n")
      local ok, log = run(backends.bootoutCommand(AGENT, APP))
      assert.is_true(ok, log)
      assert.equals(0, count(log, "pkill"), "launchd's own agent is never signalled: " .. log)
      assert.equals(0, count(log, "launchctl bootstrap"), log)
    end)

    it("fails while launchd still has the service", function()
      loaded()
      write(dir .. "/linger", "100000\n")
      local ok, log = run(backends.bootoutCommand(AGENT, APP))
      assert.is_false(ok, log)
      assert.equals(0, count(log, "pkill"), log)
    end)

    it("stops a copy that runs beside launchd, which nothing restarts", function()
      write(dir .. "/proc/" .. APP, "")
      local ok, log = run(backends.bootoutCommand(AGENT, APP))
      assert.is_true(ok, log)
      assert.equals(1, count(log, "pkill -x " .. APP), log)
      assert.equals(0, count(log, "pkill -9"), "a TERM that worked is not followed by a KILL: " .. log)
    end)

    it("stops a copy beside launchd even when the agent could not be loaded again", function()
      -- A quit is about the copy, not about what comes after it.
      write(dir .. "/proc/" .. APP, "")
      os.remove(AGENT.plist)
      local ok, log = run(backends.bootoutCommand(AGENT, APP))
      assert.is_true(ok, log)
      assert.equals(1, count(log, "pkill -x " .. APP), log)
    end)

    it("insists when the copy ignores the first signal, and says so when it stays", function()
      write(dir .. "/proc/" .. APP, "")
      write(dir .. "/unkillable", "")
      local ok, log = run(backends.bootoutCommand(AGENT, APP))
      assert.is_false(ok, log)
      assert.equals(1, count(log, "pkill -9 " .. APP), log)
      assert.equals(backends.STRAY_TERM_TRIES + backends.STRAY_KILL_TRIES, count(log, "sleep 0.5"), log)
    end)
  end)

  describe("loading", function()
    it("leaves a service launchd already has exactly as it is", function()
      loaded()
      local ok, log = run(backends.loadCommand(AGENT, APP))
      assert.is_true(ok, log)
      assert.equals(0, count(log, "launchctl bootstrap"), log)
      assert.equals(0, count(log, "launchctl bootout"), log)
      assert.equals(0, count(log, "pkill"), log)
    end)

    it("loads the plist when launchd has no such service", function()
      local ok, log = run(backends.loadCommand(AGENT, APP))
      assert.is_true(ok, log)
      assert.equals(1, count(log, "launchctl bootstrap"), log)
      assert.equals(0, count(log, "pkill"), log)
    end)

    it("stops a copy beside launchd first, then loads the agent", function()
      write(dir .. "/proc/" .. APP, "")
      local ok, log = run(backends.loadCommand(AGENT, APP))
      assert.is_true(ok, log)
      local kill = log:find("pkill -x " .. APP, 1, true)
      local load = log:find("launchctl bootstrap", 1, true)
      assert.is_truthy(kill and load, log)
      assert.is_true(kill < load, log)
    end)

    it("fails when launchd will not take the plist, without waiting for it to run", function()
      write(dir .. "/refusals", "100000\n")
      local ok, log = run(backends.loadCommand(AGENT, APP))
      assert.is_false(ok, log)
      assert.equals(0, count(log, "sleep 0.5"), "nothing to wait for on a service launchd has not got: " .. log)
    end)

    it("fails while launchd has no service, however alive the process looks", function()
      -- The machine of 2026-11-13 22:20: a process called GlobalProtect, and
      -- `launchctl print` answering `Could not find service`. A `pgrep` said
      -- yes to that; launchd's answer is the one that counts.
      write(dir .. "/proc/" .. APP, "")
      write(dir .. "/unkillable", "")
      write(dir .. "/refusals", "100000\n")
      local ok, log = run(backends.loadCommand(AGENT, APP))
      assert.is_false(ok, log)
      assert.is_truthy(io.open(dir .. "/proc/" .. APP), "the process is still there")
    end)

    it("leaves the only client running when the plist is gone", function()
      write(dir .. "/proc/" .. APP, "")
      os.remove(AGENT.plist)
      local ok, log = run(backends.loadCommand(AGENT, APP))
      assert.is_false(ok, log)
      assert.equals(0, count(log, "pkill"), log)
      assert.equals(0, count(log, "launchctl bootstrap"), log)
      assert.is_truthy(io.open(dir .. "/proc/" .. APP), "the copy beside launchd is still there")
    end)

    it("leaves the only client running when the service is disabled", function()
      write(dir .. "/proc/" .. APP, "")
      write(dir .. "/disabled", "")
      local ok, log = run(backends.loadCommand(AGENT, APP))
      assert.is_false(ok, log)
      assert.equals(0, count(log, "pkill"), log)
      assert.equals(0, count(log, "launchctl bootstrap"), log)
    end)
  end)

  describe("restarting a menu-bar manager", function()
    it("asks it to quit by bundle id, and opens it once it has gone", function()
      write(dir .. "/proc/" .. MANAGER_PID, "")
      local ok, log = run(statusitem.restartCommand(MANAGER, MANAGER_PID))
      assert.is_true(ok, log)
      local quit = log:find('osascript tell application id "ch.example.vpnbar-spec-manager" to quit', 1, true)
      local open = log:find("open -b ch.example.vpnbar-spec-manager", 1, true)
      assert.is_truthy(quit and open, log)
      assert.is_true(quit < open, log)
    end)

    it("waits for a manager that takes its time to quit, and opens it after", function()
      write(dir .. "/proc/" .. MANAGER_PID, "")
      write(dir .. "/quit-after", "40\n")
      local ok, log = run(statusitem.restartCommand(MANAGER, MANAGER_PID))
      assert.is_true(ok, log)
      assert.equals(1, count(log, "open -b"), log)
    end)

    it("does not open a manager that would not quit", function()
      write(dir .. "/proc/" .. MANAGER_PID, "")
      write(dir .. "/wont-quit", "")
      local ok, log = run(statusitem.restartCommand(MANAGER, MANAGER_PID))
      assert.is_false(ok, log)
      assert.equals(0, count(log, "open "), log)
      assert.equals(statusitem.QUIT_TRIES, count(log, "sleep 0.5"), log)
    end)
  end)
end)

describe("what launchd said about an agent", function()
  it("is missing when the print failed", function()
    assert.equals("missing", backends.agentState("", false))
    assert.equals("missing", backends.agentState("state = running", false))
    assert.equals("missing", backends.agentState(nil, nil))
  end)

  it("is running when launchd names a running state or a pid", function()
    assert.equals("running", backends.agentState("\tstate = running\n", true))
    assert.equals("running", backends.agentState("\tstate = spawn scheduled\n\tpid = 812\n", true))
  end)

  it("is only loaded when launchd has it and it does not run", function()
    assert.equals("loaded", backends.agentState("\tstate = waiting\n", true))
    assert.equals("loaded", backends.agentState(nil, true))
  end)

  it("asks for the uid, and drops the complaint about a missing service", function()
    assert.equals(
      "/bin/launchctl print gui/$(/usr/bin/id -u)/a.b.c 2>/dev/null",
      backends.agentPrintCommand({ label = "a.b.c", plist = "/p.plist" })
    )
  end)
end)

describe("opening an application that is a launchd agent", function()
  local cfg = {
    profiles = {
      { id = "aws", name = "AWS", backend = "awsvpn", app = "AWS VPN Client", row = "w" },
      "not a profile",
      { id = "gp", name = "GP", backend = "globalprotect", app = "GlobalProtect" },
    },
  }

  it("knows which applications are one", function()
    assert.equals(backends.byName.globalprotect.AGENT, backends.agentForApp("GlobalProtect", cfg))
    assert.is_nil(backends.agentForApp("AWS VPN Client", cfg))
    assert.is_nil(backends.agentForApp("Nobody", cfg))
    assert.is_nil(backends.agentForApp("GlobalProtect", nil))
    assert.is_nil(backends.agentForApp("GlobalProtect", { profiles = "none" }))
  end)

  it("names the agent behind a profile, and nothing behind anything else", function()
    assert.equals(backends.byName.globalprotect.AGENT, backends.agentOf(cfg.profiles[3]))
    assert.is_nil(backends.agentOf(cfg.profiles[1]))
    assert.is_nil(backends.agentOf({ backend = "nothing" }))
    assert.is_nil(backends.agentOf(nil))
  end)

  it("never builds `open -a` for it, and loads the agent in its place", function()
    -- `open -a GlobalProtect` starts a copy beside launchd with no KeepAlive,
    -- which neither Quit nor Restart reaches (ADR 0048).
    local command = backends.launchCommand("GlobalProtect", cfg)
    assert.is_nil(command:find("/usr/bin/open", 1, true), command)
    assert.is_nil(command:find("open -a", 1, true), command)
    assert.equals(backends.loadCommand(backends.byName.globalprotect.AGENT, "GlobalProtect"), command)
    assert.is_truthy(
      command:find("launchctl bootstrap gui/$(/usr/bin/id -u) '/Library/LaunchAgents/", 1, true),
      command
    )
  end)

  it("opens a plain application the way it always did", function()
    assert.equals("/usr/bin/open -a 'AWS VPN Client'", backends.launchCommand("AWS VPN Client", cfg))
    assert.equals("/usr/bin/open -a 'Some App'", backends.launchCommand("Some App", nil))
  end)

  it("builds no `open -a` on any path of a backend that names an agent", function()
    for name, backend in pairs(backends.byName) do
      if backend.AGENT then
        local profile = { id = "p", name = "P", backend = name, app = "Its App" }
        for _, verb in ipairs({ "quit", "restart", "load" }) do
          local ran
          backends.act(profile, verb, {
            exec = function(command)
              ran = command
              return "", true
            end,
          })
          assert.is_truthy(ran, name .. " ran nothing for " .. verb)
          assert.is_nil(ran:find("open -a", 1, true), name .. " " .. verb .. ": " .. ran)
        end
        assert.is_nil(backends.launchCommand("Its App", { profiles = { profile } }):find("open -a", 1, true))
      end
    end
  end)
end)

describe("loading an agent, as a verb", function()
  local gp = { id = "gp", name = "GP", backend = "globalprotect", app = "GlobalProtect" }

  local function runtime(ok)
    local calls = {}
    return {
      calls = calls,
      exec = function(command)
        calls[#calls + 1] = command
        return "", ok
      end,
    }
  end

  it("runs the load command and nothing else", function()
    local fake = runtime(true)
    local ok, err = backends.act(gp, "load", fake)
    assert.is_true(ok)
    assert.is_nil(err)
    assert.same({ backends.loadCommand(backends.byName.globalprotect.AGENT, "GlobalProtect") }, fake.calls)
  end)

  it("is allowed on a protected connection, because it ends with the client running", function()
    local protected = { id = "gp", name = "GP", backend = "globalprotect", app = "GlobalProtect", protected = true }
    assert.is_true((backends.act(protected, "load", runtime(true))))
  end)

  it("says what did not happen when launchd will not start it", function()
    local ok, err = backends.act(gp, "load", runtime(false))
    assert.is_false(ok)
    assert.equals("launchd did not start GlobalProtect", err)
  end)

  it("does not exist for a client that is not an agent", function()
    local aws = { id = "a", name = "A", backend = "awsvpn", app = "AWS VPN Client", row = "w" }
    local ok, err = backends.act(aws, "load", runtime(true))
    assert.is_false(ok)
    assert.equals("no load for a awsvpn connection", err)
  end)
end)

describe("a client driven through its menu-bar item", function()
  it("is GlobalProtect and nothing else", function()
    assert.is_true(backends.needsMenuBarItem({ backend = "globalprotect" }))
    assert.is_false(backends.needsMenuBarItem({ backend = "awsvpn" }))
    assert.is_false(backends.needsMenuBarItem({ backend = "scutil" }))
    assert.is_false(backends.needsMenuBarItem({ backend = "nothing" }))
    assert.is_false(backends.needsMenuBarItem(nil))
  end)
end)
