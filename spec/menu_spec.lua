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

  it("says it is working while a job is running, whatever the states say", function()
    assert.equals("◐", menu.title({ a = "connected", b = "connected" }, true))
    assert.equals("◐", menu.title({}, true))
  end)
end)

describe("menu.indicator", function()
  it("is the overall state when nothing is running", function()
    assert.equals("connected", menu.indicator({ a = "connected", b = "disconnected" }, false))
    assert.equals("disconnected", menu.indicator({ a = "disconnected" }))
    assert.equals("unknown", menu.indicator({}))
  end)

  it("shows work in flight over anything already settled", function()
    -- The whole point: on a machine with an always-on tunnel, `overall` is
    -- `connected` for ever, so nothing the adapter does could ever be seen.
    assert.equals("connecting", menu.indicator({ a = "connected" }, true))
  end)

  it("counts a connection reported as connecting as work in flight", function()
    -- Same blind spot from the other side: PRECEDENCE lets connected outrank
    -- connecting, so a tunnel coming up beside one that is up was invisible.
    assert.equals("connecting", menu.indicator({ a = "connected", b = "connecting" }))
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

  it("offers a way out of itself, last, and says what that costs", function()
    for _, cfg in ipairs({ config("a"), store.empty() }) do
      local items = menu.build(cfg, {})
      local quit = items[#items]
      assert.same({ kind = "quit" }, quit.action)
      assert.matches("Quit", quit.title)
      -- The way back is a Hammerspoon reload, which a menu that has just
      -- vanished cannot tell anybody. So the item says it while it is still there.
      assert.matches("Reload Hammerspoon", quit.tooltip)
      assert.matches("Nothing is disconnected", quit.tooltip)
    end
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
      toggleProtected = true,
      toggleAutoconnect = true,
      remove = true,
    }, kinds)
  end)

  it("does not offer a move that would fall off the end", function()
    -- "Move up" now carries the position, because the order is the priority.
    local function moveRow(items, word)
      for _, item in ipairs(items) do
        if tostring(item.title):find(word, 1, true) then
          return item
        end
      end
    end
    local manage = find(menu.build(config("a", "b"), {}), "Connections").menu
    local first, last = find(manage, "A").menu, find(manage, "B").menu
    assert.is_true(moveRow(first, "Move up").disabled)
    assert.is_false(moveRow(first, "Move down").disabled or false)
    assert.is_true(moveRow(last, "Move down").disabled)
  end)
end)

describe("menu.build, protected profiles", function()
  -- Some tunnels are policy, not preference: an always-on corporate VPN must
  -- still be visible and must never be offered a disconnect.
  local function protected()
    return assert(store.update(config("gp"), "gp", { name = "Always-on VPN", protected = true }))
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

  it("offers nothing while it is up", function()
    local item = menu.build(protected(), { gp = "connected" })[1]
    assert.equals("●  Always-on VPN", item.title)
    assert.is_nil(item.action)
    assert.is_true(item.disabled)
    assert.equals("Always-on VPN — connected, protected from disconnecting", item.tooltip)
  end)

  it("offers nothing while it is on its way up either", function()
    local item = menu.build(protected(), { gp = "connecting" })[1]
    assert.is_nil(item.action)
    assert.is_true(item.disabled)
  end)

  it("offers to bring it back when it is down", function()
    -- Protection points one way. A protected tunnel that is down is exactly
    -- the one you want a single click to fix.
    local item = menu.build(protected(), { gp = "disconnected" })[1]
    assert.same({ kind = "connect", id = "gp" }, item.action)
    assert.matches("protected once it is up", item.tooltip)
  end)

  it("never offers to disconnect it, in any state", function()
    for _, state in ipairs({ "connected", "connecting", "disconnected", "unknown" }) do
      local item = menu.build(protected(), { gp = state })[1]
      assert.not_equals("disconnect", item.action and item.action.kind)
    end
  end)

  it("reports every state like any other row", function()
    for state, glyph in pairs({ connected = "●", connecting = "◐", disconnected = "○", unknown = "◌" }) do
      local item = menu.build(protected(), { gp = state })[1]
      assert.equals(glyph .. "  Always-on VPN", item.title)
    end
  end)

  it("is still renameable, editable and removable", function()
    local items = menu.build(protected(), {})
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

describe("menu.build, the protection toggle", function()
  local function config1(protectedFlag)
    local cfg = assert(store.normalise({
      profiles = { { id = "a", name = "A", backend = "scutil", service = "a", protected = protectedFlag } },
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

  it("offers to protect a connection that is not", function()
    local item = deep(menu.build(config1(false), {}), "Protect from disconnecting")
    assert.same({ kind = "toggleProtected", id = "a" }, item.action)
  end)

  it("offers to unprotect one that is", function()
    local item = deep(menu.build(config1(true), {}), "Allow disconnecting")
    assert.same({ kind = "toggleProtected", id = "a" }, item.action)
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
    -- The dialog it replaced took two buttons and silently read the third as a
    -- style, so the list could never grow. A submenu has no such limit.
    local items = addMenu()
    assert.equals(4, #items)
    local backends = {}
    for _, item in ipairs(items) do
      backends[item.action.backend] = item.action.kind
    end
    assert.same({ scutil = "add", globalprotect = "add", awsvpn = "add", shell = "add" }, backends)
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

  it("never offers it on a protected connection", function()
    local cfg = shellProfile("pkill -f vpn")
    cfg.profiles[1].protected = true
    assert.is_nil(deep(menu.build(cfg, {}), "Force disconnect"))
  end)
end)

describe("menu.disconnectAll", function()
  -- One of each kind of answer: protected, forceable, plain, and hidden.
  local function mixed()
    return assert(store.normalise({
      profiles = {
        { id = "gp", name = "Always-on VPN", backend = "globalprotect", protected = true },
        {
          id = "aws",
          name = "AWS VPN",
          backend = "shell",
          commands = { connect = "up", disconnect = "down", force = "kill" },
        },
        { id = "work", name = "Work VPN", backend = "scutil", service = "Work VPN" },
        { id = "old", name = "Old VPN", backend = "scutil", service = "Old VPN", hidden = true },
      },
    }))
  end

  local function plan(states)
    local out = {}
    for _, entry in ipairs(menu.disconnectAll(mixed(), states)) do
      out[#out + 1] = entry.id .. ":" .. entry.verb
    end
    return out
  end

  it("takes everything that is up, in the order the config lists it", function()
    -- The hidden one is in it: hiding is about the top level of the menu, and a
    -- tunnel you cannot see is not a tunnel that is allowed to survive
    -- "everything".
    assert.same(
      { "aws:force", "work:disconnect", "old:disconnect" },
      plan({ gp = "connected", aws = "connected", work = "connected", old = "connected" })
    )
  end)

  it("uses the harder path only where the config gives one", function()
    assert.same({ "aws:force" }, plan({ aws = "connected" }))
    assert.same({ "work:disconnect" }, plan({ work = "connected" }))
  end)

  it("never includes a protected connection", function()
    assert.same({}, plan({ gp = "connected" }))
    assert.same({}, plan({ gp = "connecting" }))
  end)

  it("counts a connection on its way up, which is a thing you want stopped", function()
    assert.same({ "work:disconnect" }, plan({ work = "connecting" }))
  end)

  it("leaves alone what is down, and what nobody could read", function()
    -- A disconnect aimed at an unreadable connection is how a profile with no
    -- probe turns a menu click into a panel opening by itself.
    assert.same({}, plan({ work = "disconnected", aws = "unknown" }))
    assert.same({}, plan({}))
    assert.same({}, plan(nil))
  end)

  it("carries the name, so the confirmation can list what it is about to close", function()
    local entries = menu.disconnectAll(mixed(), { work = "connected" })
    assert.equals("Work VPN", entries[1].name)
  end)
end)

describe("menu.build, disconnect everything", function()
  local function cfg(profiles)
    return assert(store.normalise({ profiles = profiles }))
  end

  local plain = { id = "a", name = "A", backend = "scutil", service = "a" }
  local locked = { id = "gp", name = "Always-on VPN", backend = "globalprotect", protected = true }

  it("offers it above Connections once something is up", function()
    local items = menu.build(cfg({ plain }), { a = "connected" })
    local item = find(items, "Disconnect everything")
    assert.same({ kind = "disconnectAll" }, item.action)
    assert.matches("Takes down: A", item.tooltip)
    local at, connections = 0, 0
    for index, entry in ipairs(items) do
      at = entry.title == "Disconnect everything" and index or at
      connections = entry.title == "Connections" and index or connections
    end
    assert.is_true(at < connections)
  end)

  it("is not there at all when everything is already down", function()
    assert.is_nil(find(menu.build(cfg({ plain }), { a = "disconnected" }), "Disconnect everything"))
    assert.is_nil(find(menu.build(cfg({ plain }), {}), "Disconnect everything"))
  end)

  it("stays, greyed out, and names what is holding it when the only tunnel up is protected", function()
    -- The case this was written for. Hiding the row would read as a missing
    -- feature and a row that quietly did nothing would read as a broken one, so
    -- it says which connection it is not allowed to close.
    local item = find(menu.build(cfg({ locked }), { gp = "connected" }), "Disconnect everything")
    assert.is_true(item.disabled)
    assert.is_nil(item.action)
    assert.matches("Nothing here may be disconnected", item.tooltip)
    assert.matches("Always%-on VPN", item.tooltip)
  end)

  it("says both halves when some may go and some may not", function()
    local item =
      find(menu.build(cfg({ plain, locked }), { a = "connected", gp = "connected" }), "Disconnect everything")
    assert.same({ kind = "disconnectAll" }, item.action)
    assert.matches("Takes down: A", item.tooltip)
    assert.matches("Left alone, protected: Always%-on VPN", item.tooltip)
  end)

  it("says when it will use a force, because that is more than the row above does", function()
    local forceable = {
      id = "s",
      name = "Shell VPN",
      backend = "shell",
      commands = { connect = "up", disconnect = "down", force = "kill" },
    }
    local item = find(menu.build(cfg({ forceable }), { s = "connected" }), "Disconnect everything")
    assert.matches("the hard way", item.tooltip)
    assert.is_nil(
      find(menu.build(cfg({ plain }), { a = "connected" }), "Disconnect everything").tooltip:find("hard way")
    )
  end)
end)

describe("menu.build, restarting the agent", function()
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

  local function only(profile)
    return assert(store.normalise({ profiles = { profile } }))
  end

  it("is offered for GlobalProtect, whose tunnel does not live in the app", function()
    local cfg = only({ id = "gp", name = "Always-on VPN", backend = "globalprotect", app = "GlobalProtect" })
    local item = deep(menu.build(cfg, {}), "Restart GlobalProtect")
    assert.same({ kind = "restart", id = "gp" }, item.action)
    assert.matches("stopped answering", item.tooltip)
  end)

  it("offers a plain quit beside it, which is the half that does not reopen", function()
    local cfg = only({ id = "gp", name = "Always-on VPN", backend = "globalprotect", app = "GlobalProtect" })
    local item = deep(menu.build(cfg, {}), "Quit GlobalProtect")
    assert.same({ kind = "quitApp", id = "gp" }, item.action)
    assert.matches("leaves it closed", item.tooltip)
  end)

  it("is offered on a protected connection, which is the one that needs it", function()
    -- Protection is about the tunnel. A panel that has stopped answering is the
    -- app, and the connection that may not be disconnected is exactly the one
    -- whose only repair this is.
    local cfg = only({ id = "gp", name = "Always-on VPN", backend = "globalprotect", protected = true })
    assert.is_table(deep(menu.build(cfg, { gp = "connected" }), "Restart GlobalProtect"))
  end)

  -- The AWS client is an application like any other and may be closed, but it
  -- *is* the tunnel's parent process, so closing it is a disconnect — which is
  -- the one thing no button offers on a protected connection.
  it("is offered for the AWS client while nothing is protected", function()
    local aws = only({ id = "aws", name = "AWS VPN", backend = "awsvpn", app = "AWS VPN Client", row = "work" })
    assert.is_table(deep(menu.build(aws, {}), "Restart AWS VPN Client"))
    assert.is_table(deep(menu.build(aws, {}), "Quit AWS VPN Client"))
  end)

  it("is withheld from a protected client that is its own tunnel", function()
    local aws = only({
      id = "aws",
      name = "AWS VPN",
      backend = "awsvpn",
      app = "AWS VPN Client",
      row = "work",
      protected = true,
    })
    assert.is_nil(deep(menu.build(aws, { aws = "connected" }), "Quit AWS VPN Client"))
    assert.is_nil(deep(menu.build(aws, { aws = "connected" }), "Restart AWS VPN Client"))
  end)

  it("is not offered for a backend with no application at all", function()
    local scutil = only({ id = "a", name = "A", backend = "scutil", service = "a" })
    assert.is_nil(deep(menu.build(scutil, {}), "Restart"))
    assert.is_nil(deep(menu.build(scutil, {}), "Quit A"))
    local shell = only({ id = "s", name = "S", backend = "shell", commands = { connect = "up", disconnect = "down" } })
    assert.is_nil(deep(menu.build(shell, {}), "Restart"))
  end)
end)

describe("menu.quitApps and the one row that closes them all", function()
  local function cfg(profiles)
    return assert(store.normalise({ profiles = profiles }))
  end

  local gp = { id = "gp", name = "GP", backend = "globalprotect", app = "GlobalProtect", order = 10 }
  local aws = { id = "aws", name = "AWS", backend = "awsvpn", app = "AWS VPN Client", row = "w", order = 20 }

  it("lists one entry per application, not one per connection", function()
    local second = { id = "gp2", name = "GP two", backend = "globalprotect", app = "GlobalProtect", order = 30 }
    local apps = menu.quitApps(cfg({ gp, aws, second }))
    assert.equals(2, #apps, "two connections through one client are one thing to quit")
    assert.equals("GlobalProtect", apps[1].app)
    assert.equals("AWS VPN Client", apps[2].app)
  end)

  it("leaves out a protected client that is its own tunnel", function()
    local locked = {
      id = "aws",
      name = "AWS",
      backend = "awsvpn",
      app = "AWS VPN Client",
      row = "w",
      protected = true,
      order = 20,
    }
    local apps = menu.quitApps(cfg({ gp, locked }))
    assert.equals(1, #apps)
    assert.equals("GlobalProtect", apps[1].app)
  end)

  it("keeps a protected agent whose tunnel outlives it", function()
    local locked = { id = "gp", name = "GP", backend = "globalprotect", app = "GlobalProtect", protected = true }
    assert.equals(1, #menu.quitApps(cfg({ locked })))
  end)

  it("is empty when nothing has an application to close", function()
    assert.same({}, menu.quitApps(cfg({ { id = "a", name = "A", backend = "scutil", service = "a" } })))
  end)

  it("puts one row in the menu and names what it closes", function()
    local item
    for _, row in ipairs(menu.build(cfg({ gp, aws }), {})) do
      if row.title == "Quit every VPN app" then
        item = row
      end
    end
    assert.is_table(item, "the row is there")
    assert.same({ kind = "quitAllApps" }, item.action)
    assert.matches("GlobalProtect", item.tooltip)
    assert.matches("AWS VPN Client", item.tooltip)
  end)

  it("does not call one application 'them'", function()
    local item
    for _, row in ipairs(menu.build(cfg({ gp }), {})) do
      if row.title == "Quit every VPN app" then
        item = row
      end
    end
    assert.matches("leaves it closed", item.tooltip)
    assert.is_nil(item.tooltip:find("them", 1, true), item.tooltip)
  end)

  it("does call two of them 'them'", function()
    local item
    for _, row in ipairs(menu.build(cfg({ gp, aws }), {})) do
      if row.title == "Quit every VPN app" then
        item = row
      end
    end
    assert.matches("leaves them closed", item.tooltip)
  end)

  it("has no such row when there is nothing to close", function()
    for _, row in ipairs(menu.build(cfg({ { id = "a", name = "A", backend = "scutil", service = "a" } }), {})) do
      assert.not_equals("Quit every VPN app", row.title)
    end
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

  it("offers it on a protected connection too, which is where it matters most", function()
    assert.is_false(deep(menu.build(cfg({ protected = true }), {}), "Connect automatically").disabled)
  end)
end)

describe("menu.build, the settings submenu", function()
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

  it("offers both settings, with a tick showing where they stand", function()
    local off = menu.build(store.empty(), {})
    assert.is_false(deep(off, "Only one connection at a time").checked)
    assert.is_true(deep(off, "Use fallbacks").checked)
  end)

  it("carries the setting name in the action, not the label", function()
    local item = deep(menu.build(store.empty(), {}), "Only one connection at a time")
    assert.same({ kind = "toggleSetting", setting = "exclusive" }, item.action)
  end)

  it("follows what the config says", function()
    local cfg = assert(store.setSettings(store.empty(), { exclusive = true, fallback = false }))
    local items = menu.build(cfg, {})
    assert.is_true(deep(items, "Only one connection at a time").checked)
    assert.is_false(deep(items, "Use fallbacks").checked)
  end)

  it("says what each one does, since neither is obvious from four words", function()
    for _, label in ipairs({ "Only one connection at a time", "Use fallbacks" }) do
      local item = deep(menu.build(store.empty(), {}), label)
      assert.is_string(item.tooltip)
      assert.is_true(#item.tooltip > 40)
    end
  end)
end)

describe("menu.build, what it never offers", function()
  -- `supersede` is the one verb allowed to close a protected connection. It
  -- belongs to the one-at-a-time rule and to nothing a person can click, so if
  -- it ever reaches a menu item, protection has stopped meaning what the menu
  -- says it means.
  it("has no item anywhere that supersedes a connection", function()
    local cfg = assert(store.normalise({
      settings = { exclusive = true },
      profiles = {
        { id = "a", name = "A", backend = "scutil", service = "a", order = 10, protected = true },
        { id = "b", name = "B", backend = "scutil", service = "b", order = 20 },
      },
    }))
    local states = { a = "connected", b = "connected" }
    local seen = {}
    local function walk(items)
      for _, item in ipairs(items) do
        if item.action then
          seen[#seen + 1] = item.action.kind .. "/" .. tostring(item.action.verb)
        end
        if item.menu then
          walk(item.menu)
        end
      end
    end
    walk(menu.build(cfg, states))
    for _, kind in ipairs(seen) do
      assert.is_nil(kind:find("supersede", 1, true), "a menu item asks for " .. kind)
    end
  end)
end)

describe("menu.build, the order is the priority", function()
  local function twoProfiles()
    return assert(store.normalise({
      profiles = {
        { id = "a", name = "A", backend = "scutil", service = "a", order = 10 },
        { id = "b", name = "B", backend = "scutil", service = "b", order = 20 },
      },
    }))
  end

  local function moveItems(cfg, name)
    for _, item in ipairs(menu.build(cfg, {})) do
      if item.title == "Connections" then
        for _, entry in ipairs(item.menu) do
          if entry.title == name and entry.menu then
            local out = {}
            for _, row in ipairs(entry.menu) do
              if tostring(row.title):find("Move", 1, true) then
                out[#out + 1] = row
              end
            end
            return out
          end
        end
      end
    end
    return {}
  end

  it("says where a connection sits, so moving it means something", function()
    local rows = moveItems(twoProfiles(), "A")
    assert.equals("Move up (1 of 2)", rows[1].title)
  end)

  it("says what the order decides, which nothing used to", function()
    local rows = moveItems(twoProfiles(), "B")
    assert.is_truthy(rows[1].tooltip:find("tried first", 1, true))
    assert.is_truthy(rows[2].tooltip:find("taken down first", 1, true))
  end)
end)

describe("menu.build, a connection that needs a login", function()
  local function one(extra)
    local profile = { id = "gp", name = "GP", backend = "globalprotect", app = "GP" }
    for k, v in pairs(extra or {}) do
      profile[k] = v
    end
    return assert(store.normalise({ profiles = { profile } }))
  end

  it("says so on the row, since the glyph cannot", function()
    local row = menu.build(one(), { gp = "login" })[1]
    assert.equals("○  GP", row.title)
    assert.matches("needs your login", row.tooltip)
    assert.same({ kind = "connect", id = "gp" }, row.action)
  end)

  -- Protection points at bringing a connection down. Down for want of a login
  -- is still down, and the one click that may bring it back must stay.
  it("offers a protected connection its one click back, as it would when merely down", function()
    local row = menu.build(one({ protected = true }), { gp = "login" })[1]
    assert.is_nil(row.disabled, "not greyed out")
    assert.same({ kind = "connect", id = "gp" }, row.action)
    assert.matches("protected once it is up", row.tooltip)
  end)

  it("ranks it as down for the one glyph in the menu bar", function()
    assert.equals("connecting", menu.overall({ a = "login", b = "connecting" }))
    assert.equals("connected", menu.overall({ a = "login", b = "connected" }))
    -- The one that fails if `login` is missing from the ranking: unranked
    -- would lose to unknown, and a menu that knows a login is needed is not a
    -- menu where nothing is known.
    assert.equals("login", menu.overall({ a = "login", b = "unknown" }))
  end)
end)
