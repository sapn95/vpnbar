--- Reading the AWS VPN Client's window, without touching it.
---
--- The client draws its interface in a web view, so what the accessibility API
--- offers is a flat run of roles and strings rather than a table with rows in
--- it. Everything here works on that run: a list of `{ role, title, value }`
--- in the order the tree yields them, which the adapter produces alongside the
--- elements themselves. The adapter presses; this file decides what.
---
--- The shape it describes was measured on the live client, not assumed
--- ([ADR 0032](../../docs/adr/0032-the-aws-client-is-driven-by-keyboard.md)):
---
---     static  "Status:"                    static  "sbb"
---     static  "Ready to connect"           static  "Connected"
---     button  "sbb_full"   <- chooser      button  "Disconnect"
---     button  "Connect"                    button  "Other actions"
---
--- The left column is how a connection is started: one chooser naming the
--- profile that will be connected, and one Connect. The right column is the
--- list of connections that are already up, one block each. A profile that is
--- up is therefore in the second list and missing from the chooser, and the
--- Connect button belongs to no profile in particular.

local awsui = {}

--- How many nodes after a name still count as part of its block.
---
--- Three: state, button, button. A search that ran on would find the next
--- connection's Disconnect and take down a tunnel nobody asked about, which is
--- the one mistake this file exists to make impossible.
awsui.BLOCK = 3

local function node(nodes, index)
  local found = nodes[index]
  return type(found) == "table" and found or nil
end

local function text(entry)
  if type(entry) ~= "table" then
    return nil
  end
  return entry.value or entry.title
end

--- Where a name appears as plain text, which is where its block begins.
--- @param nodes table
--- @param row string
--- @return number|nil
function awsui.rowAt(nodes, row)
  if type(row) ~= "string" or row == "" then
    return nil
  end
  for index, entry in ipairs(nodes or {}) do
    if entry.role == "AXStaticText" and entry.value == row then
      return index
    end
  end
  return nil
end

--- Is this profile one of the connections that are already up?
---
--- The word sits in the block that follows the name. Asked before anything is
--- pressed, because the client answers a second Connect on a live profile with
--- an error dialog, and because a connect that has nothing to do should say so
--- rather than press something.
--- @param nodes table
--- @param row string
--- @return boolean
function awsui.isConnected(nodes, row)
  local at = awsui.rowAt(nodes, row)
  if not at then
    return false
  end
  for offset = 1, awsui.BLOCK do
    local entry = node(nodes, at + offset)
    if entry and entry.role == "AXStaticText" and entry.value == "Connected" then
      return true
    end
  end
  return false
end

--- The button of one title inside one profile's block.
--- @param nodes table
--- @param row string
--- @param title string
--- @return number|nil index into `nodes`
function awsui.rowButton(nodes, row, title)
  local at = awsui.rowAt(nodes, row)
  if not at then
    return nil
  end
  for offset = 1, awsui.BLOCK do
    local entry = node(nodes, at + offset)
    if entry and entry.role == "AXButton" and entry.title == title then
      return at + offset
    end
  end
  return nil
end

--- The Connect button, and the chooser that says what it will connect.
---
--- Found by their order rather than by their names, because the chooser is
--- titled after whichever profile is selected: a client sitting on `sbb_full`
--- has a button called `sbb_full`, which no rule about names could tell from
--- the profile of the same name in the list of live connections. What does not
--- move is that the chooser is the button immediately before Connect.
--- @param nodes table
--- @return number|nil connect, number|nil chooser
function awsui.connectAt(nodes)
  for index, entry in ipairs(nodes or {}) do
    if entry.role == "AXButton" and entry.title == "Connect" then
      local before = node(nodes, index - 1)
      local chooser = (before and before.role == "AXButton") and index - 1 or nil
      return index, chooser
    end
  end
  return nil, nil
end

--- What the chooser is set to right now, or nil when there is no chooser.
--- @param nodes table
--- @return string|nil
function awsui.chosen(nodes)
  local _, chooser = awsui.connectAt(nodes)
  local entry = chooser and node(nodes, chooser) or nil
  return entry and entry.title or nil
end

--- The profiles the open chooser is offering, in the order it lists them.
---
--- Its own little tree: a list of menu items whose name is in the value. Only
--- the profiles that can still be connected are in it, so a profile that is
--- already up is absent — which is why nothing here treats a missing name as an
--- error on its own.
--- @param nodes table nodes of the open chooser
--- @return table list of strings
function awsui.offered(nodes)
  local names = {}
  for _, entry in ipairs(nodes or {}) do
    if entry.role == "AXMenuItem" then
      local name = text(entry)
      if type(name) == "string" and name ~= "" then
        names[#names + 1] = name
      end
    end
  end
  return names
end

--- What the open chooser has highlighted, which is where an arrow key starts
--- from.
---
--- Two marks, and they are not the same thing. `selected` sits on the profile
--- the chooser is committed to and does not move; `focused` is what the arrow
--- keys move. They coincide only at the instant the chooser opens, which is the
--- instant the first version of this was measured at, and reading "either" then
--- meant that every walk downwards from the committed profile read the
--- committed one back, pressed again, and wrapped around to it
--- ([ADR 0032](../../docs/adr/0032-the-aws-client-is-driven-by-keyboard.md)).
--- Focus first; the committed one only when nothing has focus.
--- @param nodes table nodes of the open chooser
--- @return string|nil
function awsui.highlighted(nodes)
  local committed
  for _, entry in ipairs(nodes or {}) do
    if entry.role == "AXMenuItem" then
      if entry.focused then
        return text(entry)
      end
      committed = committed or (entry.selected and text(entry)) or nil
    end
  end
  return committed
end

--- Which way to walk the highlight, and how far, to reach one name.
---
--- The chooser opens with something already highlighted, and the only way to
--- move that highlight is an arrow key. Returning the direction and the count
--- keeps the arithmetic here, where a test can ask about it, rather than in a
--- loop that presses keys.
--- @param offered table names in the order the chooser lists them
--- @param highlighted string|nil what is highlighted now
--- @param wanted string the profile to reach
--- @return string|nil "down"|"up", number steps
function awsui.stepsTo(offered, highlighted, wanted)
  local from, to
  for index, name in ipairs(offered or {}) do
    if name == highlighted then
      from = index
    end
    if name == wanted then
      to = index
    end
  end
  if not to then
    return nil, 0
  end
  -- Nothing highlighted: the first press of an arrow lands on the first entry,
  -- so counting from above it gets there.
  from = from or 0
  if to == from then
    return nil, 0
  end
  if to > from then
    return "down", to - from
  end
  return "up", from - to
end

return awsui
