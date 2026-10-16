local awsui = require("vpnbar.awsui")

--- The window as it was measured with one profile up and another selected:
--- the chooser and its Connect first, then a block per live connection.
local function window(overrides)
  local nodes = {
    { role = "AXImage", title = "", value = "" },
    { role = "AXStaticText", title = "", value = "AWS" },
    { role = "AXStaticText", title = "", value = "VPN Client" },
    { role = "AXStaticText", title = "", value = "Status:" },
    { role = "AXStaticText", title = "", value = "Ready to connect" },
    { role = "AXButton", title = "work_full", value = "" },
    { role = "AXButton", title = "Connect", value = "" },
    { role = "AXStaticText", title = "", value = "You may connect up to 5 profiles." },
    { role = "AXStaticText", title = "", value = "work" },
    { role = "AXStaticText", title = "", value = "Connected" },
    { role = "AXButton", title = "Disconnect", value = "" },
    { role = "AXButton", title = "Other actions", value = "" },
  }
  for index, entry in pairs(overrides or {}) do
    nodes[index] = entry
  end
  return nodes
end

describe("awsui, reading the client's window", function()
  it("finds the Connect button and the chooser in front of it", function()
    local connect, chooser = awsui.connectAt(window())
    assert.equals(7, connect)
    assert.equals(6, chooser)
    assert.equals("work_full", awsui.chosen(window()))
  end)

  it("knows a chooser named after a profile from the profile itself", function()
    -- The chooser carries the name of whatever is selected, so a rule that went
    -- looking for a button called "work" would find the wrong thing entirely.
    assert.equals(6, select(2, awsui.connectAt(window())))
    assert.is_nil(awsui.rowButton(window(), "work_full", "Connect"))
  end)

  it("says which profile is already up", function()
    assert.is_true(awsui.isConnected(window(), "work"))
    assert.is_false(awsui.isConnected(window(), "work_full"))
    assert.is_false(awsui.isConnected(window(), "nothing of the sort"))
    -- A line of text that is not a connection at all. Its block says nothing
    -- about being connected, which is the answer.
    assert.is_false(awsui.isConnected(window(), "AWS"))
  end)

  it("finds a live connection's own Disconnect", function()
    assert.equals(11, awsui.rowButton(window(), "work", "Disconnect"))
  end)

  it("will not reach past one connection's block into the next", function()
    -- Two connections, and the first one's Disconnect has gone missing. The
    -- answer is nothing, never the second connection's.
    local nodes = window()
    table.remove(nodes, 11)
    nodes[#nodes + 1] = { role = "AXStaticText", title = "", value = "other" }
    nodes[#nodes + 1] = { role = "AXStaticText", title = "", value = "Connected" }
    nodes[#nodes + 1] = { role = "AXButton", title = "Disconnect", value = "" }
    assert.is_nil(awsui.rowButton(nodes, "work", "Disconnect"))
    assert.equals(14, awsui.rowButton(nodes, "other", "Disconnect"))
  end)

  it("has no Connect to offer when the client shows none", function()
    local nodes = window()
    table.remove(nodes, 7)
    local connect, chooser = awsui.connectAt(nodes)
    assert.is_nil(connect)
    assert.is_nil(chooser)
    assert.is_nil(awsui.chosen(nodes))
  end)

  it("takes no chooser from a Connect that has no button before it", function()
    local nodes = window()
    nodes[6] = { role = "AXStaticText", title = "", value = "Profile" }
    assert.equals(7, (awsui.connectAt(nodes)))
    assert.is_nil(select(2, awsui.connectAt(nodes)))
  end)

  --- The window with the notice of a refused connect left on it, which is where
  --- the client puts the only sentence that says why nothing happened.
  local function refused(reason)
    local nodes = window()
    nodes[#nodes + 1] = { role = "AXStaticText", title = "", value = "AWS VPN Client" }
    nodes[#nodes + 1] = { role = "AXStaticText", title = "", value = "Failed to connect" }
    if reason then
      nodes[#nodes + 1] = { role = "AXStaticText", title = "", value = reason }
    end
    nodes[#nodes + 1] = { role = "AXButton", title = "Close", value = "" }
    return nodes
  end

  it("reads the reason the client refused a connect, and where to dismiss it", function()
    local reason, dismiss = awsui.failure(refused("The provided credentials are incorrect."))
    assert.equals("The provided credentials are incorrect.", reason)
    assert.equals(16, dismiss)
  end)

  it("has nothing to report about a window with no notice on it", function()
    local reason, dismiss = awsui.failure(window())
    assert.is_nil(reason)
    assert.is_nil(dismiss)
    assert.is_nil((awsui.failure(nil)))
  end)

  it("falls back to the headline when the notice carries no reason", function()
    -- Worth saying even on its own: it is the difference between a connect the
    -- client turned down and a connect that did nothing.
    assert.equals("Failed to connect", (awsui.failure(refused(nil))))
  end)

  it("takes the first line of text as the reason and not the second", function()
    local nodes = refused("The provided credentials are incorrect.")
    table.insert(nodes, 16, { role = "AXStaticText", title = "", value = "Contact your administrator." })
    assert.equals("The provided credentials are incorrect.", (awsui.failure(nodes)))
  end)

  it("presses nothing when the notice offers a button that is not its Close", function()
    local nodes = refused("The provided credentials are incorrect.")
    nodes[16] = { role = "AXButton", title = "Other actions", value = "" }
    local reason, dismiss = awsui.failure(nodes)
    assert.equals("The provided credentials are incorrect.", reason)
    assert.is_nil(dismiss)
  end)

  it("will not reach past the notice for a Close that belongs to the window", function()
    local nodes = refused("The provided credentials are incorrect.")
    table.remove(nodes, 16)
    nodes[#nodes + 1] = { role = "AXStaticText", title = "", value = "You may connect up to 5 profiles." }
    nodes[#nodes + 1] = { role = "AXButton", title = "Close", value = "" }
    local reason, dismiss = awsui.failure(nodes)
    assert.equals("The provided credentials are incorrect.", reason)
    assert.is_nil(dismiss)
  end)
end)

describe("awsui, the open chooser", function()
  local function chooser(selected)
    local names = { "work", "work_full", "lab" }
    local nodes = {}
    for _, name in ipairs(names) do
      nodes[#nodes + 1] = {
        role = "AXMenuItem",
        title = "",
        value = name,
        selected = name == selected,
        focused = name == selected,
      }
    end
    return nodes
  end

  it("lists what it offers, in its own order", function()
    assert.same({ "work", "work_full", "lab" }, awsui.offered(chooser()))
    assert.same({}, awsui.offered(window()))
  end)

  it("follows the focus, which is what the arrow keys move", function()
    -- The committed profile keeps `selected` wherever the focus goes. After
    -- one Down from the committed profile the two are on different items, and
    -- reading the committed one back is what made every downward walk fail.
    local nodes = {
      { role = "AXMenuItem", value = "work_full", selected = true, focused = false },
      { role = "AXMenuItem", value = "work", selected = false, focused = true },
    }
    assert.equals("work", awsui.highlighted(nodes))
  end)

  it("falls back to the committed profile when nothing has focus", function()
    local nodes = {
      { role = "AXMenuItem", value = "work_full", selected = true, focused = false },
      { role = "AXMenuItem", value = "work", selected = false, focused = false },
    }
    assert.equals("work_full", awsui.highlighted(nodes))
  end)

  it("reads the highlight, marked either way round", function()
    assert.equals("work_full", awsui.highlighted(chooser("work_full")))
    assert.is_nil(awsui.highlighted(chooser()))
    assert.equals("lab", awsui.highlighted({ { role = "AXMenuItem", value = "lab", focused = true } }))
  end)

  it("takes the focus state back off the name the client lengthened", function()
    -- Measured on the live chooser: the entry the focus is on reads
    -- `work not selected`, and the same entry reads `work` the moment the focus
    -- is somewhere else. Read as it comes, the name matches no entry of the
    -- list the walk is counting steps along, so every walk downwards ended one
    -- entry short of the profile somebody asked for.
    local nodes = {
      { role = "AXMenuItem", value = "work_full", selected = true, focused = false },
      { role = "AXMenuItem", value = "work not selected", selected = false, focused = true },
    }
    assert.same({ "work_full", "work" }, awsui.offered(nodes))
    assert.equals("work", awsui.highlighted(nodes))
    assert.same({ nil, 0 }, { awsui.stepsTo(awsui.offered(nodes), awsui.highlighted(nodes), "work") })
  end)

  it("leaves the name alone on every entry the client did not rewrite", function()
    -- The committed entry keeps its plain name with the focus on it, and an
    -- entry nothing is pointing at is never rewritten at all. A profile whose
    -- own name ends in those words is not shortened for having been read.
    local nodes = {
      { role = "AXMenuItem", value = "work not selected", selected = true, focused = true },
      { role = "AXMenuItem", value = "lab not selected", selected = false, focused = false },
    }
    assert.same({ "work not selected", "lab not selected" }, awsui.offered(nodes))
    assert.equals("work not selected", awsui.highlighted(nodes))
  end)

  it("keeps an entry that is nothing but those words", function()
    local nodes = { { role = "AXMenuItem", value = " not selected", selected = false, focused = true } }
    assert.same({ " not selected" }, awsui.offered(nodes))
  end)

  it("shortens a focused name by those words and by nothing else", function()
    -- Long enough to be cut by a rule that counted characters instead of
    -- reading them, and the profile somebody asked for either way.
    local nodes = {
      { role = "AXMenuItem", value = "work_full", selected = true, focused = false },
      { role = "AXMenuItem", value = "work_in_the_other_office", selected = false, focused = true },
    }
    assert.same({ "work_full", "work_in_the_other_office" }, awsui.offered(nodes))
    assert.equals("work_in_the_other_office", awsui.highlighted(nodes))
  end)

  it("has no name to shorten on an entry that carries none", function()
    local nodes = { { role = "AXMenuItem", selected = false, focused = true } }
    assert.same({}, awsui.offered(nodes))
    assert.is_nil(awsui.highlighted(nodes))
  end)

  it("counts the arrow presses from the highlight to the profile", function()
    local offered = awsui.offered(chooser())
    assert.same({ "down", 2 }, { awsui.stepsTo(offered, "work", "lab") })
    assert.same({ "up", 1 }, { awsui.stepsTo(offered, "work_full", "work") })
  end)

  it("counts from above the list when nothing is highlighted", function()
    -- The first press of an arrow lands on the first entry.
    local offered = awsui.offered(chooser())
    assert.same({ "down", 1 }, { awsui.stepsTo(offered, nil, "work") })
    assert.same({ "down", 3 }, { awsui.stepsTo(offered, nil, "lab") })
  end)

  it("asks for nothing when the highlight is already there", function()
    local offered = awsui.offered(chooser())
    assert.same({ nil, 0 }, { awsui.stepsTo(offered, "lab", "lab") })
  end)

  it("says so rather than guessing when the profile is not offered", function()
    -- A profile that is already up is not in the list, and neither is one the
    -- client has never heard of. Pressing anything here connects the wrong one.
    local offered = awsui.offered(chooser())
    assert.same({ nil, 0 }, { awsui.stepsTo(offered, "work", "somewhere else") })
    assert.same({ nil, 0 }, { awsui.stepsTo({}, nil, "work") })
  end)

  it("has nothing to say about a row with no name", function()
    assert.is_nil(awsui.rowAt(window(), ""))
    assert.is_nil(awsui.rowAt(window(), nil))
    assert.is_false(awsui.isConnected(window(), nil))
  end)
end)
