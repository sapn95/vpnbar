--- The three ways vpnbar knows to reach a VPN, behind one interface.
---
--- Nothing here calls Hammerspoon or a shell directly: every backend is handed
--- a `runtime` and asks it. That keeps the decisions — which command, which
--- verb, which state wins — under test, and leaves the adapters in the Spoon
--- doing nothing a test would want to check.
---
--- A runtime provides:
---   exec(command)        -> stdout, ok        run a shell command
---   ifconfig()           -> stdout            output of `ifconfig`
---   press(app, verbs)    -> ok, err           click a control in an app's menu-bar panel
---   panel(app)           -> state             read that panel's state text

local parse = require("vpnbar.parse")

local backends = {}

--- Wrap a string so a shell sees exactly the bytes given, including quotes and
--- spaces. Service names come from `scutil --nc list` and from the config file,
--- and both can contain either.
--- @param value string
--- @return string
function backends.shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local scutil = {}

function scutil.status(profile, runtime)
  local out = runtime.exec("/usr/sbin/scutil --nc status " .. backends.shellQuote(profile.service))
  return parse.scutilStatus(out)
end

function scutil.connect(profile, runtime)
  local _, ok = runtime.exec("/usr/sbin/scutil --nc start " .. backends.shellQuote(profile.service))
  return ok and true or false, ok and nil or "scutil refused to start the connection"
end

function scutil.disconnect(profile, runtime)
  local _, ok = runtime.exec("/usr/sbin/scutil --nc stop " .. backends.shellQuote(profile.service))
  return ok and true or false, ok and nil or "scutil refused to stop the connection"
end

local globalprotect = {}

-- The words to look for on a control in the panel. They are matched against
-- every title, description and value in it, so "Disconnect" finds the button
-- on the panel and the item in the options menu without knowing which one the
-- agent decided to show. Deliberately NOT "Disable": on a GlobalProtect panel
-- that is a different action with a different meaning, and one of them is not
-- reversible from this menu.
globalprotect.CONNECT_VERBS = { "connect" }
globalprotect.DISCONNECT_VERBS = { "disconnect" }

function globalprotect.status(profile, runtime)
  return runtime.panel(profile.app)
end

function globalprotect.connect(profile, runtime)
  return runtime.press(profile.app, globalprotect.CONNECT_VERBS)
end

function globalprotect.disconnect(profile, runtime)
  return runtime.press(profile.app, globalprotect.DISCONNECT_VERBS)
end

local shell = {}

function shell.status(profile, runtime)
  local command = profile.commands and profile.commands.status
  if not command then
    return "unknown"
  end
  return parse.state(runtime.exec(command))
end

function shell.connect(profile, runtime)
  local _, ok = runtime.exec(profile.commands.connect)
  return ok and true or false, ok and nil or "the connect command failed"
end

function shell.disconnect(profile, runtime)
  local _, ok = runtime.exec(profile.commands.disconnect)
  return ok and true or false, ok and nil or "the disconnect command failed"
end

function shell.force(profile, runtime)
  local _, ok = runtime.exec(profile.commands.force)
  return ok and true or false, ok and nil or "the force command failed"
end

backends.byName = { scutil = scutil, globalprotect = globalprotect, shell = shell }

--- Is there a harder way to bring this connection down than asking politely?
---
--- Only where one genuinely exists. `scutil --nc stop` has no stronger form,
--- and the GlobalProtect panel has one Disconnect and nothing behind it —
--- offering a "force" that runs the identical command would be a menu item
--- that lies about being stronger. A shell profile has one exactly when its
--- config gives it one.
--- @param profile table
--- @return boolean
function backends.canForce(profile)
  if type(profile) ~= "table" or profile.monitor then
    return false
  end
  return profile.backend == "shell" and type(profile.commands) == "table" and profile.commands.force ~= nil
end

--- The state of one connection.
---
--- A configured probe wins over the backend's own answer, always. Reading an
--- interface costs one `ifconfig` and touches nothing; the alternatives open a
--- panel or shell out per connection per tick, and one of them cannot even be
--- asked without moving something on screen.
--- @param profile table
--- @param runtime table
--- @return string state
function backends.status(profile, runtime)
  if profile.probe then
    local state = parse.probeState(runtime.ifconfig(), profile.probe)
    if state ~= "unknown" then
      return state
    end
  end
  local backend = backends.byName[profile.backend]
  if not backend then
    return "unknown"
  end
  local ok, state = pcall(backend.status, profile, runtime)
  return (ok and parse.STATES[state] and state) or "unknown"
end

--- @param profile table
--- @param verb string "connect" or "disconnect"
--- @param runtime table
--- @return boolean ok, string|nil err
function backends.act(profile, verb, runtime)
  -- Enforced here as well as in the menu. The menu decides what is offered;
  -- this decides what happens, and a monitored connection has to be safe from
  -- a dispatch that reaches it by any other route.
  if profile.monitor then
    return false, ("%s is monitored only"):format(profile.name or profile.id or "this connection")
  end
  local backend = backends.byName[profile.backend]
  if not backend or not backend[verb] then
    return false, ("no %s for a %s connection"):format(verb, tostring(profile.backend))
  end
  local called, ok, err = pcall(backend[verb], profile, runtime)
  if not called then
    return false, tostring(ok)
  end
  return ok and true or false, err
end

return backends
