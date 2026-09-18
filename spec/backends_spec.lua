local backends = require("vpnbar.backends")

--- A runtime that records what it was asked and answers from a script.
local function fakeRuntime(answers)
  answers = answers or {}
  local calls = { exec = {}, press = {}, panel = {} }
  return {
    calls = calls,
    exec = function(command)
      calls.exec[#calls.exec + 1] = command
      local answer = answers.exec
      if type(answer) == "function" then
        return answer(command)
      end
      return answer or "", answers.execOk ~= false
    end,
    ifconfig = function()
      calls.ifconfig = (calls.ifconfig or 0) + 1
      return answers.ifconfig or ""
    end,
    panel = function(app)
      calls.panel[#calls.panel + 1] = app
      return answers.panel or "unknown"
    end,
    press = function(app, verbs)
      calls.press[#calls.press + 1] = { app = app, verbs = verbs }
      if answers.pressOk == false then
        return false, answers.pressErr or "no"
      end
      return true, nil
    end,
  }
end

describe("backends.shellQuote", function()
  it("wraps a plain string", function()
    assert.equals("'Work VPN'", backends.shellQuote("Work VPN"))
  end)

  it("survives an apostrophe, which a service name is allowed to contain", function()
    assert.equals([['Seb'\''s VPN']], backends.shellQuote("Seb's VPN"))
  end)
end)

describe("the scutil backend", function()
  local profile = { id = "a", name = "Work", backend = "scutil", service = "Work VPN" }

  it("asks scutil for the status and normalises the answer", function()
    local runtime = fakeRuntime({ exec = "Connected\nExtended Status <dictionary> {}" })
    assert.equals("connected", backends.status(profile, runtime))
    assert.equals("/usr/sbin/scutil --nc status 'Work VPN'", runtime.calls.exec[1])
  end)

  it("starts and stops by name", function()
    local runtime = fakeRuntime()
    assert.is_true((backends.act(profile, "connect", runtime)))
    assert.is_true((backends.act(profile, "disconnect", runtime)))
    assert.equals("/usr/sbin/scutil --nc start 'Work VPN'", runtime.calls.exec[1])
    assert.equals("/usr/sbin/scutil --nc stop 'Work VPN'", runtime.calls.exec[2])
  end)

  it("reports a command that failed", function()
    local runtime = fakeRuntime({ execOk = false })
    local ok, err = backends.act(profile, "connect", runtime)
    assert.is_false(ok)
    assert.matches("scutil refused", err)
  end)
end)

describe("the globalprotect backend", function()
  local profile = { id = "gp", name = "GP", backend = "globalprotect", app = "GlobalProtect" }

  it("reads the state off the panel", function()
    local runtime = fakeRuntime({ panel = "connecting" })
    assert.equals("connecting", backends.status(profile, runtime))
    assert.same({ "GlobalProtect" }, runtime.calls.panel)
  end)

  it("clicks the control that says disconnect", function()
    local runtime = fakeRuntime()
    assert.is_true((backends.act(profile, "disconnect", runtime)))
    assert.same({ "disconnect" }, runtime.calls.press[1].verbs)
    assert.equals("GlobalProtect", runtime.calls.press[1].app)
  end)

  it("never clicks Disable, which means something else", function()
    local runtime = fakeRuntime()
    backends.act(profile, "disconnect", runtime)
    for _, verb in ipairs(runtime.calls.press[1].verbs) do
      assert.not_equals("disable", verb)
    end
  end)

  it("passes on why a click did not happen", function()
    local runtime = fakeRuntime({ pressOk = false, pressErr = "the panel did not open" })
    local ok, err = backends.act(profile, "connect", runtime)
    assert.is_false(ok)
    assert.equals("the panel did not open", err)
  end)
end)

describe("the shell backend", function()
  local profile = {
    id = "s",
    name = "Shell",
    backend = "shell",
    commands = { connect = "vpn up", disconnect = "vpn down", status = "vpn status" },
  }

  it("runs the status command and normalises what it prints", function()
    local runtime = fakeRuntime({ exec = "connected\n" })
    assert.equals("connected", backends.status(profile, runtime))
    assert.equals("vpn status", runtime.calls.exec[1])
  end)

  it("is unknown when no status command was given", function()
    local without = { id = "s", name = "S", backend = "shell", commands = { connect = "a", disconnect = "b" } }
    local runtime = fakeRuntime()
    assert.equals("unknown", backends.status(without, runtime))
    assert.equals(0, #runtime.calls.exec)
  end)

  it("runs the connect and disconnect commands as given", function()
    local runtime = fakeRuntime()
    backends.act(profile, "connect", runtime)
    backends.act(profile, "disconnect", runtime)
    assert.same({ "vpn up", "vpn down" }, runtime.calls.exec)
  end)
end)

describe("backends.status", function()
  -- 0x8051 really does spell out UP, POINTOPOINT, RUNNING and MULTICAST. The
  -- short version of this fixture disagreed with its own hex, which went
  -- unnoticed for as long as nothing read the flags.
  local ifconfig = "utun4: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1400\n"
    .. "\tinet 10.11.12.13 --> 10.11.12.13 netmask 0xffffffff"

  it("prefers the probe over the backend, because it costs nothing", function()
    local profile = {
      id = "gp",
      name = "GP",
      backend = "globalprotect",
      app = "GlobalProtect",
      probe = { cidr = "10.0.0.0/8", interface = "utun" },
    }
    local runtime = fakeRuntime({ ifconfig = ifconfig, panel = "disconnected" })
    assert.equals("connected", backends.status(profile, runtime))
    assert.equals(0, #runtime.calls.panel)
  end)

  it("falls back to the backend when the probe cannot answer at all", function()
    local profile = { id = "gp", name = "GP", backend = "globalprotect", app = "GlobalProtect", probe = {} }
    local runtime = fakeRuntime({ ifconfig = ifconfig, panel = "connecting" })
    assert.equals("connecting", backends.status(profile, runtime))
  end)

  it("is unknown for a backend it does not have", function()
    assert.equals("unknown", backends.status({ id = "x", backend = "carrier-pigeon" }, fakeRuntime()))
  end)

  it("is unknown when a backend throws rather than answers", function()
    local runtime = fakeRuntime({
      exec = function()
        error("boom")
      end,
    })
    local profile = { id = "a", name = "A", backend = "scutil", service = "A" }
    assert.equals("unknown", backends.status(profile, runtime))
  end)

  it("is unknown when a backend answers with a word nobody knows", function()
    local runtime = fakeRuntime({ panel = "sideways" })
    local profile = { id = "gp", name = "GP", backend = "globalprotect", app = "GlobalProtect" }
    assert.equals("unknown", backends.status(profile, runtime))
  end)
end)

describe("backends.act", function()
  it("refuses a verb the backend does not have", function()
    local ok, err = backends.act({ backend = "carrier-pigeon" }, "connect", fakeRuntime())
    assert.is_false(ok)
    assert.matches("no connect for", err)
  end)

  it("turns a thrown error into a message instead of taking Hammerspoon down", function()
    local runtime = fakeRuntime({
      exec = function()
        error("boom")
      end,
    })
    local profile = { id = "a", name = "A", backend = "scutil", service = "A" }
    local ok, err = backends.act(profile, "connect", runtime)
    assert.is_false(ok)
    assert.matches("boom", err)
  end)
end)

describe("backends.act, protected profiles", function()
  local profile = {
    id = "gp",
    name = "Always-on VPN",
    backend = "scutil",
    service = "Always-on VPN",
    protected = true,
  }

  it("refuses to bring it down, by either verb", function()
    local runtime = fakeRuntime()
    for _, verb in ipairs({ "disconnect", "force" }) do
      local ok, err = backends.act(profile, verb, runtime)
      assert.is_false(ok)
      assert.matches("protected from being disconnected", err)
    end
    assert.equals(0, #runtime.calls.exec)
  end)

  it("connects it happily, which is the direction protection allows", function()
    local runtime = fakeRuntime()
    assert.is_true((backends.act(profile, "connect", runtime)))
    assert.equals(1, #runtime.calls.exec)
  end)

  it("names the connection it refused", function()
    local _, err = backends.act(profile, "disconnect", fakeRuntime())
    assert.matches("Always%-on VPN", err)
  end)

  it("still reports its state, which is the whole point of it", function()
    local runtime = fakeRuntime({ exec = "Connected" })
    assert.equals("connected", backends.status(profile, runtime))
  end)
end)

describe("the globalprotect backend, restarting the agent", function()
  local profile = { id = "gp", name = "Always-on VPN", backend = "globalprotect", app = "GlobalProtect" }

  it("asks it to quit, insists, and then opens it again", function()
    local runtime = fakeRuntime()
    assert.is_true((backends.act(profile, "restart", runtime)))
    local command = runtime.calls.exec[1]
    assert.equals(1, #runtime.calls.exec)
    -- TERM first: an agent that is merely wedged in its panel may still shut
    -- down cleanly, and a clean shutdown is the one that leaves its own state
    -- tidy.
    assert.matches("^/usr/bin/pkill %-x 'GlobalProtect'", command)
    assert.matches("pkill %-9 %-x 'GlobalProtect'", command)
    -- Opening it again is last, so it is the exit status that reaches the caller.
    assert.matches("/usr/bin/open %-a 'GlobalProtect'$", command)
    assert.is_true(command:find("pkill %-x") < command:find("pkill %-9"))
  end)

  it("waits between the two, and again before it opens it", function()
    local runtime = fakeRuntime()
    backends.act(profile, "restart", runtime)
    local _, sleeps = runtime.calls.exec[1]:gsub("/bin/sleep", "")
    assert.equals(2, sleeps)
  end)

  it("quotes the app name, which is allowed to contain a space", function()
    local command = backends.restartCommand("Some Agent")
    assert.matches("pkill %-x 'Some Agent'", command)
    assert.matches("open %-a 'Some Agent'$", command)
  end)

  it("reports the failure of the reopen, not of the kill", function()
    -- `pkill` exits non-zero when nothing matched, so an agent that had already
    -- crashed would otherwise be reported as an error while it was being fixed.
    local runtime = fakeRuntime({ execOk = false })
    local ok, err = backends.act(profile, "restart", runtime)
    assert.is_false(ok)
    assert.matches("could not open GlobalProtect again", err)
  end)

  it("is allowed on a protected connection, unlike every other write", function()
    local locked = { id = "gp", name = "Always-on VPN", backend = "globalprotect", app = "GP", protected = true }
    local runtime = fakeRuntime()
    assert.is_true((backends.act(locked, "restart", runtime)))
    assert.equals(1, #runtime.calls.exec)
    for _, verb in ipairs({ "disconnect", "force" }) do
      assert.is_false((backends.act(locked, verb, runtime)))
    end
    assert.equals(1, #runtime.calls.exec)
  end)
end)

describe("backends.canRestart", function()
  it("is true for the one backend whose tunnel outlives its app", function()
    assert.is_true(backends.canRestart({ id = "g", backend = "globalprotect", app = "GlobalProtect" }))
  end)

  it("is true even when the connection is protected", function()
    assert.is_true(backends.canRestart({ id = "g", backend = "globalprotect", app = "GP", protected = true }))
  end)

  it("is false where quitting the app would take the tunnel with it", function()
    assert.is_false(backends.canRestart({ id = "a", backend = "scutil", service = "a" }))
    assert.is_false(backends.canRestart({ id = "s", backend = "shell", commands = { connect = "up" } }))
  end)

  it("is false without an app to restart, and for anything that is not a profile", function()
    assert.is_false(backends.canRestart({ id = "g", backend = "globalprotect" }))
    assert.is_false(backends.canRestart({ id = "x", backend = "carrier-pigeon" }))
    assert.is_false(backends.canRestart(nil))
    assert.is_false(backends.canRestart("nope"))
  end)
end)

describe("backends.canForce", function()
  local function shell(force, extra)
    local profile = {
      id = "s",
      name = "S",
      backend = "shell",
      commands = { connect = "up", disconnect = "down", force = force },
    }
    for key, value in pairs(extra or {}) do
      profile[key] = value
    end
    return profile
  end

  it("is true only when a shell profile was given a force command", function()
    assert.is_true(backends.canForce(shell("pkill -f vpn")))
    assert.is_false(backends.canForce(shell(nil)))
  end)

  it("is false for the backends that have nothing stronger to run", function()
    assert.is_false(backends.canForce({ id = "a", backend = "scutil", service = "a" }))
    assert.is_false(backends.canForce({ id = "g", backend = "globalprotect", app = "GlobalProtect" }))
  end)

  it("is false for a protected connection, whatever it was given", function()
    assert.is_false(backends.canForce(shell("pkill -f vpn", { protected = true })))
  end)

  it("is false for anything that is not a profile", function()
    assert.is_false(backends.canForce(nil))
    assert.is_false(backends.canForce("nope"))
  end)
end)

describe("backends.act with force", function()
  local profile = {
    id = "s",
    name = "S",
    backend = "shell",
    commands = { connect = "up", disconnect = "down", force = "pkill -f vpn" },
  }

  it("runs the force command, not the disconnect one", function()
    local runtime = fakeRuntime()
    assert.is_true((backends.act(profile, "force", runtime)))
    assert.same({ "pkill -f vpn" }, runtime.calls.exec)
  end)

  it("reports a force command that failed", function()
    local ok, err = backends.act(profile, "force", fakeRuntime({ execOk = false }))
    assert.is_false(ok)
    assert.matches("force command failed", err)
  end)

  it("refuses on a backend with no force at all", function()
    local ok, err = backends.act({ id = "a", name = "A", backend = "scutil", service = "a" }, "force", fakeRuntime())
    assert.is_false(ok)
    assert.matches("no force for", err)
  end)
end)

describe("the awsvpn backend", function()
  local profile = {
    id = "aws",
    name = "AWS",
    backend = "awsvpn",
    app = "AWS VPN Client",
    row = "work",
    commands = { status = "aws-vpn-client status", force = "aws-vpn-client force" },
  }

  local function runtimeWithRows()
    local runtime = fakeRuntime({ exec = "connected" })
    runtime.rows = {}
    runtime.pressRow = function(app, row, button)
      runtime.rows[#runtime.rows + 1] = { app = app, row = row, button = button }
      return true, nil
    end
    return runtime
  end

  it("clicks the named row's own button", function()
    local runtime = runtimeWithRows()
    backends.act(profile, "connect", runtime)
    backends.act(profile, "disconnect", runtime)
    assert.same({ app = "AWS VPN Client", row = "work", button = "Connect" }, runtime.rows[1])
    assert.same({ app = "AWS VPN Client", row = "work", button = "Disconnect" }, runtime.rows[2])
  end)

  it("reads the state from a command instead, which opens no window", function()
    local runtime = runtimeWithRows()
    assert.equals("connected", backends.status(profile, runtime))
    assert.same({ "aws-vpn-client status" }, runtime.calls.exec)
    assert.equals(0, #runtime.rows)
  end)

  it("is unknown when no status command was given, rather than opening one", function()
    local runtime = runtimeWithRows()
    local bare = { id = "aws", name = "AWS", backend = "awsvpn", app = "AWS VPN Client", row = "work" }
    assert.equals("unknown", backends.status(bare, runtime))
    assert.equals(0, #runtime.rows)
  end)

  it("forces with the command, not with a click", function()
    local runtime = runtimeWithRows()
    assert.is_true((backends.act(profile, "force", runtime)))
    assert.same({ "aws-vpn-client force" }, runtime.calls.exec)
  end)

  it("can be forced, because the config gave it the command", function()
    assert.is_true(backends.canForce(profile))
  end)
end)

describe("backends.act, superseding", function()
  local function scutilProfile(overrides)
    local p = { id = "s", name = "S", backend = "scutil", service = "Work VPN" }
    for k, v in pairs(overrides or {}) do
      p[k] = v
    end
    return p
  end

  it("closes a protected connection, which disconnect and force may not", function()
    local locked = scutilProfile({ protected = true })
    local runtime = fakeRuntime()
    assert.is_true((backends.act(locked, "supersede", runtime)))
    for _, verb in ipairs({ "disconnect", "force" }) do
      assert.is_false((backends.act(locked, verb, runtime)))
    end
  end)

  it("runs the backend's own disconnect, not a second code path", function()
    local runtime = fakeRuntime()
    backends.act(scutilProfile(), "supersede", runtime)
    local ran = table.concat(runtime.calls.exec, " ")
    assert.is_truthy(ran:find("stop", 1, true), "scutil --nc stop: " .. ran)
  end)

  it("is refused by a backend with nothing to disconnect with", function()
    local ok, err = backends.act({ id = "x", name = "X", backend = "nosuch" }, "supersede", fakeRuntime())
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("supersede", 1, true), "says the verb asked for")
  end)

  -- `ok and nil or "..."` is not a ternary: `true and nil` is nil, which is
  -- falsy, so the message came back on success too.
  it("says nothing went wrong when nothing went wrong", function()
    local ok, err = backends.act(scutilProfile(), "supersede", fakeRuntime())
    assert.is_true(ok)
    assert.is_nil(err, "a successful call carried an error message: " .. tostring(err))
  end)
end)

describe("quitting and restarting an application", function()
  local function fake()
    return fakeRuntime()
  end

  it("asks the app to quit, then insists, and does not reopen it", function()
    local runtime = fake()
    assert.is_true((backends.act({ id = "g", name = "G", backend = "globalprotect", app = "GP" }, "quit", runtime)))
    local ran = runtime.calls.exec[1]
    assert.is_truthy(ran:find("pkill -x 'GP'", 1, true), ran)
    assert.is_truthy(ran:find("pkill -9 -x 'GP'", 1, true), ran)
    assert.is_nil(ran:find("open -a", 1, true), "quit does not start it again")
  end)

  it("says the app is closed even when it was not running", function()
    -- pkill calls "nothing matched" a failure, and an app that was not there is
    -- an app that is now closed.
    local runtime = fakeRuntime({ exec = { "", false } })
    local ok, err = backends.act({ id = "g", name = "G", backend = "globalprotect", app = "GP" }, "quit", runtime)
    assert.is_true(ok)
    assert.is_nil(err)
  end)

  -- Same command, two different promises.
  it("is offered for both agents, because both are applications", function()
    assert.is_true(backends.canQuit({ id = "g", backend = "globalprotect", app = "GP" }))
    assert.is_true(backends.canRestart({ id = "g", backend = "globalprotect", app = "GP" }))
    assert.is_true(backends.canQuit({ id = "a", backend = "awsvpn", app = "AWS VPN Client", row = "work" }))
    assert.is_true(backends.canRestart({ id = "a", backend = "awsvpn", app = "AWS VPN Client", row = "work" }))
  end)

  it("is not offered for a backend with no application to close", function()
    assert.is_false(backends.canQuit({ id = "s", backend = "scutil", service = "s" }))
    assert.is_false(backends.canQuit({ id = "h", backend = "shell", commands = {} }))
    assert.is_false(backends.canQuit({ id = "g", backend = "globalprotect" }), "no app named")
    assert.is_false(backends.canQuit(nil))
  end)

  -- The distinction the whole thing turns on: closing GlobalProtect closes a
  -- window, closing the AWS client ends the session.
  it("still closes a protected agent whose tunnel outlives it", function()
    local locked = { id = "g", name = "G", backend = "globalprotect", app = "GP", protected = true }
    assert.is_true(backends.canQuit(locked))
    assert.is_true(backends.canRestart(locked))
    assert.is_true((backends.act(locked, "quit", fake())))
    assert.is_true((backends.act(locked, "restart", fake())))
  end)

  it("refuses to close a protected client that is its own tunnel", function()
    local locked = { id = "a", name = "A", backend = "awsvpn", app = "AWS VPN Client", row = "w", protected = true }
    assert.is_false(backends.canQuit(locked))
    assert.is_false(backends.canRestart(locked))
    local ok, err = backends.act(locked, "quit", fake())
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("protected", 1, true), tostring(err))
  end)

  it("closes that same client happily once it is not protected", function()
    local open = { id = "a", name = "A", backend = "awsvpn", app = "AWS VPN Client", row = "w" }
    assert.is_true((backends.act(open, "quit", fake())))
  end)
end)
