local menu = require("vpnbar.menu")
local store = require("vpnbar.store")

local function config(...)
  local profiles = {}
  for _, id in ipairs({ ... }) do
    profiles[#profiles + 1] = { id = id, name = id:upper(), backend = "scutil", service = id }
  end
  return assert(store.normalise({ profiles = profiles }))
end

local function find(items, title)
  for _, item in ipairs(items) do
    if item.title == title then
      return item
    end
  end
  return nil
end

describe("menu.title", function()
  it("shows the best state in the set", function()
    assert.equals("●", menu.title({ a = "connected", b = "disconnected" }))
    assert.equals("◐", menu.title({ a = "connecting", b = "disconnected" }))
    assert.equals("○", menu.title({ a = "disconnected", b = "unknown" }))
    assert.equals("◌", menu.title({ a = "unknown" }))
  end)

  it("counts when more than one tunnel is up", function()
    assert.equals("●2", menu.title({ a = "connected", b = "connected" }))
  end)

  it("has something to show for an empty menu", function()
    assert.equals("◌", menu.title({}))
    assert.equals("◌", menu.title(nil))
  end)
end)

describe("menu.build", function()
  it("offers disconnect for what is up and connect for what is not", function()
    local items = menu.build(config("a", "b"), { a = "connected", b = "disconnected" })
    assert.same({ kind = "disconnect", id = "a" }, items[1].action)
    assert.same({ kind = "connect", id = "b" }, items[2].action)
    assert.matches("^●", items[1].title)
  end)

  it("offers connect for a state it could not read", function()
    local items = menu.build(config("a"), {})
    assert.equals("connect", items[1].action.kind)
    assert.matches("state unknown", items[1].tooltip)
  end)

  it("says so when there is nothing configured", function()
    local items = menu.build(store.empty(), {})
    assert.is_true(items[1].disabled)
    assert.matches("No connections", items[1].title)
  end)

  it("leaves hidden profiles out of the top level but manageable below it", function()
    local cfg = assert(store.update(config("a", "b"), "b", { hidden = true }))
    local items = menu.build(cfg, {})
    assert.is_nil(find(items, "○  B"))
    local manage = find(items, "Connections").menu
    assert.is_table(find(manage, "B (hidden)"))
  end)

  it("carries the whole CRUD in the Connections submenu", function()
    local manage = find(menu.build(config("a"), {}), "Connections").menu
    -- No ellipsis: it opens a submenu of backends, not a dialog.
    assert.is_table(find(manage, "Add a connection").menu)
    assert.is_table(find(manage, "Import from scutil…"))
    assert.is_table(find(manage, "Open the config file"))
    local perProfile = find(manage, "A").menu
    local kinds = {}
    for _, item in ipairs(perProfile) do
      if item.action then
        kinds[item.action.kind] = true
      end
    end
    assert.same({
      rename = true,
      edit = true,
      move = true,
      toggleHidden = true,
      toggleMonitor = true,
      toggleAutoconnect = true,
      remove = true,
    }, kinds)
  end)

  it("does not offer a move that would fall off the end", function()
    local manage = find(menu.build(config("a", "b"), {}), "Connections").menu
    local first, last = find(manage, "A").menu, find(manage, "B").menu
    assert.is_true(find(first, "Move up").disabled)
    assert.is_false(find(first, "Move down").disabled or false)
    assert.is_true(find(last, "Move down").disabled)
  end)
end)

describe("menu.build, monitor-only profiles", function()
  -- Some tunnels are policy, not preference: an always-on corporate VPN must
  -- still be visible and must never be offered a disconnect.
  local function monitored()
    return assert(store.update(config("gp"), "gp", { name = "Always-on VPN", monitor = true }))
  end

  local function deep(items, needle)
    for _, item in ipairs(items) do
      if item.title and item.title:find(needle, 1, true) then
        return item
      end
      if item.menu then
        local found = deep(item.menu, needle)
        if found then
          return found
        end
      end
    end
    return nil
  end

  it("shows the state but offers no action", function()
    local item = menu.build(monitored(), { gp = "connected" })[1]
    assert.equals("●  Always-on VPN", item.title)
    assert.is_nil(item.action)
    assert.is_true(item.disabled)
  end)

  it("says why it cannot be clicked", function()
    local item = menu.build(monitored(), { gp = "connected" })[1]
    assert.equals("Always-on VPN — connected, monitored only", item.tooltip)
  end)

  it("reports every state like any other row", function()
    for state, glyph in pairs({ connected = "●", connecting = "◐", disconnected = "○", unknown = "◌" }) do
      local item = menu.build(monitored(), { gp = state })[1]
      assert.equals(glyph .. "  Always-on VPN", item.title)
      assert.is_nil(item.action)
    end
  end)

  it("is still renameable, editable and removable", function()
    local items = menu.build(monitored(), {})
    assert.equals("rename", deep(items, "Rename").action.kind)
    assert.equals("edit", deep(items, "Edit").action.kind)
    assert.equals("remove", deep(items, "Remove").action.kind)
  end)
end)

describe("menu.overall and menu.connectedCount", function()
  it("let the best state speak for the whole menu", function()
    assert.equals("connected", menu.overall({ a = "connected", b = "disconnected" }))
    assert.equals("connecting", menu.overall({ a = "connecting", b = "disconnected" }))
    assert.equals("disconnected", menu.overall({ a = "disconnected", b = "unknown" }))
    assert.equals("unknown", menu.overall({ a = "unknown" }))
  end)

  it("have an answer for an empty menu", function()
    assert.equals("unknown", menu.overall({}))
    assert.equals("unknown", menu.overall(nil))
    assert.equals(0, menu.connectedCount(nil))
  end)

  it("count only what is actually up", function()
    assert.equals(2, menu.connectedCount({ a = "connected", b = "connected", c = "connecting" }))
  end)

  it("agree with the text title, which is the fallback for both", function()
    assert.equals("●2", menu.title({ a = "connected", b = "connected" }))
    assert.equals("◐", menu.title({ a = "connecting" }))
  end)
end)

describe("menu.build, the monitor toggle", function()
  local function config1(monitor)
    local cfg = assert(store.normalise({
      profiles = { { id = "a", name = "A", backend = "scutil", service = "a", monitor = monitor } },
    }))
    return cfg
  end

  local function deep(items, needle)
    for _, item in ipairs(items) do
      if item.title and item.title:find(needle, 1, true) then
        return item
      end
      if item.menu then
        local found = deep(item.menu, needle)
        if found then
          return found
        end
      end
    end
    return nil
  end

  it("offers to lock a controllable connection", function()
    local item = deep(menu.build(config1(false), {}), "Monitor only")
    assert.same({ kind = "toggleMonitor", id = "a" }, item.action)
  end)

  it("offers to unlock a monitored one", function()
    local item = deep(menu.build(config1(true), {}), "Allow connect and disconnect")
    assert.same({ kind = "toggleMonitor", id = "a" }, item.action)
  end)
end)

describe("menu.build, adding a connection", function()
  local function addMenu()
    for _, item in ipairs(menu.build(store.empty(), {})) do
      if item.menu then
        for _, sub in ipairs(item.menu) do
          if sub.title == "Add a connection" then
            return sub.menu
          end
        end
      end
    end
    return nil
  end

  it("offers one entry per backend rather than a dialog with three buttons", function()
    local items = addMenu()
    assert.equals(3, #items)
    local backends = {}
    for _, item in ipairs(items) do
      backends[item.action.backend] = item.action.kind
    end
    assert.same({ scutil = "add", globalprotect = "add", shell = "add" }, backends)
  end)

  it("explains each backend where the choice is made", function()
    for _, item in ipairs(addMenu()) do
      assert.is_string(item.tooltip)
      assert.is_true(#item.tooltip > 10)
    end
  end)
end)

describe("menu.build, force disconnect", function()
  local function shellProfile(force)
    local commands = { connect = "up", disconnect = "down" }
    commands.force = force
    return assert(store.normalise({
      profiles = { { id = "s", name = "Shell VPN", backend = "shell", commands = commands } },
    }))
  end

  local function deep(items, needle)
    for _, item in ipairs(items) do
      if item.title and item.title:find(needle, 1, true) then
        return item
      end
      if item.menu then
        local found = deep(item.menu, needle)
        if found then
          return found
        end
      end
    end
    return nil
  end

  it("offers it when the connection has a harder path", function()
    local item = deep(menu.build(shellProfile("pkill -f vpn"), {}), "Force disconnect")
    assert.same({ kind = "force", id = "s" }, item.action)
  end)

  it("does not offer it when there is nothing stronger to run", function()
    -- A greyed-out entry here would promise something the menu cannot do:
    -- `scutil --nc stop` has no harder form, and neither has the panel click.
    assert.is_nil(deep(menu.build(shellProfile(nil), {}), "Force disconnect"))
    local scutil = assert(store.normalise({
      profiles = { { id = "a", name = "A", backend = "scutil", service = "A" } },
    }))
    assert.is_nil(deep(menu.build(scutil, {}), "Force disconnect"))
  end)

  it("never offers it on a monitored connection", function()
    local cfg = shellProfile("pkill -f vpn")
    cfg.profiles[1].monitor = true
    assert.is_nil(deep(menu.build(cfg, {}), "Force disconnect"))
  end)
end)

describe("menu.build, the autoconnect toggle", function()
  local function cfg(fields)
    local profile = { id = "a", name = "A", backend = "scutil", service = "a" }
    for key, value in pairs(fields or {}) do
      profile[key] = value
    end
    return assert(store.normalise({ profiles = { profile } }))
  end

  local function deep(items, needle)
    for _, item in ipairs(items) do
      if item.title and item.title:find(needle, 1, true) then
        return item
      end
      if item.menu then
        local found = deep(item.menu, needle)
        if found then
          return found
        end
      end
    end
    return nil
  end

  it("offers to switch it on and off", function()
    assert.same({ kind = "toggleAutoconnect", id = "a" }, deep(menu.build(cfg(), {}), "Connect automatically").action)
    local on = cfg({ autoconnect = true })
    assert.is_truthy(deep(menu.build(on, {}), "Do not connect automatically"))
  end)

  it("greys it out on a monitored connection, which is never acted on", function()
    assert.is_true(deep(menu.build(cfg({ monitor = true }), {}), "Connect automatically").disabled)
  end)
end)
