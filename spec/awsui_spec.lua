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
