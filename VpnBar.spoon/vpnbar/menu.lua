--- The menu model. Everything the user sees is decided here, out of a config
--- and a table of states, and returned as plain data — no closures, no
--- Hammerspoon. The Spoon turns each `action` descriptor into a click handler;
--- the tests read the same descriptors and never open a menu.

local backends = require("vpnbar.backends")
local form = require("vpnbar.form")
local store = require("vpnbar.store")

local menu = {}

local GLYPHS = {
  connected = "●",
  connecting = "◐",
  disconnected = "○",
  unknown = "◌",
}

-- Worst-to-best, for the one glyph in the menu bar: anything connected shows
-- as connected, anything mid-flight shows as busy, and only a menu where
-- nothing is known shows as unknown.
local PRECEDENCE = { connected = 4, connecting = 3, disconnected = 2, unknown = 1 }

local LABELS = {
  connected = "connected",
  connecting = "working…",
  disconnected = "not connected",
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

--- Everything a **Disconnect everything** would actually take down, in the order
--- the config lists it.
---
--- Protected connections are never in it, and that is the whole reason this is a
--- function rather than a loop inside the item: the menu says which connections
--- it is about to close, the adapter closes exactly those, and neither can drift
--- from the other. Hidden connections **are** in it — hiding is about the top
--- level of the menu, not about the tunnel.
--- @param cfg table
--- @param states table map of profile id to state
--- @return table list of { id, name, verb }
function menu.disconnectAll(cfg, states)
  states = states or {}
  local plan = {}
  for _, profile in ipairs(store.list(cfg, true)) do
    if not profile.protected and isUp(states[profile.id]) then
      plan[#plan + 1] = {
        id = profile.id,
        name = profile.name,
        -- The harder path wherever the config gives one. An item that says
        -- everything is the wrong place to make somebody ask twice.
        verb = backends.canForce(profile) and "force" or "disconnect",
      }
    end
  end
  return plan
end

-- The connections that are up and may not be touched. Not a plan, a reason: an
-- item that says "everything" and does nothing has to be able to say why.
local function heldOpen(cfg, states)
  local names = {}
  for _, profile in ipairs(store.list(cfg, true)) do
    if profile.protected and isUp(states[profile.id]) then
      names[#names + 1] = profile.name
    end
  end
  return names
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
    if entry.verb == "force" then
      return true
    end
  end
  return false
end

-- One row for "shut what can be shut". Greyed out rather than hidden when
-- everything that is up is protected, which is the one case where a disabled
-- item earns its place: on a machine whose only tunnel is an always-on one, an
-- item that quietly did nothing would look broken, and one that was simply
-- absent would look missing. So it stays, and it names what is holding it.
local function disconnectAllItem(plan, held)
  if #plan == 0 then
    return {
      title = "Disconnect everything",
      disabled = true,
      tooltip = "Nothing here may be disconnected. Protected from disconnecting: " .. table.concat(held, ", ") .. ".",
    }
  end
  local tooltip = "Takes down: " .. table.concat(namesOf(plan), ", ") .. "."
  if usesForce(plan) then
    tooltip = tooltip .. " Each one the hard way where its config has one."
  end
  if #held > 0 then
    tooltip = tooltip .. " Left alone, protected: " .. table.concat(held, ", ") .. "."
  end
  return { title = "Disconnect everything", tooltip = tooltip, action = { kind = "disconnectAll" } }
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

-- Only for a backend where quitting the app leaves the tunnel alone, which today
-- means GlobalProtect and nothing else. Same shape as forceItem: a separator
-- where it does not apply, so the renderer collapses it away.
local function restartItem(profile)
  if not backends.canRestart(profile) then
    return { separator = true }
  end
  return {
    title = ("Restart %s"):format(profile.app),
    tooltip = ("Quits %s and opens it again, for a panel that has stopped answering. "):format(profile.app)
      .. "The tunnel is held by the agent's own system service rather than by this app, so it is not a disconnect.",
    action = { kind = "restart", id = profile.id },
  }
end

local function toggleAction(state)
  if state == "connected" then
    return "disconnect"
  end
  return "connect"
end

--- Build the whole menu.
--- @param cfg table
--- @param states table map of profile id to state
--- @return table list of items: { title, action?, separator?, disabled?, menu?, tooltip? }
function menu.build(cfg, states)
  states = states or {}
  local items = {}
  local visible = store.list(cfg)

  if #visible == 0 then
    items[#items + 1] = { title = "No connections configured", disabled = true }
  end

  for _, profile in ipairs(visible) do
    local state = states[profile.id] or "unknown"
    if profile.protected and state ~= "disconnected" then
      -- Protected means protected from being brought *down*: an always-on
      -- corporate VPN is a policy, and a menu item that would breach it is
      -- worse than no menu item. Up or on its way up, there is nothing this
      -- row may do, so it only reports.
      items[#items + 1] = {
        title = ("%s  %s"):format(menu.glyph(state), profile.name),
        tooltip = ("%s — %s, protected from disconnecting"):format(profile.name, menu.label(state)),
        disabled = true,
      }
    elseif profile.protected then
      -- Down, though, it may be brought back: that is the direction the
      -- protection points in.
      items[#items + 1] = {
        title = ("%s  %s"):format(menu.glyph(state), profile.name),
        tooltip = ("%s — %s, protected once it is up"):format(profile.name, menu.label(state)),
        action = { kind = "connect", id = profile.id },
      }
    else
      items[#items + 1] = {
        title = ("%s  %s"):format(menu.glyph(state), profile.name),
        tooltip = ("%s — %s"):format(profile.name, menu.label(state)),
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
  local held = heldOpen(cfg, states)
  if #plan > 0 or #held > 0 then
    items[#items + 1] = { separator = true }
    items[#items + 1] = disconnectAllItem(plan, held)
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
        { title = "Move up", disabled = index == 1, action = { kind = "move", id = profile.id, delta = -1 } },
        { title = "Move down", disabled = index == #all, action = { kind = "move", id = profile.id, delta = 1 } },
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
        { separator = true },
        forceItem(profile),
        restartItem(profile),
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
