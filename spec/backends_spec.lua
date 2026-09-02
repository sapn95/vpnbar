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
  local ifconfig = "utun4: flags=8051<UP> mtu 1400\n\tinet 10.11.12.13 --> 10.11.12.13 netmask 0xffffffff"

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
