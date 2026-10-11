--- The menu model. Everything the user sees is decided here, out of a config
--- and a table of states, and returned as plain data — no closures, no
--- Hammerspoon. The Spoon turns each `action` descriptor into a click handler;
--- the tests read the same descriptors and never open a menu.

local autoconnect = require("vpnbar.autoconnect")
local backends = require("vpnbar.backends")
local form = require("vpnbar.form")
local store = require("vpnbar.store")

local menu = {}

local GLYPHS = {
  connected = "●",
  connecting = "◐",
  disconnected = "○",
  login = "○",
  unknown = "◌",
}

-- Worst-to-best, for the one glyph in the menu bar: anything connected shows
-- as connected, anything mid-flight shows as busy, and only a menu where
-- nothing is known shows as unknown.
local PRECEDENCE = { connected = 4, connecting = 3, disconnected = 2, login = 2, unknown = 1 }

local LABELS = {
  connected = "connected",
  connecting = "working…",
  disconnected = "not connected",
  -- Down, and the row can say why: the session has ended, and the next connect
  -- opens a login window rather than a tunnel.
  login = "needs your login",
  unknown = "state unknown",
}

--- @param state string|nil
--- @return string
function menu.glyph(state)
  return GLYPHS[state or "unknown"] or GLYPHS.unknown
end

--- @param state string|nil
--- @return string
function menu.label(state)
  return LABELS[state or "unknown"] or LABELS.unknown
end

--- The one state that speaks for the whole menu: anything connected beats
--- anything in flight, which beats anything known to be down.
--- @param states table map of profile id to state
--- @return string
function menu.overall(states)
  local best = "unknown"
  for _, state in pairs(states or {}) do
    if (PRECEDENCE[state] or 0) > (PRECEDENCE[best] or 0) then
      best = state
    end
  end
  return best
end

--- What the menu-bar mark shows, which is not quite the same question as
--- `overall`.
---
--- Work in flight wins over every settled state. Two reasons: a state table
--- cannot say "a read is running", and `PRECEDENCE` deliberately lets anything
--- connected outrank anything mid-flight — so on a machine with an always-on
--- tunnel the busy mark existed and was never once reachable. Starting up,
--- waking, and a click that takes seconds to land all looked exactly like
--- nothing happening.
---
--- @param states table map of profile id to state
--- @param busy boolean|nil whether the adapter has a job running
--- @return string
function menu.indicator(states, busy)
  if busy then
    return "connecting"
  end
  for _, state in pairs(states or {}) do
    if state == "connecting" then
      return "connecting"
    end
  end
  return menu.overall(states)
end

--- How many tunnels are up. Shown beside the icon once it is more than one,
--- because two at once is worth noticing and one is the normal case.
--- @param states table map of profile id to state
--- @return number
function menu.connectedCount(states)
  local connected = 0
  for _, state in pairs(states or {}) do
    if state == "connected" then
      connected = connected + 1
    end
  end
  return connected
end

--- The text form of the title. The menu bar draws the icon instead, but this
--- is what a build without a canvas falls back to, and it is what the tests
--- read.
--- @param states table map of profile id to state
--- @param busy boolean|nil whether the adapter has a job running
--- @return string
function menu.title(states, busy)
  local indicator = menu.indicator(states, busy)
  local connected = menu.connectedCount(states)
  if indicator == "connected" and connected > 1 then
    return GLYPHS.connected .. tostring(connected)
  end
  return menu.glyph(indicator)
end

-- Up, or on its way up. What "everything" is counted from: a connection that is
-- down needs nothing done to it, and one whose state could not be read is one
-- nobody knows anything about — sending a disconnect at that is how an
-- unconfigured probe turns into a panel opening by itself.
local function isUp(state)
  return state == "connected" or state == "connecting"
end

-- Down, whether or not a person is needed to bring it back. What a protected
-- row may offer turns on this and not on the one word "disconnected".
local function isDown(state)
  return state == "disconnected" or state == "login"
end

--- Everything a **Disconnect everything** would actually take down, in the order
--- the config lists it.
---
--- Everything means everything, protected connections included. It used to
--- leave those alone, and on a machine where both VPNs are protected the row was
--- greyed out every time it was wanted, which is whenever somebody needs the
--- local network: a printer, a NAS, a router's own page
--- ([ADR 0041](../../docs/adr/0041-everything-means-everything.md)). Protection
--- is against a stray click on a row; this is a confirmed request naming every
--- connection it will close, and the protected ones are named as such. Each
--- entry says whether it is protected, so the confirmation can say it out loud.
---
--- It is a function rather than a loop inside the item for the reason it always
--- was: the menu says what it is about to close, the adapter closes exactly
--- those, and neither can drift from the other. Hidden connections **are** in
--- it, since hiding is about the top level of the menu, not about the tunnel.
--- @param cfg table
--- @param states table map of profile id to state
--- @return table list of { id, name, verb, protected }
function menu.disconnectAll(cfg, states)
  states = states or {}
  local plan = {}
  for _, profile in ipairs(store.list(cfg, true)) do
    if isUp(states[profile.id]) then
      plan[#plan + 1] = {
        id = profile.id,
        name = profile.name,
        -- `standdown` is a disconnect a person asked for by name, and the one
        -- the backend lets through on a protected connection. It takes the
        -- harder path wherever the config gives one: an item that says
        -- everything is the wrong place to make somebody ask twice.
        verb = "standdown",
        force = backends.hasForceCommand(profile),
        protected = profile.protected == true,
      }
    end
  end
  return plan
end

local function namesOf(plan)
  local names = {}
  for _, entry in ipairs(plan) do
    names[#names + 1] = entry.name
  end
  return names
end

local function usesForce(plan)
  for _, entry in ipairs(plan) do
    if entry.force then
      return true
    end
  end
  return false
end

local function protectedIn(plan)
  local names = {}
  for _, entry in ipairs(plan) do
    if entry.protected then
      names[#names + 1] = entry.name
    end
  end
  return names
end

-- One row for "turn it all off". Shown once something is up, never greyed out:
-- the protected connections are in the plan, and the tooltip says so before
-- the confirmation does.
local function disconnectAllItem(plan)
  local tooltip = "Takes down: " .. table.concat(namesOf(plan), ", ") .. "."
  local protected = protectedIn(plan)
  if #protected > 0 then
    tooltip = tooltip .. " Protected, and taken down too: " .. table.concat(protected, ", ") .. "."
  end
  if usesForce(plan) then
    tooltip = tooltip .. " Each one the hard way where its config has one."
  end
  tooltip = tooltip .. " Autoconnect then stays off until you turn the VPNs back on."
  return { title = "Disconnect everything", tooltip = tooltip, action = { kind = "disconnectAll" } }
end

-- While autoconnect is paused, the first row says so and is the way back.
-- Nothing else in the menu brings the VPNs back on its own in this state, so
-- the way back has to be the thing nobody can miss (ADR 0041).
--
-- The title comes from the states rather than from the pause, because the
-- pause is a decision and the states are what happened: a disconnect that
-- failed, or a connection brought up by hand while paused, leaves something up
-- that a title saying "off" would hide.
local function pausedItem(plan)
  local title = "VPNs are off. Turn them back on"
  if #plan > 0 then
    title = ("Autoconnect is paused, %s still up. Resume"):format(table.concat(namesOf(plan), ", "))
  end
  return {
    title = title,
    tooltip = "Everything was disconnected on purpose, so autoconnect is leaving it alone."
      .. " This hands every connection back to autoconnect, in the order of the menu.",
    action = { kind = "resumeAll" },
  }
end

-- The backend chooser is a submenu and not a dialog: hs.dialog.blockAlert
-- takes two buttons and reads a third argument as a *style*, so the version of
-- this that offered three of them was quietly dropping one. A submenu also
-- puts each backend's one-line explanation where it is read, next to the thing
-- it explains.
local function addMenu()
  local items = {}
  for _, backend in ipairs(form.BACKENDS) do
    items[#items + 1] = {
      title = backend.label,
      tooltip = backend.hint,
      action = { kind = "add", backend = backend.value },
    }
  end
  return items
end

-- Only where `backends.canForce` says there is something stronger to run.
-- Everywhere else this returns a separator, which the renderer collapses --
-- a greyed-out "Force disconnect" on a connection that has no such thing
-- would be a promise the menu cannot keep.
local function forceItem(profile)
  if not backends.canForce(profile) then
    return { separator = true }
  end
  return { title = "Force disconnect", action = { kind = "force", id = profile.id } }
end

--- Every application this menu is allowed to close, one entry per application
--- rather than one per connection: two connections through the same client are
--- one thing to quit.
---
--- Protected connections whose client *is* the tunnel are not in it, because
--- closing those is a disconnect and no button in this menu performs one
--- ([ADR 0028](../../docs/adr/0028-quit-and-restart-are-per-application.md)).
--- @param cfg table
--- @return table list of { id, name, app }
function menu.quitApps(cfg)
  local apps, seen = {}, {}
  for _, profile in ipairs(store.list(cfg, true)) do
    if backends.canQuit(profile, cfg) and not seen[profile.app] then
      seen[profile.app] = true
      apps[#apps + 1] = { id = profile.id, name = profile.name, app = profile.app }
    end
  end
  return apps
end

-- Whether closing the app leaves the tunnel alone decides what these rows are
-- allowed to promise, and `backends.canQuit` has already refused the case where
-- it would not. Same shape as forceItem: a separator where it does not apply,
-- so the renderer collapses it away.
local function quitItem(profile, cfg)
  if not backends.canQuit(profile, cfg) then
    return { separator = true }
  end
  return {
    title = ("Quit %s"):format(profile.app),
    tooltip = ("Closes %s and leaves it closed."):format(profile.app)
      .. " Autoconnect leaves its connections alone afterwards, until you connect one again.",
    action = { kind = "quitApp", id = profile.id },
  }
end

local function restartItem(profile, cfg)
  if not backends.canRestart(profile, cfg) then
    return { separator = true }
  end
  return {
    title = ("Restart %s"):format(profile.app),
    tooltip = ("Closes %s and opens it again, for a client that has stopped answering."):format(profile.app),
    action = { kind = "restart", id = profile.id },
  }
end

local function quitAllItem(apps)
  local names = {}
  for _, entry in ipairs(apps) do
    names[#names + 1] = entry.app
  end
  -- One application is not "them". On a machine where only one client may be
  -- closed, which is the common case once something is protected, the plural
  -- reads as a promise about connections nobody is going to touch.
  local closed = #apps == 1 and " and leaves it closed." or " and leaves them closed."
  return {
    title = "Quit every VPN app",
    tooltip = "Closes "
      .. table.concat(names, " and ")
      .. closed
      .. " Autoconnect leaves their connections alone afterwards, until you connect one again.",
    action = { kind = "quitAllApps" },
  }
end

--- Has somebody closed the client behind this connection?
---
--- Keyed by application, because that is what was quit: one client, every
--- connection through it ([ADR 0031](../../docs/adr/0031-autoconnect-does-not-undo-a-quit.md)).
--- @param profile table
--- @param quitByHand table|nil { [app] = true }
--- @return boolean
local function isStandingDown(profile, quitByHand)
  return (profile.app ~= nil and quitByHand ~= nil and quitByHand[profile.app] == true)
end

-- Why nothing is happening. A connection autoconnect has been told to leave
-- alone looks exactly like one that is failing, and the difference is the whole
-- point: a row that did not say so would be a tunnel that stays down for a
-- reason nobody can see from the menu.
local function standingDownNote(profile, quitByHand)
  if not isStandingDown(profile, quitByHand) then
    return ""
  end
  return (" Autoconnect is leaving it alone since %s was quit; connecting it hands it back."):format(profile.app)
end

-- The way back, for somebody who wants autoconnect again without connecting
-- anything this second. A separator everywhere else, which the renderer
-- collapses: an always-present row that usually does nothing is a row that
-- teaches nobody anything.
local function resumeItem(profile, quitByHand)
  if not isStandingDown(profile, quitByHand) then
    return { separator = true }
  end
  return {
    title = ("Resume autoconnect for %s"):format(profile.app),
    tooltip = ("Autoconnect has left every connection through %s alone since it was quit."):format(profile.app)
      .. " This hands them back, so they may come up on their own again.",
    action = { kind = "resume", id = profile.id },
  }
end

-- The repair for a client whose own service has stopped answering it. Offered
-- on a protected connection too, because it ends with the service running and
-- it is the only way back short of a reboot
-- ([ADR 0039](../../docs/adr/0039-putting-a-service-back-on-its-feet.md)).
local function repairItem(profile)
  if not backends.canRepair(profile) then
    return { separator = true }
  end
  local admin = backends.serviceNeedsAdmin(backends.serviceOf(profile))
  return {
    title = ("Restart the service behind %s"):format(profile.app or profile.name),
    tooltip = "For a client that has stopped answering: the agent asks and its own service never hears."
      .. " The connection goes down and comes back."
      .. (admin and " It asks for an administrator." or ""),
    action = { kind = "repair", id = profile.id },
  }
end

local function toggleAction(state)
  if state == "connected" then
    return "disconnect"
  end
  return "connect"
end

--- The connections a **Switch to** row may offer: everything visible except the
--- one that ranks first right now, in rank order. Hidden connections are left
--- out for the same reason they are out of the top level.
--- @param cfg table
--- @param preferred string|nil the id somebody switched to, if any
--- @return table list of profiles
function menu.switchTargets(cfg, preferred)
  local ranked = autoconnect.ranked(cfg, preferred)
  local current = ranked[1]
  local targets = {}
  for _, profile in ipairs(ranked) do
    if current and profile.id ~= current.id and not profile.hidden then
      targets[#targets + 1] = profile
    end
  end
  return targets
end

--- One row that changes which connection stays up, without touching the order.
---
--- The connection you chose is crawling and you want to be on the other one
--- *now*, and to stay there. A plain Connect does not give you that while
--- *Only one connection at a time* takes the second tunnel straight down
--- again, and Move up would change the config for a problem that is about this
--- afternoon. The switch makes the other one preferred for this session and
--- connects it
--- ([ADR 0030](../../docs/adr/0030-a-switch-is-a-preference-not-an-order.md)).
local function switchRow(profile, cfg, preferred, exclusive)
  local natural = store.list(cfg, true)[1]
  local back = preferred ~= nil and natural ~= nil and profile.id == natural.id
  local tooltip = ("Connects %s now and keeps it up instead of the current one, until vpnbar restarts."):format(
    profile.name
  ) .. " The order in the menu stays as it is."
  if not exclusive then
    tooltip = tooltip .. " Only one connection at a time is off, so the current one stays up too."
  end
  return {
    title = (back and "Switch back to %s" or "Switch to %s"):format(profile.name),
    tooltip = tooltip,
    action = { kind = "switch", id = profile.id },
  }
end

local function switchItem(cfg, preferred)
  local targets = menu.switchTargets(cfg, preferred)
  if #targets == 0 then
    return nil
  end
  local exclusive = store.settings(cfg).exclusive
  if #targets == 1 then
    return switchRow(targets[1], cfg, preferred, exclusive)
  end
  local rows = {}
  for _, profile in ipairs(targets) do
    rows[#rows + 1] = switchRow(profile, cfg, preferred, exclusive)
  end
  return { title = "Switch to", menu = rows }
end

--- Build the whole menu.
--- @param cfg table
--- @param states table map of profile id to state
--- @param preferred string|nil the id somebody switched to for this session
--- @param quitByHand table|nil the applications somebody closed, `{ [app] = true }`
--- @param paused boolean|nil everything was disconnected on purpose (ADR 0041)
--- @return table list of items: { title, action?, separator?, disabled?, menu?, tooltip? }
function menu.build(cfg, states, preferred, quitByHand, paused)
  states = states or {}
  local items = {}
  local visible = store.list(cfg)

  -- Before everything, while everything is off by request: it is the only way
  -- back, so it is the one row that cannot be missed.
  if paused then
    items[#items + 1] = pausedItem(menu.disconnectAll(cfg, states))
    items[#items + 1] = { separator = true }
  end

  -- First, because it is the row for the moment this menu is opened in anger:
  -- the connection you chose is crawling and you want the other one.
  local switch = switchItem(cfg, preferred)
  if switch then
    items[#items + 1] = switch
    items[#items + 1] = { separator = true }
  end

  if #visible == 0 then
    items[#items + 1] = { title = "No connections configured", disabled = true }
  end

  for _, profile in ipairs(visible) do
    local state = states[profile.id] or "unknown"
    -- Added to every row rather than only to the ones that are down. A tunnel
    -- that is still up with its client closed is the case worth saying it in:
    -- a quit made outside this menu leaves the connection up for as long as the
    -- client's own service holds it, and the moment it drops nothing is going
    -- to bring it back.
    local note = standingDownNote(profile, quitByHand)
    if profile.protected and not isDown(state) then
      -- Protected means protected from being brought *down*: an always-on
      -- corporate VPN is a policy, and a menu item that would breach it is
      -- worse than no menu item. Up or on its way up, there is nothing this
      -- row may do, so it only reports.
      items[#items + 1] = {
        title = ("%s  %s"):format(menu.glyph(state), profile.name),
        tooltip = ("%s — %s, protected from disconnecting"):format(profile.name, menu.label(state)) .. note,
        disabled = true,
      }
    elseif profile.protected then
      -- Down, though, it may be brought back: that is the direction the
      -- protection points in.
      items[#items + 1] = {
        title = ("%s  %s"):format(menu.glyph(state), profile.name),
        tooltip = ("%s — %s, protected once it is up"):format(profile.name, menu.label(state)) .. note,
        action = { kind = "connect", id = profile.id },
      }
    else
      items[#items + 1] = {
        title = ("%s  %s"):format(menu.glyph(state), profile.name),
        tooltip = ("%s — %s"):format(profile.name, menu.label(state)) .. note,
        -- A connection whose state is unknown is still clickable: refusing to
        -- act because the probe could not answer would make an unconfigured
        -- probe look like a broken connection.
        action = { kind = toggleAction(state), id = profile.id },
      }
    end
  end

  -- Only once there is something up to talk about. On an idle machine every
  -- connection is already down, and a row offering to close nothing is noise.
  local plan = menu.disconnectAll(cfg, states)
  local apps = menu.quitApps(cfg)
  if #plan > 0 or #apps > 0 then
    items[#items + 1] = { separator = true }
  end
  if #plan > 0 then
    items[#items + 1] = disconnectAllItem(plan)
  end
  -- Closing the clients is a different thing from taking the tunnels down, and
  -- it is the repair for a client that has stopped answering, so it sits beside
  -- the row that disconnects rather than inside a connection's submenu.
  if #apps > 0 then
    items[#items + 1] = quitAllItem(apps)
  end

  items[#items + 1] = { separator = true }

  local manage = {
    { title = "Add a connection", menu = addMenu() },
    { title = "Import from scutil…", action = { kind = "import" } },
  }
  local all = store.list(cfg, true)
  if #all > 0 then
    manage[#manage + 1] = { separator = true }
  end
  for index, profile in ipairs(all) do
    manage[#manage + 1] = {
      title = profile.name .. (profile.hidden and " (hidden)" or ""),
      menu = {
        { title = "Rename…", action = { kind = "rename", id = profile.id } },
        { title = "Edit…", action = { kind = "edit", id = profile.id } },
        { separator = true },
        -- The order is not only cosmetic and used to look it. It is the
        -- priority: autoconnect asks the highest one first, and with one at a
        -- time switched on the highest is the one that stays up. Saying so here
        -- is the difference between a list and a setting.
        {
          title = ("Move up (%d of %d)"):format(index, #all),
          tooltip = "Higher means tried first, and kept when only one may be up at a time.",
          disabled = index == 1,
          action = { kind = "move", id = profile.id, delta = -1 },
        },
        {
          title = "Move down",
          tooltip = "Lower means tried later, and taken down first when only one may be up at a time.",
          disabled = index == #all,
          action = { kind = "move", id = profile.id, delta = 1 },
        },
        {
          title = profile.hidden and "Show in the menu" or "Hide from the menu",
          action = { kind = "toggleHidden", id = profile.id },
        },
        {
          title = profile.protected and "Allow disconnecting" or "Protect from disconnecting",
          action = { kind = "toggleProtected", id = profile.id },
        },
        {
          title = profile.autoconnect and "Do not connect automatically" or "Connect automatically",
          -- Protected and autoconnect belong together: a tunnel that must stay
          -- up is exactly the one worth bringing up on its own.
          disabled = false,
          action = { kind = "toggleAutoconnect", id = profile.id },
        },
        resumeItem(profile, quitByHand),
        { separator = true },
        forceItem(profile),
        quitItem(profile, cfg),
        restartItem(profile, cfg),
        repairItem(profile),
        { title = "Remove…", action = { kind = "remove", id = profile.id } },
      },
    }
  end
  manage[#manage + 1] = { separator = true }
  local settings = store.settings(cfg)
  manage[#manage + 1] = {
    title = "Settings",
    menu = {
      {
        title = "Only one connection at a time",
        checked = settings.exclusive,
        tooltip = "Autoconnect never starts a second tunnel, and takes down extras it started. "
          .. "A connection you opened yourself is reported, never closed.",
        action = { kind = "toggleSetting", setting = "exclusive" },
      },
      {
        title = "Use fallbacks",
        checked = settings.fallback,
        tooltip = "Off, autoconnect keeps asking for the connection you chose instead of trying its fallback.",
        action = { kind = "toggleSetting", setting = "fallback" },
      },
    },
  }
  manage[#manage + 1] = { separator = true }
  manage[#manage + 1] = { title = "Open the config file", action = { kind = "reveal" } }
  manage[#manage + 1] = { title = "Reload from disk", action = { kind = "reload" } }

  items[#items + 1] = { title = "Connections", menu = manage }
  items[#items + 1] = { title = "Refresh now", action = { kind = "refresh" } }
  items[#items + 1] = { separator = true }
  -- Last, and its own item rather than something under Connections: a menu-bar
  -- app with no way out of its own menu is one you have to know about
  -- Hammerspoon to get rid of.
  items[#items + 1] = {
    title = "Quit vpnbar",
    tooltip = "Takes the icon out of the menu bar and stops watching. "
      .. "Nothing is disconnected. Reload Hammerspoon to bring it back.",
    action = { kind = "quit" },
  }

  return items
end

return menu
