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
    assert.is_table(find(manage, "Add a connection…"))
    assert.is_table(find(manage, "Import from scutil…"))
    assert.is_table(find(manage, "Open the config file"))
    local perProfile = find(manage, "A").menu
    local kinds = {}
    for _, item in ipairs(perProfile) do
      if item.action then
        kinds[item.action.kind] = true
      end
    end
    assert.same({ rename = true, edit = true, move = true, toggleHidden = true, remove = true }, kinds)
  end)

  it("does not offer a move that would fall off the end", function()
    local manage = find(menu.build(config("a", "b"), {}), "Connections").menu
    local first, last = find(manage, "A").menu, find(manage, "B").menu
    assert.is_true(find(first, "Move up").disabled)
    assert.is_false(find(first, "Move down").disabled or false)
    assert.is_true(find(last, "Move down").disabled)
  end)
end)
