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
local routes = require("vpnbar.routes")

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
--- Every way into this agent is a click in its own panel, so there is nothing
--- to press while the screen is locked. Measured on 2026-10-15: twenty presses
--- between 18:21 and 22:33, every one of them answered `GlobalProtect offers no
--- "connect" right now`, and the lock log says `locked` across the whole window
--- ([ADR 0042](../../docs/adr/0042-nothing-happens-while-nobody-is-there.md)).
globalprotect.pressesInterface = true

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
    -- The exit status of `pkill` answers the wrong question: it reports
    -- "nothing matched" as a failure, which is the normal outcome of a kill
    -- that worked. Asking whether the process is still there answers the right
    -- one, and it is the only way a `pkill` that failed for a real reason —
    -- no permission, a command that is not there — is told apart from success.
    "! /usr/bin/pgrep -x " .. quoted .. " >/dev/null",
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

--- How often launchd is asked, and how many times, while an agent goes or comes.
---
--- Every wait below is a count, never a condition alone: the command runs
--- inside one blocking `exec`, and a loop that waited for launchd without a
--- bound would hold Hammerspoon for as long as launchd took.
---
--- Twenty-five seconds for a removal. Measured on 2026-11-13: `bootout` at
--- 22:20:26.5, the agent gone at 22:20:28.6, because it unloads its network
--- extension configuration before it exits. Two seconds on a good day. The
--- bound is past launchd's own: the GlobalProtect plist sets no `ExitTimeOut`,
--- so launchd waits its default twenty seconds before it kills the agent, and
--- a wait that gave up sooner would skip the load and leave the service to be
--- removed after the command had finished. Five tries for a `bootstrap`, a second apart, and
--- five seconds for launchd to say the service runs. A copy that launchd does
--- not own gets five seconds to leave on a TERM and two more after a KILL.
backends.AGENT_POLL = 0.5
backends.AGENT_REMOVAL_TRIES = 50
backends.AGENT_BOOTSTRAP_TRIES = 5
backends.AGENT_START_TRIES = 10
backends.STRAY_TERM_TRIES = 10
backends.STRAY_KILL_TRIES = 4

--- The uid is asked for rather than remembered, because a uid baked in is a
--- uid that is wrong for anybody else.
local GUI_DOMAIN = "gui/$(/usr/bin/id -u)"

--- Ask launchd what it knows about an agent.
---
--- `launchctl print` fails when the service is not loaded and prints its state
--- when it is, so one command answers both questions the adapter has: is it
--- there, and does it run. Its complaint about a missing service goes to
--- stderr and is dropped, because "not loaded" is an answer here and not a
--- fault.
--- @param agent table { label = string, plist = string }
--- @return string command
function backends.agentPrintCommand(agent)
  return ("/bin/launchctl print %s/%s 2>/dev/null"):format(GUI_DOMAIN, agent.label)
end

--- Shell: does launchd have this service?
local function agentIsLoaded(agent)
  return ("/bin/launchctl print %s/%s >/dev/null 2>&1"):format(GUI_DOMAIN, agent.label)
end

--- Shell: does launchd say this service runs?
---
--- Not `pgrep`. A process of that name proves nothing about launchd: on
--- 2026-11-13 the final `pgrep -x GlobalProtect` of a restart matched the old
--- agent on its way out, reported success, and left a machine where
--- `launchctl print` answered `Could not find service`
--- ([ADR 0048](../../docs/adr/0048-an-agent-that-stays-loaded.md)).
local function agentIsRunning(agent)
  return backends.agentPrintCommand(agent) .. " | /usr/bin/grep -Eq 'state = running|pid = [0-9]'"
end

--- Shell: can launchd load this service at all?
---
--- The plist has to be there and the service must not be disabled. Asked
--- before anything is stopped: a copy beside launchd is the only client there
--- is, and stopping it for a load that cannot work would leave none.
local function agentCanLoad(agent)
  return ("[ -r %s ] && ! /bin/launchctl print-disabled %s 2>/dev/null | /usr/bin/grep -Fq %s"):format(
    backends.shellQuote(agent.plist),
    GUI_DOMAIN,
    backends.shellQuote(('"%s" => disabled'):format(agent.label))
  )
end

--- Shell: repeat a sleep while something holds, a bounded number of times.
local function waitWhile(condition, tries)
  return ('n=0 ; while [ "$n" -lt %d ] && %s ; do /bin/sleep %s ; n=$((n+1)) ; done'):format(
    tries,
    condition,
    tostring(backends.AGENT_POLL)
  )
end

--- Stop a copy of the application that launchd does not own.
---
--- Every step asks launchd first and does nothing while the service is loaded,
--- so this never signals the agent itself: that kill is the race against
--- `KeepAlive` that [ADR 0033](../../docs/adr/0033-stopping-an-agent-that-launchd-restarts.md)
--- removed. What is left when the service is not loaded is a copy somebody
--- started with `open`, which nothing restarts, so a signal sticks.
--- TERM first, because the agent logs out of its gateway on a TERM.
---
--- Where the copy is stopped to make way for the agent, it is only stopped once
--- launchd can load the agent: with the plist gone or the service disabled,
--- the copy is the only client there is.
--- @return table commands
local function strayCommands(agent, app, toReload)
  local quoted = backends.shellQuote(app)
  local stray = ("! %s && /usr/bin/pgrep -x %s >/dev/null"):format(agentIsLoaded(agent), quoted)
  if toReload then
    stray = agentCanLoad(agent) .. " && " .. stray
  end
  return {
    stray .. " && /usr/bin/pkill -x " .. quoted,
    waitWhile(stray, backends.STRAY_TERM_TRIES),
    stray .. " && /usr/bin/pkill -9 -x " .. quoted,
    waitWhile(stray, backends.STRAY_KILL_TRIES),
  }
end

--- Load the service and wait for launchd to say it runs.
---
--- `bootstrap` is tried again while launchd does not have the service: it
--- answers error 5 or 37 while a removal is still in flight. The last command
--- is the answer the caller gets, and it is launchd's.
--- @return table commands
local function startCommands(agent)
  local bootstrap = ("/bin/launchctl bootstrap %s %s"):format(GUI_DOMAIN, backends.shellQuote(agent.plist))
  return {
    ('n=0 ; while [ "$n" -lt %d ] && %s && ! %s ; do %s || /bin/sleep 1 ; n=$((n+1)) ; done'):format(
      backends.AGENT_BOOTSTRAP_TRIES,
      agentCanLoad(agent),
      agentIsLoaded(agent),
      bootstrap
    ),
    -- Only for a service launchd has. Waiting for one it refused to load is
    -- seconds of a blocked menu for an answer that is already known.
    waitWhile(agentIsLoaded(agent) .. " && ! " .. agentIsRunning(agent), backends.AGENT_START_TRIES),
    agentIsRunning(agent),
  }
end

--- Stop an application that launchd has been told to keep alive.
---
--- `pkill` against such a service is a race nobody wins. The GlobalProtect
--- agent ships with `KeepAlive` set to true, so it is running again seconds
--- after any kill, and from the menu bar that looks exactly like a Quit that
--- did nothing ([ADR 0033](../../docs/adr/0033-stopping-an-agent-that-launchd-restarts.md)).
---
--- `launchctl bootout` unloads the service instead, so there is nothing left
--- to restart it. In the person's own GUI domain it needs no root, which was
--- measured rather than assumed.
---
--- `bootout` returns before the service is gone. Measured on 2026-11-13: it
--- returned at once, the agent exited two seconds later, and only then did
--- launchd log `removing service`. So the command waits until `launchctl
--- print` fails, which is launchd saying the service is removed. One fixed
--- second was the old wait, and it was half of what the agent needed
--- ([ADR 0048](../../docs/adr/0048-an-agent-that-stays-loaded.md)).
---
--- A copy running beside launchd is stopped after that, and the command ends
--- by asking both questions: launchd has no such service, and no process of
--- that name is left. `bootout` itself reports "not loaded" as a failure, which
--- is the normal answer when somebody has already stopped it, so its own exit
--- status is not the one that counts.
--- @param agent table { label = string, plist = string }
--- @param app string
--- @param toReload boolean|nil true when a load follows, see `strayCommands`
--- @return string command
function backends.bootoutCommand(agent, app, toReload)
  local parts = {
    ("/bin/launchctl bootout %s/%s"):format(GUI_DOMAIN, agent.label),
    waitWhile(agentIsLoaded(agent), backends.AGENT_REMOVAL_TRIES),
  }
  for _, command in ipairs(strayCommands(agent, app, toReload)) do
    parts[#parts + 1] = command
  end
  parts[#parts + 1] = ("! %s && ! /usr/bin/pgrep -x %s >/dev/null"):format(
    agentIsLoaded(agent),
    backends.shellQuote(app)
  )
  return table.concat(parts, " ; ")
end

--- Unload a launchd agent and load it again.
---
--- `open -a` would start the application beside launchd rather than under it,
--- which is a second copy with nothing keeping it alive. Loading the plist
--- back puts the service where it was.
---
--- The load only runs once the unload has finished. On 2026-11-13 the
--- `bootstrap` ran one second after the `bootout`, hit a service launchd was
--- still tearing down and loaded nothing. The restart reported success and the
--- agent was gone from launchd
--- ([ADR 0048](../../docs/adr/0048-an-agent-that-stays-loaded.md)).
--- @param agent table { label = string, plist = string }
--- @param app string
--- @return string command
function backends.bootstrapCommand(agent, app)
  return ("%s && { %s ; }"):format(backends.bootoutCommand(agent, app, true), table.concat(startCommands(agent), " ; "))
end

--- Make sure a launchd agent is loaded and running, without unloading it.
---
--- Does nothing to a service launchd already has. Where launchd has none, a
--- copy of the application running beside it is stopped first, and then the
--- plist is loaded. This is what vpnbar runs wherever it would otherwise open
--- the application ([ADR 0048](../../docs/adr/0048-an-agent-that-stays-loaded.md)).
--- @param agent table { label = string, plist = string }
--- @param app string
--- @return string command
function backends.loadCommand(agent, app)
  local parts = strayCommands(agent, app, true)
  for _, command in ipairs(startCommands(agent)) do
    parts[#parts + 1] = command
  end
  return table.concat(parts, " ; ")
end

--- What launchd said about an agent, as one word.
---
--- `missing` when the print failed, which is launchd having no such service.
--- `running` when it names a running state or a pid, `loaded` otherwise.
--- @param out string|nil output of `agentPrintCommand`
--- @param ok boolean whether it exited zero
--- @return string "missing"|"loaded"|"running"
function backends.agentState(out, ok)
  if not ok then
    return "missing"
  end
  out = tostring(out or "")
  if out:find("state = running", 1, true) or out:find("pid = %d") then
    return "running"
  end
  return "loaded"
end

--- Restart one launchd service, in whichever domain it was registered in.
---
--- `kickstart -k` stops it and starts it again in one step, which is what
--- `KeepAlive` turns a plain stop into anyway. The uid is asked for rather than
--- remembered, because a uid baked in is a uid that is wrong for anybody else.
--- @param service table { label = string, domain = "gui"|"system" }
--- @return string command
function backends.kickstartCommand(service)
  local domain = service.domain == "system" and "system" or "gui/$(/usr/bin/id -u)"
  return ("/bin/launchctl kickstart -k %s/%s"):format(domain, service.label)
end

--- The service behind a connection's client, where its backend names one.
--- @param profile table
--- @return table|nil
function backends.serviceOf(profile)
  if type(profile) ~= "table" then
    return nil
  end
  local backend = backends.byName[profile.backend]
  return backend and backend.SERVICE or nil
end

--- May this connection's service be restarted from the menu?
---
--- Allowed on a `protected` connection for the same reason a restart is: it
--- ends with the service running, and it is the only repair for a client whose
--- service has stopped answering
--- ([ADR 0034](../../docs/adr/0034-a-protected-connection-keeps-its-repair.md)).
--- @param profile table
--- @return boolean
function backends.canRepair(profile)
  return backends.serviceOf(profile) ~= nil
end

--- Does restarting it need an administrator?
--- @param service table|nil
--- @return boolean
function backends.serviceNeedsAdmin(service)
  return type(service) == "table" and service.domain == "system"
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
--- The launchd agent behind a backend's application, where there is one.
--- @param profile table
--- @return table|nil { label = string, plist = string }
function backends.agentOf(profile)
  if type(profile) ~= "table" then
    return nil
  end
  local backend = backends.byName[profile.backend]
  return backend and backend.AGENT or nil
end
local agentOf = backends.agentOf

--- The launchd agent behind an application name, where the config has a
--- connection through that application whose backend names one.
--- @param app string
--- @param cfg table|nil
--- @return table|nil
function backends.agentForApp(app, cfg)
  if type(cfg) ~= "table" or type(cfg.profiles) ~= "table" then
    return nil
  end
  for _, profile in ipairs(cfg.profiles) do
    if type(profile) == "table" and profile.app == app and agentOf(profile) then
      return agentOf(profile)
    end
  end
  return nil
end

--- The command that puts an application on its feet.
---
--- `open -a` for a plain application. Never for one that is a launchd agent:
--- `open` starts it beside launchd, with no `KeepAlive`, as a second kind of
--- GlobalProtect that the Quit and the Restart in this menu do not reach. For
--- an agent the service is loaded instead
--- ([ADR 0048](../../docs/adr/0048-an-agent-that-stays-loaded.md)).
--- @param app string
--- @param cfg table|nil
--- @return string command
function backends.launchCommand(app, cfg)
  local agent = backends.agentForApp(app, cfg)
  if agent then
    return backends.loadCommand(agent, app)
  end
  return "/usr/bin/open -a " .. backends.shellQuote(app)
end

local function quitApp(profile, runtime)
  local agent = agentOf(profile)
  local command = agent and backends.bootoutCommand(agent, profile.app) or backends.quitCommand(profile.app)
  local _, ok = runtime.exec(command)
  -- The command ends by checking that nothing of that name is left, so this is
  -- "it is closed" rather than "the kill returned zero".
  return outcome(ok, tostring(profile.app) .. " is still running")
end

local function restartApp(profile, runtime)
  local agent = agentOf(profile)
  local command = agent and backends.bootstrapCommand(agent, profile.app) or backends.restartCommand(profile.app)
  local _, ok = runtime.exec(command)
  return outcome(ok, "could not open " .. tostring(profile.app) .. " again")
end

globalprotect.quit = quitApp
globalprotect.restart = restartApp

--- Load the agent where launchd has lost it. Asked for by the planner, never
--- by a menu row ([ADR 0048](../../docs/adr/0048-an-agent-that-stays-loaded.md)).
function globalprotect.load(profile, runtime)
  local _, ok = runtime.exec(backends.loadCommand(globalprotect.AGENT, profile.app))
  return outcome(ok, "launchd did not start " .. tostring(profile.app))
end

--- The launchd agent that is the GlobalProtect application.
---
--- `KeepAlive` is true in this plist, so launchd starts it again within seconds
--- of any kill. Stopping it means unloading the service, and starting it again
--- means loading the plist rather than opening the app
--- ([ADR 0033](../../docs/adr/0033-stopping-an-agent-that-launchd-restarts.md)).
globalprotect.AGENT = {
  label = "com.paloaltonetworks.gp.pangpa",
  plist = "/Library/LaunchAgents/com.paloaltonetworks.gp.pangpa.plist",
}

--- The service behind the agent, which is the thing that holds the tunnel.
---
--- Restarting it is the repair for a client whose own service has stopped
--- answering it: measured, the agent logs a connect and the service logs
--- nothing at all, and nothing the agent does gets through
--- ([ADR 0039](../../docs/adr/0039-putting-a-service-back-on-its-feet.md)).
--- In `gui`, so it needs no administrator, which is not obvious from a process
--- that runs as root.
globalprotect.SERVICE = {
  label = "com.paloaltonetworks.gp.pangps",
  domain = "gui",
}

--- Every way into this client is its menu-bar item: the panel opens from it,
--- and the panel is where Connect is. An agent that runs without one cannot be
--- pressed at all ([ADR 0048](../../docs/adr/0048-an-agent-that-stays-loaded.md)).
globalprotect.needsMenuBarItem = true

--- Stopping this agent ends the session.
---
--- Measured, after two years of this file claiming the opposite: the agent
--- exits, and 2 seconds later the tunnel is down and the gateway has logged the
--- user out. The service behind it keeps running and holds nothing. So closing
--- GlobalProtect *is* a disconnect, and the next connect wants a login
--- ([ADR 0033](../../docs/adr/0033-stopping-an-agent-that-launchd-restarts.md),
--- which reverses [ADR 0021](../../docs/adr/0021-restarting-the-agent-is-not-a-disconnect.md)).
globalprotect.appOwnsTunnel = true

--- Where the agent writes one line per event. World-readable, and the same
--- file that diagnosed every GlobalProtect incident in this repository.
globalprotect.EVENT_LOG = "/Library/Logs/PaloAltoNetworks/GlobalProtect/pan_gp_event.log"

--- The lines in the event log that say anything about the session, in the
--- order they were written. Only the markers, from the whole file: a fixed
--- number of trailing lines was the first version, and at the agent's measured
--- rate of around twenty lines per network change a logout scrolled out of it
--- after a dozen of those, which read as "disconnected" and opened the SAML
--- window on schedule. The file is small and the grep is bounded by it.
globalprotect.SESSION_MARKERS = {
  "User was logged out of Gateway",
  "Auth Failed during login",
  "Cleared user auth cookie",
  "Invalid user auth cookie",
  "Auto Gateway login finished",
  "IPSec tunnel creation finished",
  "Tunnel is restored",
}

--- @param log string
--- @return string command
function globalprotect.sessionCommand(log)
  local parts = { "/usr/bin/grep -F" }
  for _, marker in ipairs(globalprotect.SESSION_MARKERS) do
    parts[#parts + 1] = "-e " .. backends.shellQuote(marker)
  end
  parts[#parts + 1] = backends.shellQuote(log)
  parts[#parts + 1] = "2>/dev/null | /usr/bin/tail -n 20"
  return table.concat(parts, " ")
end

--- Has the gateway ended the session, so that the next connect starts a login
--- rather than a tunnel? Asked only once the probe has said the tunnel is
--- down: it turns "down" into "down, and a person may be needed", which is
--- what keeps autoconnect from starting that login on a locked screen.
--- @param profile table
--- @param runtime table
--- @return boolean
function globalprotect.needsLogin(profile, runtime)
  local log = profile.eventLog or globalprotect.EVENT_LOG
  local out = runtime.exec(globalprotect.sessionCommand(log))
  return parse.globalprotectNeedsLogin(out)
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

-- The AWS VPN Client. The state comes from a command that costs nothing and
-- opens no window, because the client cannot be asked which profile is up
-- ([ADR 0027](../../docs/adr/0027-the-aws-client-stopped-having-a-management-interface.md)).
-- The two directions are not symmetrical in its window: a connection that is up
-- has a block of its own with a Disconnect in it, while starting one means
-- setting a chooser and pressing the single Connect beside it
-- ([ADR 0032](../../docs/adr/0032-the-aws-client-is-driven-by-keyboard.md)).
local awsvpn = {}

awsvpn.status = shell.status
awsvpn.force = shell.force

function awsvpn.connect(profile, runtime)
  return runtime.connectRow(profile.app, profile.row)
end

function awsvpn.disconnect(profile, runtime)
  return runtime.pressRow(profile.app, profile.row, "Disconnect")
end

--- The service behind this client, which is where its tunnel lives.
---
--- A `LaunchDaemon` with `KeepAlive` set, so it is in the system domain and
--- restarting it takes an administrator, unlike the GlobalProtect one.
--- Its window is the only way in as well, and it is not drawn while the screen
--- is locked ([ADR 0042](../../docs/adr/0042-nothing-happens-while-nobody-is-there.md)).
awsvpn.pressesInterface = true

awsvpn.SERVICE = {
  label = "com.amazonaws.acvc.osx.core",
  domain = "system",
}

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
--- Does reaching this connection mean clicking in an application's window?
---
--- `scutil` and a `shell` profile are commands, and a command runs the same
--- whether or not anybody is at the machine. A panel and a client window are
--- not drawn while the screen is locked, so a press into one is an attempt that
--- was certain to fail before it was made
--- ([ADR 0042](../../docs/adr/0042-nothing-happens-while-nobody-is-there.md)).
--- @param profile table
--- @return boolean
function backends.pressesInterface(profile)
  if type(profile) ~= "table" then
    return false
  end
  local backend = backends.byName[profile.backend]
  return backend ~= nil and backend.pressesInterface == true
end

--- Is this connection only reachable through its client's menu-bar item?
--- @param profile table
--- @return boolean
function backends.needsMenuBarItem(profile)
  if type(profile) ~= "table" then
    return false
  end
  local backend = backends.byName[profile.backend]
  return backend ~= nil and backend.needsMenuBarItem == true
end

--- Does the config give this connection a harder way down, whether or not it
--- is protected? `canForce` answers for the menu row, which protection removes;
--- this answers for **Disconnect everything**, which protection does not stop
--- ([ADR 0041](../../docs/adr/0041-everything-means-everything.md)).
--- @param profile table
--- @return boolean
function backends.hasForceCommand(profile)
  return type(profile) == "table" and type(profile.commands) == "table" and profile.commands.force ~= nil
end

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
--- Is any connection through this application protected?
---
--- One application, several connections: the AWS client lists a profile per
--- endpoint, and closing it closes all of them. Asking only about the profile
--- somebody clicked would let an unprotected connection close a client that a
--- protected one is also using, which is a disconnect of the protected tunnel by
--- another name.
---
--- Without a config there is nothing to widen the question with, so the answer
--- is about the one profile — the same as before, and the callers that matter
--- all pass one.
--- @param profile table
--- @param cfg table|nil
--- @return boolean
local function appIsProtected(profile, cfg)
  if profile.protected then
    return true
  end
  if type(cfg) ~= "table" or type(cfg.profiles) ~= "table" then
    return false
  end
  for _, other in ipairs(cfg.profiles) do
    if type(other) == "table" and other.app == profile.app and other.protected then
      return true
    end
  end
  return false
end

local function appVerb(profile, verb, cfg)
  if type(profile) ~= "table" then
    return false
  end
  local backend = backends.byName[profile.backend]
  if backend == nil or backend[verb] == nil or profile.app == nil then
    return false
  end
  -- Where closing the app closes the tunnel, closing it is a disconnect, and a
  -- protected connection refuses those from every button in the menu.
  --
  -- A restart is the exception, and the direction is the reason: a quit ends
  -- with the connection down and a restart ends with the client running, which
  -- is the only repair in this menu for a client that has stopped answering.
  -- The connection that may not be disconnected is the one that needs it most,
  -- and the dialog says what it costs before anything is closed
  -- ([ADR 0034](../../docs/adr/0034-a-protected-connection-keeps-its-repair.md)).
  if verb ~= "restart" and backend.appOwnsTunnel and appIsProtected(profile, cfg) then
    return false
  end
  return true
end

function backends.canRestart(profile, cfg)
  return appVerb(profile, "restart", cfg)
end

function backends.canQuit(profile, cfg)
  return appVerb(profile, "quit", cfg)
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
---
--- `renew` is the planner's as well: a tunnel that is up and carries nothing,
--- taken down so that the connect that follows installs its routes. It ends with
--- the tunnel up, which is the reason a restart is allowed here too
--- ([ADR 0034](../../docs/adr/0034-a-protected-connection-keeps-its-repair.md),
--- [ADR 0047](../../docs/adr/0047-a-tunnel-that-carries-nothing.md)).
---
--- `load` puts an agent back under launchd. It ends with the client running,
--- which is the direction protection points in
--- ([ADR 0048](../../docs/adr/0048-an-agent-that-stays-loaded.md)).
backends.PROTECTED_VERBS = {
  connect = true,
  restart = true,
  supersede = true,
  renew = true,
  quit = true,
  standdown = true,
  load = true,
}

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
  local backend = backends.byName[profile.backend]
  if profile.probe then
    local state = parse.probeState(runtime.ifconfig(), profile.probe)
    if state ~= "unknown" then
      -- A probe can only say up or down. Down with a session that has ended is
      -- a different thing from down, and the backend's own log knows which.
      if state == "disconnected" and backend and backend.needsLogin then
        local ok, needs = pcall(backend.needsLogin, profile, runtime)
        if ok and needs then
          return "login"
        end
      end
      return state
    end
  end
  if not backend then
    return "unknown"
  end
  local ok, state = pcall(backend.status, profile, runtime)
  return (ok and parse.STATES[state] and state) or "unknown"
end

--- Does a tunnel that is up carry the address it was given to reach?
---
--- Three answers, and the third is the common one. `nil` means nobody can say:
--- the profile names no address, or its probe does not find a tunnel, and a
--- tunnel that is not there has no routes to be missing. `false` is the finding:
--- the interface is up, the address is on it, and a packet to the far side
--- leaves by something else
--- ([ADR 0047](../../docs/adr/0047-a-tunnel-that-carries-nothing.md)).
--- @param profile table
--- @param runtime table
--- @return boolean|nil carried
--- @return string|nil the interface the address leaves by instead, see `routes.carries`
--- @return number|nil the prefix length of that route
function backends.carries(profile, runtime)
  local probe = type(profile) == "table" and profile.probe or nil
  if type(probe) ~= "table" or type(probe.reach) ~= "string" then
    return nil, nil, nil
  end
  local interfaces = parse.probeInterfaces(runtime.ifconfig(), probe)
  if #interfaces == 0 then
    return nil, nil, nil
  end
  return routes.carries(runtime.routeTable(), probe.reach, interfaces)
end

--- @param profile table
--- @param verb string "connect" or "disconnect"
--- @param runtime table
--- @return boolean ok, string|nil err
function backends.act(profile, verb, runtime, cfg)
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
  -- Closing an application that a protected connection is also using is that
  -- connection's disconnect, whichever profile was clicked to ask for it. A
  -- restart is the exception, because it ends with the client running
  -- ([ADR 0034](../../docs/adr/0034-a-protected-connection-keeps-its-repair.md)).
  local closes = backends.APP_VERBS[verb] and verb ~= "restart"
  if appIsTheTunnel and closes and appIsProtected(profile, cfg) then
    return false, ("%s is protected from being disconnected"):format(profile.name or profile.id or "this connection")
  end
  local allowed = backends.PROTECTED_VERBS[verb] and not (appIsTheTunnel and closes)
  if profile.protected and not allowed then
    return false, ("%s is protected from being disconnected"):format(profile.name or profile.id or "this connection")
  end
  local backend = backends.byName[profile.backend]
  -- `supersede` is a disconnect wearing a different name so the protection
  -- check above can tell them apart. No backend implements it; every backend
  -- already knows how to close its own connection.
  --
  -- `standdown` is the other one: a disconnect a person asked for by name,
  -- through **Disconnect everything**, after a confirmation that listed every
  -- protected connection it would close. It takes the harder path where the
  -- config has one (ADR 0041).
  local action = verb
  if verb == "supersede" or verb == "renew" then
    action = "disconnect"
  elseif verb == "standdown" then
    action = backends.hasForceCommand(profile) and "force" or "disconnect"
  end
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
