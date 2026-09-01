--- The menu model. Everything the user sees is decided here, out of a config
--- and a table of states, and returned as plain data — no closures, no
--- Hammerspoon. The Spoon turns each `action` descriptor into a click handler;
--- the tests read the same descriptors and never open a menu.

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

--- The menu-bar title: one glyph for the whole set, plus a count when more
--- than one connection is up, because two tunnels at once is worth noticing.
--- @param states table map of profile id to state
--- @return string
function menu.title(states)
  local best, connected = "unknown", 0
  for _, state in pairs(states or {}) do
    if (PRECEDENCE[state] or 0) > (PRECEDENCE[best] or 0) then
      best = state
    end
    if state == "connected" then
      connected = connected + 1
    end
  end
  if connected > 1 then
    return GLYPHS.connected .. tostring(connected)
  end
  return menu.glyph(best)
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
    if profile.monitor then
      -- Some tunnels are not this menu's to change: an always-on corporate VPN
      -- is a policy, and a menu item that would breach it is worse than no
      -- menu item. The row still reports, which is the half that is wanted.
      items[#items + 1] = {
        title = ("%s  %s"):format(menu.glyph(state), profile.name),
        tooltip = ("%s — %s, monitored only"):format(profile.name, menu.label(state)),
        disabled = true,
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

  items[#items + 1] = { separator = true }

  local manage = {
    { title = "Add a connection…", action = { kind = "add" } },
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
        { separator = true },
        { title = "Remove…", action = { kind = "remove", id = profile.id } },
      },
    }
  end
  manage[#manage + 1] = { separator = true }
  manage[#manage + 1] = { title = "Open the config file", action = { kind = "reveal" } }
  manage[#manage + 1] = { title = "Reload from disk", action = { kind = "reload" } }

  items[#items + 1] = { title = "Connections", menu = manage }
  items[#items + 1] = { title = "Refresh now", action = { kind = "refresh" } }

  return items
end

return menu
