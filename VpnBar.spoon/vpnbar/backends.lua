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

-- `ok and nil or "..."` reads like a ternary and is not one: `true and nil` is
-- `nil`, which is falsy, so the `or` branch runs and the message came back on
-- success as well as on failure. Nothing acted on it, because every caller
-- tests the boolean first, so it sat in six places until a test asked one of
-- them what it returned.
local function outcome(ok, message)
  if ok then
    return true, nil
  end
  return false, message
end

function scutil.connect(profile, runtime)
  local _, ok = runtime.exec("/usr/sbin/scutil --nc start " .. backends.shellQuote(profile.service))
  return outcome(ok, "scutil refused to start the connection")
end

function scutil.disconnect(profile, runtime)
  local _, ok = runtime.exec("/usr/sbin/scutil --nc stop " .. backends.shellQuote(profile.service))
  return outcome(ok, "scutil refused to stop the connection")
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

-- Seconds given to the agent to go away by itself, and to settle once it is
-- gone. Both are spent inside one blocking `exec`, which is why the caller runs
-- this off the run loop like every other press.
--- Seconds between asking an app to quit and insisting, and between insisting
--- and opening it again.
backends.APP_QUIT_GRACE = 2
backends.APP_SETTLE = 1

--- Close an application by name.
---
--- `pkill -x` matches on the process name, which for these agents is also the
--- application name the config already carries. TERM first and KILL after the
--- grace period: the second is a no-op when the first worked, and this is asked
--- for exactly when an app has stopped answering, which is when TERM alone is
--- least likely to land.
--- @param app string
--- @return string command
function backends.quitCommand(app)
  local quoted = backends.shellQuote(app)
  return table.concat({
    "/usr/bin/pkill -x " .. quoted,
    "/bin/sleep " .. tostring(backends.APP_QUIT_GRACE),
    "/usr/bin/pkill -9 -x " .. quoted,
  }, " ; ")
end

--- Close an application and open it again.
---
--- The exit status has to come from `open`, because `pkill` reports "nothing
--- matched" as a failure and an app that had already crashed would then look
--- like an error at the moment it was being fixed.
--- @param app string
--- @return string command
function backends.restartCommand(app)
  return table.concat({
    backends.quitCommand(app),
    "/bin/sleep " .. tostring(backends.APP_SETTLE),
    "/usr/bin/open -a " .. backends.shellQuote(app),
  }, " ; ")
end

--- Quitting and restarting, for any backend that names an application.
---
--- What it *means* differs by backend and that difference is the whole reason
--- `appOwnsTunnel` exists. Closing GlobalProtect closes a user interface: its
--- tunnel is held by a root service and a system extension
--- ([ADR 0001](../../docs/adr/0001-globalprotect-is-not-a-scutil-vpn.md)).
--- Closing the AWS client takes the session with it, because that client is the
--- tunnel's own parent. Same command, two different promises, and only one of
--- them may be made about a `protected` connection
--- ([ADR 0028](../../docs/adr/0028-quit-and-restart-are-per-application.md)).
local function quitApp(profile, runtime)
  runtime.exec(backends.quitCommand(profile.app))
  -- Always a success. `pkill` calls "nothing matched" a failure, and an app that
  -- was not running is an app that is now closed, which is what was asked for.
  return true, nil
end

local function restartApp(profile, runtime)
  local _, ok = runtime.exec(backends.restartCommand(profile.app))
  return outcome(ok, "could not open " .. tostring(profile.app) .. " again")
end

globalprotect.quit = quitApp
globalprotect.restart = restartApp

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
  return outcome(ok, "the connect command failed")
end

function shell.disconnect(profile, runtime)
  local _, ok = runtime.exec(profile.commands.disconnect)
  return outcome(ok, "the disconnect command failed")
end

function shell.force(profile, runtime)
  local _, ok = runtime.exec(profile.commands.force)
  return outcome(ok, "the force command failed")
end

-- The AWS VPN Client. Its window lists one row per profile, and the management
-- interface behind it cannot say which of them is up — `state` reports that a
-- session exists, not whose. So the two halves are answered by two different
-- things: the state by a command that costs nothing and opens no window, the
-- clicking by the row itself.
local awsvpn = {}

awsvpn.status = shell.status
awsvpn.force = shell.force

function awsvpn.connect(profile, runtime)
  return runtime.pressRow(profile.app, profile.row, "Connect")
end

function awsvpn.disconnect(profile, runtime)
  return runtime.pressRow(profile.app, profile.row, "Disconnect")
end

awsvpn.quit = quitApp
awsvpn.restart = restartApp
-- Quitting this client ends the session: it is the tunnel's parent process, so
-- the same command that closes a window elsewhere is a disconnect here.
awsvpn.appOwnsTunnel = true

backends.byName = { scutil = scutil, globalprotect = globalprotect, shell = shell, awsvpn = awsvpn }

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
  if type(profile) ~= "table" or profile.protected then
    return false
  end
  -- Whether a force exists is a question about the config, not about the
  -- backend: any profile that was given the harder command has one.
  return type(profile.commands) == "table" and profile.commands.force ~= nil
end

--- Can this connection's app be restarted from the menu?
---
--- A question about the backend, not about the config: only where quitting the
--- app leaves the tunnel where it is. Deliberately not gated on `protected` —
--- restarting the agent is the repair for a panel that has stopped answering, and
--- the connection that must stay up is the one that needs it most
--- ([ADR 0021](../../docs/adr/0021-restarting-the-agent-is-not-a-disconnect.md)).
--- @param profile table
--- @return boolean
local function appVerb(profile, verb)
  if type(profile) ~= "table" then
    return false
  end
  local backend = backends.byName[profile.backend]
  if backend == nil or backend[verb] == nil or profile.app == nil then
    return false
  end
  -- Where closing the app closes the tunnel, closing it is a disconnect, and a
  -- protected connection refuses those from every button in the menu.
  if profile.protected and backend.appOwnsTunnel then
    return false
  end
  return true
end

function backends.canRestart(profile)
  return appVerb(profile, "restart")
end

function backends.canQuit(profile)
  return appVerb(profile, "quit")
end

-- What a protected connection still allows. Connecting is the direction its
-- protection points in. Restarting the agent does not reach the tunnel at all,
-- and a rule that refused it would leave the one connection that may not be
-- disconnected as the one whose stuck panel cannot be repaired either.
--- Verbs a `protected` connection still allows.
---
--- `connect`, because protection points one way. `restart`, because it closes an
--- application and not a tunnel
--- ([ADR 0021](../../docs/adr/0021-restarting-the-agent-is-not-a-disconnect.md)).
--- And `supersede`, which is a disconnect asked for by the one-at-a-time rule
--- when a connection ranked above this one is already up
--- ([ADR 0026](../../docs/adr/0026-one-at-a-time-outranks-protection.md)).
---
--- `supersede` is deliberately not a verb any menu item produces. Every button
--- goes on being refused, so protection still means what the menu says it means.
backends.PROTECTED_VERBS = { connect = true, restart = true, supersede = true, quit = true }

--- The verbs that act on an application rather than on a tunnel. They are only
--- allowed on a protected connection where the application is not the tunnel.
backends.APP_VERBS = { quit = true, restart = true }

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
  -- this decides what happens, and a protected connection has to be safe from
  -- a dispatch that reaches it by any other route.
  --
  -- Protected means protected from being *brought down*. Connecting one is
  -- always allowed — a tunnel that must stay up is exactly the one worth
  -- bringing up automatically — and so is restarting the app that reports it,
  -- which is a different thing from the tunnel. See `backends.PROTECTED_VERBS`.
  local backendFor = backends.byName[profile.backend]
  local appIsTheTunnel = backendFor ~= nil and backendFor.appOwnsTunnel == true
  local allowed = backends.PROTECTED_VERBS[verb] and not (appIsTheTunnel and backends.APP_VERBS[verb])
  if profile.protected and not allowed then
    return false, ("%s is protected from being disconnected"):format(profile.name or profile.id or "this connection")
  end
  local backend = backends.byName[profile.backend]
  -- `supersede` is a disconnect wearing a different name so the protection
  -- check above can tell them apart. No backend implements it; every backend
  -- already knows how to close its own connection.
  local action = verb == "supersede" and "disconnect" or verb
  if not backend or not backend[action] then
    return false, ("no %s for a %s connection"):format(verb, tostring(profile.backend))
  end
  local called, ok, err = pcall(backend[action], profile, runtime)
  if not called then
    return false, tostring(ok)
  end
  return ok and true or false, err
end

return backends
