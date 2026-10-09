--- === VpnBar ===
---
--- A menu-bar button for the VPNs on this Mac: what is up, one click to change
--- it, and add / edit / reorder / remove without leaving the menu.
---
--- Everything that decides anything lives in `vpnbar/` and is tested there.
--- This file is the adapter: Hammerspoon on one side, those modules on the
--- other, and as little judgement in between as it can get away with.

local obj = {}
obj.__index = obj

obj.name = "VpnBar"
obj.version = "0.1.0"
obj.author = "Sebastian Winterberger"
obj.license = "MIT"
obj.homepage = "https://github.com/sapn95/vpnbar"

obj.spoonPath = debug.getinfo(1, "S").source:match("^@(.*/)")
package.path = obj.spoonPath .. "?.lua;" .. obj.spoonPath .. "?/init.lua;" .. package.path

local store = require("vpnbar.store")
local menu = require("vpnbar.menu")
local autoconnect = require("vpnbar.autoconnect")
local backends = require("vpnbar.backends")
local form = require("vpnbar.form")
local icon = require("vpnbar.icon")
local work = require("vpnbar.work")
local awsui = require("vpnbar.awsui")
local routes = require("vpnbar.routes")

--- VpnBar.configPath
--- Variable
--- Where the connections are kept. Set it before `:start()` to move it.
obj.configPath = os.getenv("HOME") .. "/.config/vpnbar/profiles.json"

--- VpnBar.interval
--- Variable
--- Seconds between state polls. Only cheap reads run on this timer — see
--- `panelReads` below.
obj.interval = 10

--- VpnBar.panelReads
--- Variable
--- Whether a connection with no probe may be read by opening its app's panel.
--- Off on the timer no matter what this says; on only for an explicit refresh,
--- because opening a panel moves something on screen.
obj.panelReads = true

obj.logger = hs.logger.new("vpnbar", "info")

-- ---------------------------------------------------------------- config i/o

--- Make every missing directory on the way to `path`.
---
--- `hs.fs.mkdir` creates one level, and the default config lives two below a
--- `~/.config` that a fresh Mac has never needed. One level meant the very
--- first save failed on exactly the machine that had never run this before.
local function ensureDirectory(path)
  local directory = path:match("^(.*)/[^/]*$")
  if not directory then
    return
  end
  local sofar = directory:sub(1, 1) == "/" and "" or "."
  for part in directory:gmatch("[^/]+") do
    sofar = sofar .. "/" .. part
    if not hs.fs.attributes(sofar) then
      hs.fs.mkdir(sofar)
    end
  end
end

--- Write the config, or nothing at all. A crash between `open` and the last
--- byte would otherwise leave a truncated file that the next start refuses,
--- and the connections would be gone with it.
local function writeAtomically(path, contents)
  ensureDirectory(path)
  local temporary = path .. ".tmp"
  local file, err = io.open(temporary, "w")
  if not file then
    return false, err
  end
  local ok, writeErr = file:write(contents)
  file:close()
  if not ok then
    os.remove(temporary)
    return false, writeErr
  end
  return os.rename(temporary, path)
end

function obj:load()
  local file = io.open(self.configPath, "r")
  if not file then
    -- Only a file that genuinely is not there means "no connections yet".
    -- Anything else — permissions, a directory in the way — must not empty the
    -- menu, because the next save would then write that emptiness over a
    -- config that was fine.
    if hs.fs.attributes(self.configPath) then
      self:complain("The config file cannot be read — leaving it alone.")
      self.config = self.config or store.empty()
      return self.config
    end
    self.config = self.config or store.empty()
    return self.config
  end
  local contents = file:read("a")
  file:close()
  local decoded = hs.json.decode(contents)
  if decoded == nil and contents:match("%S") then
    self:complain("The config file is not valid JSON — leaving it alone.")
    self.config = self.config or store.empty()
    return self.config
  end
  local config, err = store.normalise(decoded)
  if not config then
    self:complain("Config rejected: " .. err)
    self.config = self.config or store.empty()
    return self.config
  end
  self.config = config
  return config
end

function obj:save(config)
  local ok, err = writeAtomically(self.configPath, hs.json.encode(config, true))
  if not ok then
    self:complain("Could not write the config: " .. tostring(err))
    return false
  end
  self.config = config
  return true
end

function obj:complain(message)
  self.logger.w(message)
  hs.notify.new({ title = "vpnbar", informativeText = message, withdrawAfter = 10 }):send()
end

-- ------------------------------------------------- accessibility, for the app
-- ------------------------------------------------- that has no other way in

local function menuBarItem(appName)
  local app = hs.application.get(appName)
  if not app then
    return nil, appName .. " is not running"
  end
  local element = hs.axuielement.applicationElement(app)
  local bar = element and element:attributeValue("AXExtrasMenuBar")
  local item = bar and (bar:attributeValue("AXChildren") or {})[1]
  if not item then
    return nil, appName .. " has no menu-bar item"
  end
  return item, nil
end

local function textOf(element)
  local parts = {}
  for _, attribute in ipairs({ "AXTitle", "AXDescription", "AXValue" }) do
    local value = element:attributeValue(attribute)
    if type(value) == "string" then
      parts[#parts + 1] = value
    end
  end
  return table.concat(parts, " "):lower()
end

--- How deep a window's tree is followed.
---
--- Eight was enough for a panel and not for a web view. The AWS client draws
--- its window in one, and its own controls sit at depth nine and ten behind
--- seven nested groups, so a walk that stopped at eight found the groups, none
--- of the buttons, and reported a client that offered nothing
--- ([ADR 0032](../../docs/adr/0032-the-aws-client-is-driven-by-keyboard.md)).
--- Twenty is past anything either client draws and still a number, which is
--- what the bound is for: a tree with a cycle in it would otherwise hang
--- Hammerspoon.
local WALK_DEPTH = 20

--- Depth-first walk, calling `visit` on every element.
local function walk(element, visit, depth)
  depth = depth or 0
  if depth > WALK_DEPTH or not element then
    return nil
  end
  local found = visit(element)
  if found then
    return found
  end
  for _, child in ipairs(element:attributeValue("AXChildren") or {}) do
    found = walk(child, visit, depth + 1)
    if found then
      return found
    end
  end
  return nil
end

local function findPressable(root, verbs)
  return walk(root, function(element)
    local actions = element:actionNames() or {}
    local pressable = false
    for _, action in ipairs(actions) do
      pressable = pressable or action == "AXPress"
    end
    if not pressable then
      return nil
    end
    local text = textOf(element)
    for _, verb in ipairs(verbs) do
      if text:find(verb, 1, true) then
        return element
      end
    end
    return nil
  end)
end

--- Do something that takes the focus, then give it back.
---
--- Every way this Spoon reaches a VPN client goes through that client's own
--- user interface: a menu-bar panel that opens with keyboard focus, a window
--- brought up by `open`. Each of those takes the focus from whatever the person
--- was typing into, and nothing gave it back. With autoconnect retrying on a
--- schedule, that was the focus being taken every few minutes, for as long as a
--- connection stayed down.
---
--- The window is preferred to the application: an app with several windows
--- would otherwise come back with whichever one it chose.
--- @param body function
--- @return ... whatever body returns
local function keepingFocus(body)
  local app = hs.application.frontmostApplication()
  local window = hs.window.focusedWindow()
  -- Restored whether or not the body threw. Every caller is under a pcall
  -- already, but a throw that left the focus on the agent's panel would be the
  -- one occurrence of the thing this exists to prevent.
  local results = table.pack(pcall(body))
  if window and window:isVisible() then
    window:focus()
  elseif app then
    app:activate()
  end
  if not results[1] then
    error(results[2], 0)
  end
  return table.unpack(results, 2, results.n)
end

--- Open the panel, do something with it, close it again. The same click both
--- opens and closes it, which is more reliable than sending Escape and does
--- not depend on which window happens to be focused.
local function withPanel(appName, body)
  local item, err = menuBarItem(appName)
  if not item then
    return nil, err
  end
  item:performAction("AXPress")

  local element = hs.axuielement.applicationElement(hs.application.get(appName))
  local window
  for _ = 1, 30 do
    window = (element:attributeValue("AXWindows") or {})[1]
    if window then
      break
    end
    hs.timer.usleep(100000)
  end

  local result, bodyErr
  if window then
    result, bodyErr = body(window)
  else
    bodyErr = "the " .. appName .. " panel did not open"
  end

  item:performAction("AXPress")
  return result, bodyErr
end

--- What the panel says about itself. The state lives in two places — a status
--- line and the name of the status image — and either will do.
local function panelState(appName)
  local state = withPanel(appName, function(window)
    local words = {}
    walk(window, function(element)
      local role = element:attributeValue("AXRole")
      if role == "AXStaticText" or role == "AXImage" then
        words[#words + 1] = textOf(element)
      end
      return nil
    end)
    return require("vpnbar.parse").state(table.concat(words, " "))
  end)
  return state or "unknown"
end

--- Make sure an app has a window to look at, opening it if it has none.
---
--- The AWS client keeps running without one, and with no window its
--- accessibility tree is empty — which is what made an earlier version of this
--- project conclude it had none at all.
--- The first thing in a list of windows that is actually a window.
---
--- A client with no window open still answers `AXWindows` with one entry, and
--- that entry has the role `AXApplication` and a frame of nothing: a tree of
--- menu bars rather than an interface. Taken at face value it is a window where
--- every control is missing, which reads exactly like a client that has stopped
--- offering them ([ADR 0032](../../docs/adr/0032-the-aws-client-is-driven-by-keyboard.md)).
local function realWindow(element)
  for _, candidate in ipairs((element and element:attributeValue("AXWindows")) or {}) do
    if candidate:attributeValue("AXRole") == "AXWindow" then
      return candidate
    end
  end
  return nil
end

local function windowOf(appName)
  local app = hs.application.get(appName)
  if not app then
    return nil, appName .. " is not running"
  end
  local element = hs.axuielement.applicationElement(app)
  local window = realWindow(element)
  if window then
    return window, nil
  end
  -- Not `open -g`. Measured: plain `open -a` on the running client left the
  -- focus where it was, and `-g` moved the focused window to the client's.
  hs.execute("/usr/bin/open -a " .. backends.shellQuote(appName))
  for _ = 1, 25 do
    window = realWindow(element)
    if window then
      return window, nil
    end
    hs.timer.usleep(200000)
  end
  -- Measured on the AWS client: once its window has been closed, neither
  -- `open -a` nor activating it brings one back, and it has no Window menu to
  -- ask. Only its icon in the menu bar does, so that is what the message says
  -- rather than a second attempt that would fail the same way.
  return nil, ("%s has no window to click in; its menu bar icon opens one"):format(appName)
end

--- Every element of a window in the order the tree yields them, as plain data
--- beside the elements themselves.
---
--- The data half is what `vpnbar/awsui.lua` reads, so which button belongs to
--- which profile is decided by a pure function and tested without a client;
--- the element half is what gets pressed.
--- @param root table an accessibility element
--- @return table nodes, table elements
local function flatten(root)
  local nodes, elements = {}, {}
  walk(root, function(element)
    nodes[#nodes + 1] = {
      role = element:attributeValue("AXRole"),
      title = element:attributeValue("AXTitle"),
      value = element:attributeValue("AXValue"),
      selected = element:attributeValue("AXSelected") == true,
      focused = element:attributeValue("AXFocused") == true,
    }
    elements[#elements + 1] = element
    return nil
  end)
  return nodes, elements
end

--- Press one control, by focusing it and sending it a key.
---
--- `AXPress` is what this used to do and it does nothing at all in this client:
--- measured on its profile chooser, on a plain button and on a menu item, the
--- action is accepted and no click happens. What does work is the keyboard the
--- control already answers to, and it works with the application in the
--- background, so nothing is brought to the front and no focus is taken
--- ([ADR 0032](../../docs/adr/0032-the-aws-client-is-driven-by-keyboard.md)).
---
--- The key is addressed to the application rather than to the system, so a
--- focus that did not take sends a keystroke the client ignores, never a space
--- into whatever somebody is typing in.
--- @param appName string
--- @param element table|nil
--- @param key string "return" presses a button, "space" opens the chooser
--- @return boolean
local function pressElement(appName, element, key)
  local app = hs.application.get(appName)
  if not app or not element then
    return false
  end
  pcall(function()
    element:setAttributeValue("AXFocused", true)
  end)
  hs.timer.usleep(150000)
  hs.eventtap.keyStroke({}, key, 0, app)
  return true
end

--- Every real window of an application, the chooser's included.
local function windowsOf(appName)
  local app = hs.application.get(appName)
  local element = app and hs.axuielement.applicationElement(app)
  local windows = {}
  for _, candidate in ipairs((element and element:attributeValue("AXWindows")) or {}) do
    if candidate:attributeValue("AXRole") == "AXWindow" then
      windows[#windows + 1] = candidate
    end
  end
  return windows
end

--- The window with the client in it, as opposed to a chooser hanging open.
---
--- An open chooser is a window of the application in its own right, and it
--- comes first in the list, so the plain "first window" this used to take was
--- whichever of the two happened to be there.
local function clientWindow(appName)
  local _, err = windowOf(appName)
  if err then
    return nil, nil, err
  end
  for _, candidate in ipairs(windowsOf(appName)) do
    local nodes, elements = flatten(candidate)
    if #awsui.offered(nodes) == 0 then
      return nodes, elements, nil
    end
  end
  return nil, nil, ("%s has only a chooser open"):format(appName)
end

--- The chooser's own window, once it is open, or nil while it is not.
local function chooserWindow(appName)
  for _, candidate in ipairs(windowsOf(appName)) do
    local nodes, elements = flatten(candidate)
    if #awsui.offered(nodes) > 0 then
      return nodes, elements
    end
  end
  return nil, nil
end

--- How many times a step of the chooser is looked at before it is called
--- failed, and how long each look is apart. Two seconds all told: the list is
--- drawn by a web view, so it is neither instant nor slow.
local CHOOSER_TRIES, CHOOSER_WAIT = 20, 100000

local function settle(check)
  for _ = 1, CHOOSER_TRIES do
    local value = check()
    if value then
      return value
    end
    hs.timer.usleep(CHOOSER_WAIT)
  end
  return nil
end

--- Set the chooser to one profile, leaving it closed either way.
---
--- Opened with a space, walked with arrow keys and taken with a return, which
--- is what the control answers to. The walk re-reads the highlight after every
--- press rather than counting the presses out in advance: the list is short,
--- the highlight is readable, and a count that was one out would connect a
--- different VPN than the one somebody asked for.
--- @return boolean ok, string|nil err
local function chooseProfile(appName, chooser, row)
  local app = hs.application.get(appName)
  local function escape()
    if app then
      hs.eventtap.keyStroke({}, "escape", 0, app)
    end
  end

  pressElement(appName, chooser, "space")
  local nodes = settle(function()
    return (chooserWindow(appName))
  end)
  if not nodes then
    return false, ("%s did not open its profile chooser"):format(appName)
  end

  local offered = awsui.offered(nodes)
  local _, steps = awsui.stepsTo(offered, awsui.highlighted(nodes), row)
  if steps == 0 and awsui.highlighted(nodes) ~= row then
    escape()
    -- The chooser lists what can still be connected, so a name that is not in
    -- it is either one the client does not have or one that is already up, and
    -- the second was ruled out before we got here.
    return false, ("%s does not offer a profile called %s"):format(appName, tostring(row))
  end

  for _ = 1, #offered do
    local highlighted = awsui.highlighted(nodes)
    if highlighted == row then
      break
    end
    local direction = awsui.stepsTo(offered, highlighted, row)
    if not direction or not app then
      break
    end
    hs.eventtap.keyStroke({}, direction, 0, app)
    -- Wait for the focus to have moved before reading it, rather than reading
    -- once after a fixed pause. A read that came back before the client had
    -- drawn the move said the old item, which asked for another press, and
    -- the list wraps, so one press too many is the committed profile again.
    local before = highlighted
    nodes = settle(function()
      local fresh = chooserWindow(appName)
      if fresh and awsui.highlighted(fresh) ~= before then
        return fresh
      end
      return nil
    end) or chooserWindow(appName) or nodes
  end
  if awsui.highlighted(nodes) ~= row then
    escape()
    return false, ("%s would not move its chooser to %s"):format(appName, tostring(row))
  end

  if app then
    hs.eventtap.keyStroke({}, "return", 0, app)
  end
  local chosen = settle(function()
    local current = clientWindow(appName)
    return (current and awsui.chosen(current) == row) or nil
  end)
  if not chosen then
    escape()
    return false, ("%s did not settle on %s"):format(appName, tostring(row))
  end
  return true, nil
end

--- Press a button on the block belonging to one name.
---
--- Which button that is comes from `awsui`; this only presses it. The block is
--- bounded there, so a profile that does not offer the button being asked for
--- cannot reach into the next one and press that.
local function pressRow(appName, row, buttonTitle)
  local nodes, elements, err = clientWindow(appName)
  if not nodes then
    return false, err
  end
  local at = awsui.rowButton(nodes, row, buttonTitle)
  if not at then
    return false, ("%s offers no %s on a row called %s"):format(appName, buttonTitle, tostring(row))
  end
  pressElement(appName, elements[at], "return")
  return true, nil
end

--- Set the chooser to one profile and press Connect.
---
--- There is no Connect on a profile in this client. There is one chooser saying
--- what will be connected and one Connect beside it, so connecting a named
--- profile means setting the chooser first, and the chooser is a list that only
--- an arrow key moves
--- ([ADR 0032](../../docs/adr/0032-the-aws-client-is-driven-by-keyboard.md)).
local function connectRow(appName, row)
  local nodes, elements, err = clientWindow(appName)
  if not nodes then
    return false, err
  end
  if awsui.isConnected(nodes, row) then
    -- Nothing to press. The client answers a second Connect on a live profile
    -- with a dialog, and a read that lagged behind is a normal thing to have.
    return true, nil
  end
  local connect, chooser = awsui.connectAt(nodes)
  if not connect then
    return false, ("%s offers no Connect right now"):format(appName)
  end

  if awsui.chosen(nodes) ~= row then
    if not chooser then
      return false, ("%s has no profile chooser to pick %s with"):format(appName, tostring(row))
    end
    local ok, chooseErr = chooseProfile(appName, elements[chooser], row)
    if not ok then
      return false, chooseErr
    end
    -- The window is rebuilt around the new selection, so the elements read
    -- before it are stale.
    nodes, elements = clientWindow(appName)
    if not nodes then
      return false, appName .. " closed its window mid-way"
    end
    connect = awsui.connectAt(nodes)
    if not connect then
      return false, ("%s offers no Connect right now"):format(appName)
    end
  end

  pressElement(appName, elements[connect], "return")
  return true, nil
end

--- Click the control that carries one of `verbs`. It is looked for on the
--- panel first and in the options menu second, because which of the two holds
--- Disconnect depends on the state the agent is in.
local function panelPress(appName, verbs)
  local ok, err = withPanel(appName, function(window)
    local target = findPressable(window, verbs)
    if not target then
      local popup = walk(window, function(element)
        return element:attributeValue("AXRole") == "AXPopUpButton" and element or nil
      end)
      if popup then
        popup:performAction("AXShowMenu")
        for _ = 1, 20 do
          target = findPressable(popup, verbs)
          if target then
            break
          end
          hs.timer.usleep(100000)
        end
        if not target then
          -- Addressed to the agent. Sent to nowhere in particular, this went
          -- to whatever had the keyboard, which by now was somebody's editor.
          hs.eventtap.keyStroke({}, "escape", 0, hs.application.get(appName))
        end
      end
    end
    if not target then
      return nil, ("%s offers no %q right now"):format(appName, verbs[1])
    end
    target:performAction("AXPress")
    return true, nil
  end)
  return ok and true or false, err
end

-- ------------------------------------------------------------------- runtime

--- The adapter the backends are handed. `ifconfig` is read at most once per
--- refresh: every probe wants the same output and it does not change between
--- two profiles a millisecond apart.
function obj:runtime(allowPanelReads)
  local cachedIfconfig
  return {
    exec = function(command)
      local out, ok = hs.execute(command)
      return out, ok
    end,
    ifconfig = function()
      cachedIfconfig = cachedIfconfig or hs.execute("/sbin/ifconfig")
      return cachedIfconfig or ""
    end,
    -- Both families in one string, because `routes.parse` reads rows and does
    -- not care which table they came from.
    routeTable = function()
      local four = hs.execute("/usr/sbin/netstat -rn -f inet") or ""
      local six = hs.execute("/usr/sbin/netstat -rn -f inet6") or ""
      return four .. "\n" .. six
    end,
    panel = function(app)
      if not (allowPanelReads and self.panelReads) then
        return "unknown"
      end
      return keepingFocus(function()
        return panelState(app)
      end)
    end,
    press = function(app, verbs)
      return keepingFocus(function()
        return panelPress(app, verbs)
      end)
    end,
    pressRow = function(app, row, buttonTitle)
      return keepingFocus(function()
        return pressRow(app, row, buttonTitle)
      end)
    end,
    connectRow = function(app, row)
      return keepingFocus(function()
        return connectRow(app, row)
      end)
    end,
  }
end

-- -------------------------------------------------------------- applications

--- Which of the applications the config names are running right now.
---
--- `hs.application.get` is the same lookup every way into these clients already
--- makes — the menu-bar panel and the window are both fetched with it — so this
--- answers the question autoconnect needs answered: would there be anything to
--- click in? Asked once per profile per refresh, and only when autoconnect may
--- act on the answer.
--- @return table { [app] = boolean }
function obj:appsRunning()
  local running = {}
  for _, profile in ipairs(store.list(self.config, true)) do
    if profile.app and running[profile.app] == nil then
      running[profile.app] = hs.application.get(profile.app) ~= nil
    end
  end
  return running
end

--- Where the command line half of vpnbar is, for the one job the Spoon cannot
--- do on its own.
---
--- Deleting a route needs an administrator, and `vpnbar clean` is the tested
--- thing that knows which routes may go. Looked up through a login shell
--- because an application started by launchd has a PATH with no Homebrew in it,
--- and remembered, because the answer does not change while the Spoon is loaded.
function obj:cliPath()
  if self.cli ~= nil then
    return self.cli ~= false and self.cli or nil
  end
  local found = hs.execute("command -v vpnbar", true)
  found = found and found:gsub("%s+$", "") or ""
  self.cli = found ~= "" and found or false
  return self.cli ~= false and self.cli or nil
end

--- Offer to sweep up the routes a dead tunnel left behind, and do it.
---
--- A dialog rather than a notification, because it is a question: it needs an
--- administrator, and the person answering it is the one whose network is
--- broken. Said once per occurrence, with "Not now" meaning a quarter of an
--- hour ([ADR 0035](../../docs/adr/0035-a-dead-tunnels-routes-are-swept-up.md)).
--- @param offer table from `routes.offer`
function obj:offerCleanup(offer)
  -- Marked before the question is put, and cleared by whichever callback
  -- answers it: the refresh that found these routes goes on running while the
  -- dialog is on the screen, and would otherwise ask again every time
  -- (ADR 0038). A throw clears it here, since no callback will.
  self.routeMemory.asking = os.time()
  local ok, err = pcall(function()
    self:askAboutCleanup(offer)
  end)
  if not ok then
    self.routeMemory.asking = nil
    error(err, 0)
  end
end

--- vpnbar's own mark, as a file a dialog can show.
---
--- `hs.dialog` draws Hammerspoon's hammer on everything, which on a question
--- about a route table is an icon from a different program
--- ([ADR 0037](../../docs/adr/0037-a-dialog-that-looks-like-vpnbar.md)). An
--- AppleScript dialog takes a file instead, so the shield is drawn once at a
--- size a dialog wants and kept in the cache directory.
---
--- Filled rather than drawn as the template the menu bar uses: a template is
--- black, and black on the dark appearance of a dialog is nothing at all.
--- @return string|nil path
function obj:markFile()
  if self.mark ~= nil then
    return self.mark ~= false and self.mark or nil
  end
  self.mark = false
  local path = ("%s/Library/Caches/vpnbar/mark.png"):format(os.getenv("HOME") or "")
  ensureDirectory(path)
  local size = 256
  local canvas = hs.canvas.new({ x = 0, y = 0, w = size, h = size })
  if not canvas then
    return nil
  end
  -- The accent blue reads on both appearances, which neither black nor white
  -- does.
  local blue = { red = 0.04, green = 0.52, blue = 1.0, alpha = 1 }
  local inset = hs.canvas.matrix.translate(size * 0.07, size * 0.07)
  canvas:replaceElements({
    {
      type = "segments",
      closed = true,
      coordinates = icon.shield(size * 0.86),
      action = "fill",
      fillColor = blue,
      strokeColor = blue,
      transformation = inset,
    },
    {
      type = "segments",
      closed = false,
      coordinates = icon.tick(size * 0.86),
      action = "stroke",
      strokeColor = { white = 1, alpha = 1 },
      strokeWidth = size / 11,
      strokeCapStyle = "round",
      strokeJoinStyle = "round",
      transformation = inset,
    },
  })
  local image = canvas:imageFromCanvas()
  canvas:delete()
  if image and image:saveToFile(path) then
    self.mark = path
  end
  return self.mark ~= false and self.mark or nil
end

--- Ask a question with vpnbar's own icon on it, and say which button was taken.
--- @return string|nil the button, or nil when the dialog could not be shown
--- Run one AppleScript without holding the run loop, and hand the result on.
---
--- `hs.osascript.applescript` blocks until the script returns, and a dialog
--- returns when somebody clicks it. A question that nobody is at the machine to
--- answer therefore stops every timer in Hammerspoon for as long as it is on
--- the screen: no reads, no menu, no icon
--- ([ADR 0038](../../docs/adr/0038-a-question-that-does-not-block.md)).
--- `osascript` as a task answers on a callback instead.
--- @param script string
--- @param done function called with (ok, output)
local function runScript(script, done)
  local task = hs.task.new("/usr/bin/osascript", function(code, out)
    done(code == 0, (out or ""):gsub("%s+$", ""))
  end, { "-e", script })
  if not task or not task:start() then
    done(false, "osascript would not start")
  end
end

local function appleQuoted(text)
  return '"' .. tostring(text):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

--- Ask a question with vpnbar's own icon on it, and call back with the button.
---
--- The callback gets nil for a dialog somebody dismissed with Escape, which is
--- a no rather than a fault.
function obj:ask(title, message, buttons, default, done)
  local mark = self:markFile()
  if not mark then
    -- No mark, no AppleScript: the blocking dialog with Hammerspoon's hammer on
    -- it is worse-looking and still works.
    return done(hs.dialog.blockAlert(title, message, buttons[2], buttons[1]))
  end
  local script = ("display dialog %s with title %s buttons {%s, %s} default button %s with icon POSIX file %s"):format(
    appleQuoted(message),
    appleQuoted(title),
    appleQuoted(buttons[1]),
    appleQuoted(buttons[2]),
    appleQuoted(default),
    appleQuoted(mark)
  )
  runScript(script, function(ok, out)
    if not ok then
      return done(nil)
    end
    done((out:match("button returned:([^,]*)") or ""):gsub("%s+$", ""))
  end)
end

function obj:askAboutCleanup(offer)
  local cli = self:cliPath()
  if not cli then
    -- Nothing to drive, so nothing to offer. Saying so once is better than a
    -- dialog whose button cannot work.
    self.routeMemory.asking, self.routeMemory.declined = nil, os.time()
    self:complain("routes are left behind, and the vpnbar command line is not on PATH to clean them")
    return
  end
  self:ask(
    "Clean up after a tunnel that is down?",
    routes.explain(offer),
    { "Not now", "Clean up" },
    "Clean up",
    function(answer)
      if answer ~= "Clean up" then
        self.routeMemory.asking, self.routeMemory.declined = nil, os.time()
        return
      end
      -- macOS asks for the password itself, once, and nothing is left behind with
      -- standing privileges: no helper, no sudoers entry, no daemon.
      --
      -- Two quotings, because there are two languages here. The shell sees the
      -- path inside single quotes, so a space or a semicolon in it is a character
      -- rather than a command; AppleScript then sees that whole command as a
      -- double-quoted string, where a backslash and a double quote are what need
      -- escaping.
      local command = backends.shellQuote(cli) .. " clean --yes"
      local template = "do shell script %s with administrator privileges"
        .. ' with prompt "vpnbar is removing %d route(s) that point at a tunnel which is down."'
      local script = template:format(appleQuoted(command), offer.count)
      runScript(script, function(ok, out)
        self.routeMemory.asking = nil
        self.routeMemory.since, self.routeMemory.declined = nil, os.time()
        if not ok then
          -- A cancelled password dialog is a no, not a fault worth a second window.
          self.logger.w("route cleanup did not run: " .. tostring(out))
          return
        end
        self.logger.i(
          ("cleanup: removed %d route(s) left behind by %s"):format(offer.count, table.concat(offer.interfaces, ", "))
        )
        self:refreshSoon(nil, 1)
      end)
    end
  )
end

--- Hand a client back to autoconnect.
---
--- Every path that means "I want this working again" ends here: Connect, Switch
--- to, Restart, switching autoconnect on, and Resume itself. Keyed by
--- application, because that is the unit a quit closed
--- ([ADR 0031](../../docs/adr/0031-autoconnect-does-not-undo-a-quit.md)).
--- @param id string a profile id
function obj:resume(id)
  local profile = store.get(self.config, id)
  local app = profile and profile.app or nil
  if app == nil or not self.quitByHand[app] then
    return
  end
  self.quitByHand[app] = nil
  -- Handed back means tried now. A held connection records no attempts, so what
  -- the memory still holds is whatever failed before the quit, and asking
  -- somebody to wait out a fifteen-minute cooldown they earned before they
  -- closed the client is the delay this whole rule was written to remove.
  --
  -- `succeeded` rather than `forget`, because who started a tunnel is not a
  -- failure record and the supersede rule of
  -- [ADR 0015](../../docs/adr/0015-one-at-a-time-is-a-setting-not-a-rule.md)
  -- turns on it. Every connection through the client, since the quit held all
  -- of them.
  for _, other in ipairs(store.list(self.config, true)) do
    if other.app == app then
      autoconnect.succeeded(self.attempts, other.id)
    end
  end
end

--- Remember that somebody closed a client, so autoconnect stops asking it for
--- anything.
---
--- Taken on the click rather than on the outcome of the kill. `pkill` against an
--- agent with `KeepAlive` set — which is how GlobalProtect is installed — races
--- its own launch agent, so "did it stay closed" is not a question with a stable
--- answer. What somebody asked for is.
--- @param app string|nil
function obj:standDown(app)
  if app then
    self.quitByHand[app] = true
    self.logger.i(("quit: %s is left alone until somebody asks for it"):format(app))
  end
end

-- ---------------------------------------------------------------------- icon

-- Drawn once each and kept: three settled states plus the frames of the busy
-- pulse. The alternative is a canvas per refresh — a new bitmap every ten
-- seconds, and one every third of a second while the mark is moving, for a
-- picture with a handful of possible values.
local iconCache = {}

local function menubarIcon(state, phase)
  local key = state .. "/" .. icon.frame(phase)
  if iconCache[key] then
    return iconCache[key]
  end
  local canvas = hs.canvas.new({ x = 0, y = 0, w = icon.SIZE, h = icon.SIZE })
  if not canvas then
    return nil
  end
  canvas:replaceElements(icon.elements(state, icon.SIZE, phase))
  local image = canvas:imageFromCanvas()
  canvas:delete()
  if image then
    -- A template image is tinted by macOS: white on a dark menu bar, black on
    -- a light one, inverted again while the menu is open. Anything drawn in a
    -- colour of its own would be right in one of those and wrong in the others.
    image = image:template(true)
    iconCache[key] = image
  end
  return image
end

--- Put the current state in the menu bar.
---
--- The only place that touches the icon. The mark depends on two things now —
--- what was last read, and whether a job is running — and two places deciding
--- that would drift apart within a release.
function obj:paint()
  if not self.menubar then
    return
  end
  local busy = work.busy(self.work, os.time())
  local state = menu.indicator(self.states, busy)
  local image = menubarIcon(state, self.phase)
  if image then
    self.menubar:setIcon(image)
    -- The count sits beside the icon only when it says something: one tunnel
    -- up is the normal case and the icon already reports it.
    local connected = menu.connectedCount(self.states)
    self.menubar:setTitle(connected > 1 and tostring(connected) or "")
  else
    self.menubar:setTitle(menu.title(self.states, busy))
  end
  self:pulsate(state == "connecting")
end

--- Run the pulse while there is something to pulse about, and not a moment
--- longer. A timer redrawing a settled icon three times a second is a timer
--- that turns up in a battery report.
--- @param wanted boolean
function obj:pulsate(wanted)
  if wanted and not self.pulse then
    self.pulse = hs.timer.doEvery(0.3, function()
      self.phase = (self.phase or 1) + 1
      self:paint()
    end)
  elseif not wanted and self.pulse then
    self.pulse:stop()
    self.pulse = nil
    self.phase = 1
  end
end

--- Read the state, but let the menu bar draw first.
---
--- Everything a refresh does is synchronous — `ifconfig`, a shell helper,
--- sometimes an accessibility tree that sleeps waiting for a window. Called
--- inline at start-up or on a wake, the icon appears only once all of that is
--- over, which is the lag this removes: claim the mark, hand the run loop back
--- so it gets drawn, then read.
---
--- `pcall`, so a read that throws still releases the mark. The deadline in
--- `work` is the backstop for everything that manages to escape even that.
--- @param options table|nil passed to `refresh`
--- @param delay number|nil seconds, default none
function obj:refreshSoon(options, delay)
  work.begin(self.work, os.time())
  self:paint()
  hs.timer.doAfter(delay or 0, function()
    if not self.running then
      -- Quit while this was waiting. A read after that would run commands for a
      -- menu that is no longer there, and the wake schedule queues three of them
      -- at a time.
      work.finish(self.work)
      return
    end
    local ok, err = pcall(self.refresh, self, options)
    work.finish(self.work)
    self:paint()
    if not ok then
      self.logger.e("refresh failed: " .. tostring(err))
    end
  end)
end

-- --------------------------------------------------------------------- state

--- Read every connection's state, and optionally act on it.
---
--- @param options table|nil
---   panelReads: allow a state read that puts a panel on screen
---   autoconnect: allow autoconnect to start or stop something
function obj:refresh(options)
  options = options or {}
  local runtime = self:runtime(options.panelReads == true)
  local states = {}
  for _, profile in ipairs(store.list(self.config, true)) do
    states[profile.id] = backends.status(profile, runtime)
  end
  -- A tunnel that has just arrived was not being left alone by anybody: whoever
  -- brought it up, the quit that held it has been overtaken by events. Which
  -- readings count as an arrival is `autoconnect.arrived`, not this loop.
  for _, profile in ipairs(store.list(self.config, true)) do
    if profile.app and autoconnect.arrived((self.states or {})[profile.id], states[profile.id]) then
      self.quitByHand[profile.app] = nil
    end
  end
  -- When each connection began its handshake. Cleared the moment it says
  -- anything else, so this is the age of the current `connecting` and not of
  -- the last one (ADR 0036).
  for _, profile in ipairs(store.list(self.config, true)) do
    if states[profile.id] == "connecting" then
      self.connectingSince[profile.id] = self.connectingSince[profile.id] or os.time()
    else
      self.connectingSince[profile.id] = nil
    end
  end
  self.states = states

  -- Routes a tunnel left behind when it died without disconnecting. Asked only
  -- when `ifconfig`, which was read for the probes anyway, says some tunnel is
  -- down: on a machine where everything is up there is no route table to read
  -- ([ADR 0035](../../docs/adr/0035-a-dead-tunnels-routes-are-swept-up.md)).
  -- The route table is read every time rather than only when `ifconfig` shows a
  -- tunnel that is down, because the worst case is a tunnel that is not in
  -- `ifconfig` at all: destroyed, with its routes still installed. A guard that
  -- asked `ifconfig` first could not see that one. Measured at 30 ms for both
  -- families, against a refresh that already runs several commands.
  local interfaces = require("vpnbar.parse").ifconfigInterfaces(runtime.ifconfig())
  local stranded, names = routes.stranded(routes.parse(runtime.routeTable()), interfaces)
  local offer = routes.offer(stranded, names, self.routeMemory, os.time())

  -- At most one connection is started per refresh, and only from this one
  -- place. The policy — cooldown, how many tries before the fallback, when to
  -- give up — is all in vpnbar/autoconnect.lua and under test there.
  --
  -- Only when the caller allows it, which the timer and a wake do and opening
  -- the menu does not. Otherwise looking at the menu would start a VPN: the
  -- awsvpn backend brings a window up and clicks it, and having that happen
  -- because somebody wanted to read a status is not acceptable.
  -- What this read knows about the person, for the one kind of connect that
  -- needs one: a connection whose session has ended. Everything else is silent
  -- and is never held.
  --
  -- `idleTime` asks IOKit and raises when it cannot; a refresh must not die on
  -- that, and nil is the answer that means "go ahead". `fresh` is the window
  -- after a wake or an unlock, spent by the first login-needing connect made in
  -- it, so the second connection does not get the exemption ten seconds after
  -- the first used it. `locked` is nobody there, whatever the idle time says.
  local context
  if options.autoconnect then
    local measured, seconds = pcall(hs.host.idleTime)
    context = {
      idle = measured and seconds or nil,
      fresh = work.withinFreshStart(self.lastFreshStart, os.time()) and not self.freshSpent,
      locked = self:screenLocked(),
      preferred = self.preferred,
      -- The two reasons a client is off limits: it is not running, so there is
      -- nothing to click in, or somebody closed it and that stands (ADR 0031).
      appRunning = self:appsRunning(),
      quitByHand = self.quitByHand,
      connectingSince = self.connectingSince,
    }
  end
  local plan = options.autoconnect and autoconnect.plan(self.config, states, self.attempts, os.time(), context) or nil
  if plan then
    local profile = store.get(self.config, plan.id)
    self.logger.i(("autoconnect: %s %s (%s)"):format(plan.verb, plan.id, plan.reason))
    if plan.verb == "connect" then
      autoconnect.remember(self.attempts, plan.id, os.time())
      if context.fresh and states[plan.id] == "login" then
        self.freshSpent = true
      end
    else
      -- Taking the stand-in back down ends its history: it is not a failure,
      -- and the next time it is needed it should start from nothing.
      autoconnect.forget(self.attempts, plan.id)
    end
    if profile then
      local ok, err = backends.act(profile, plan.verb, runtime, self.config)
      if not ok then
        -- On the console rather than as a notification: this runs on a timer,
        -- and a press that found no panel is worth a line, not a banner. It
        -- used to be discarded, and an evening of twenty presses left no
        -- trace of what any of them met.
        self.logger.w(("autoconnect: %s %s failed: %s"):format(plan.verb, plan.id, tostring(err)))
      end
    end
  end

  self:paint()

  -- Last, and after the icon is right: the dialog blocks, and a question about
  -- a dead tunnel must not hold up the reading that found it.
  if offer then
    hs.timer.doAfter(0, function()
      if self.running then
        self:offerCleanup(offer)
      end
    end)
  end
  return states
end

-- ------------------------------------------------------------------- actions

--- Ask for one line of text. Returns nil when the user cancels, which every
--- caller treats as "change nothing".
local function ask(message, informative, default)
  local button, text = hs.dialog.textPrompt(message, informative, default or "", "OK", "Cancel")
  if button ~= "OK" then
    return nil
  end
  return text
end

function obj:apply(config, err)
  if not config then
    self:complain(err or "the change was rejected")
    return false
  end
  return self:save(config)
end

--- Walk the fields for a backend, one prompt at a time, and hand back the
--- profile they describe. Returns nil when the user cancels, which every
--- caller treats as "change nothing".
---
--- This replaced a single dialog holding the whole profile as JSON. A one-line
--- text field cannot show a JSON object, so the thing being edited was mostly
--- off-screen — an excellent way to lose a working config to a typo nobody
--- could see.
--- @param backend string
--- @param base table|nil the profile being edited
--- @return table|nil profile, string|nil err
local function runForm(backend, base)
  local answers = form.defaults(backend, base)
  for _, field in ipairs(form.fields(backend)) do
    if form.applies(field, answers) then
      local text = ask(field.label, field.informative, answers[field.key])
      if text == nil then
        return nil, nil
      end
      answers[field.key] = text
    else
      -- Not asked, so not kept: a probe interface without a probe is a setting
      -- that does nothing and would confuse the next person to read the file.
      answers[field.key] = ""
    end
  end
  return form.build(backend, answers, base)
end

function obj:addProfile(backend)
  local profile, err = runForm(backend, nil)
  if not profile then
    if err then
      self:complain(err)
    end
    return
  end
  profile.id = store.freeId(self.config, profile.name)
  if self:apply(store.add(self.config, profile)) then
    self:refresh()
  end
end

function obj:editProfile(id)
  local existing = store.get(self.config, id)
  if not existing then
    return
  end
  local profile, err = runForm(existing.backend, existing)
  if not profile then
    if err then
      self:complain(err)
    end
    return
  end
  -- Replaced rather than merged: what came back is the whole profile, and a
  -- field the user emptied is a field they meant to empty.
  local without, removeErr = store.remove(self.config, id)
  if not without then
    self:complain(removeErr)
    return
  end
  local added, addErr = store.add(without, profile)
  if self:apply(added, addErr) then
    self:refresh()
  end
end

function obj:removeProfile(id)
  local profile = store.get(self.config, id)
  if not profile then
    return
  end
  if
    hs.dialog.blockAlert(
      "Remove " .. profile.name .. "?",
      "It is only removed from this menu. Nothing is uninstalled and no system setting is touched.",
      "Remove",
      "Cancel"
    ) ~= "Remove"
  then
    return
  end
  if self:apply(store.remove(self.config, id)) then
    -- Only now: cleared before the dialog, a Cancel would have dropped the
    -- preference and let the planner take the switched-to tunnel down.
    if self.preferred == id then
      self.preferred = nil
    end
    self:refresh()
  end
end

function obj:importFromScutil()
  local parse = require("vpnbar.parse")
  local services = parse.scutilList(hs.execute("/usr/sbin/scutil --nc list"))
  local config, added = store.import(self.config, services)
  if #added == 0 then
    hs.alert.show("Nothing new — every service is already in the menu")
    return
  end
  if self:apply(config) then
    hs.alert.show(("Added %d connection%s"):format(#added, #added == 1 and "" or "s"))
    self:refresh()
  end
end

function obj:act(id, verb)
  local profile = store.get(self.config, id)
  if not profile then
    return
  end
  -- Under the mark from the click to the state that comes back, because the
  -- gap between the two is where this used to look broken: connecting the AWS
  -- client means bringing its window up and pressing a row in it, several
  -- seconds during which the old icon said whatever it said before.
  --
  -- Deferred for the same reason `refreshSoon` is — the pressing blocks, so an
  -- icon set just before it would not reach the screen until it was over.
  work.begin(self.work, os.time())
  self:paint()
  hs.timer.doAfter(0, function()
    if not self.running then
      work.finish(self.work)
      return
    end
    local called, ok, err = pcall(backends.act, profile, verb, self:runtime(true), self.config)
    if not called then
      self:complain(("%s: %s"):format(profile.name, tostring(ok)))
    elseif not ok then
      self:complain(("%s: %s"):format(profile.name, err or "the command failed"))
    end
    -- The agent needs a moment before its state is worth reading again. Queued
    -- before this job is released, so the mark stays up across the two rather
    -- than blinking off in between.
    self:refreshSoon(nil, 2)
    work.finish(self.work)
  end)
end

--- Prefer one connection for this session, and connect it now.
---
--- The preference is what makes this a switch rather than a Connect: with *Only
--- one connection at a time* on, the planner takes the other tunnel down once
--- this one is up, and keeps this one up from here on. The order in the menu is
--- not touched, and a restart forgets the preference
--- ([ADR 0030](../../docs/adr/0030-a-switch-is-a-preference-not-an-order.md)).
---
--- The connect is made here rather than left to the planner, because this is a
--- person clicking: nothing about idle time or a login window applies. Its
--- failures are forgotten first, so a backoff earned while it was the stand-in
--- does not make the switch wait.
function obj:switchTo(id)
  if not store.get(self.config, id) then
    return
  end
  self.preferred = id
  -- A person asking for this connection is a person asking for its client, which
  -- is the one thing that lifts a quit.
  self:resume(id)
  autoconnect.forget(self.attempts, id)
  self.logger.i(("switch: %s is preferred until restart"):format(id))
  local state = self.states[id]
  if state == "connected" or state == "connecting" then
    -- Already up: nothing to connect, only the other one to take down, which
    -- is the planner's job on its next pass.
    self:refreshSoon({ autoconnect = true }, 0)
    return
  end
  self:act(id, "connect")
  -- Remembered as an attempt so the planner does not press Connect a second
  -- time while this one is still on its way; the planner's next pass is what
  -- takes the other tunnel down once this one is up, and it is asked for
  -- sooner than the timer would.
  autoconnect.remember(self.attempts, id, os.time())
  self:refreshSoon({ autoconnect = true }, 6)
end

--- Restart the service behind a client, which is the repair for one whose own
--- service has stopped answering it.
---
--- Confirmed first, because it takes the connection down on the way. In the
--- `gui` domain it needs nothing; in `system` it asks macOS for an
--- administrator, the same one prompt the route cleanup uses and nothing left
--- behind ([ADR 0039](../../docs/adr/0039-putting-a-service-back-on-its-feet.md)).
function obj:repairService(id)
  local profile = store.get(self.config, id)
  local service = profile and backends.serviceOf(profile)
  if not service then
    return
  end
  local app = profile.app or profile.name
  local admin = backends.serviceNeedsAdmin(service)
  local question = ("Restart the service behind %s?"):format(app)
  local message = "This is the repair for a client whose own service has stopped answering it:"
    .. " the agent asks for a connection and the service never hears."
    .. " The connection goes down and comes back."
    .. (admin and " It asks for an administrator." or "")
  self:ask(question, message, { "Cancel", "Restart it" }, "Restart it", function(answer)
    if answer ~= "Restart it" then
      return
    end
    local command = backends.kickstartCommand(service)
    -- Handing the client back to autoconnect belongs after the restart, not
    -- before it: a `launchctl` that failed, or an administrator prompt somebody
    -- cancelled, would otherwise have lifted a quit that still stands
    -- ([ADR 0031](../../docs/adr/0031-autoconnect-does-not-undo-a-quit.md)).
    if not admin then
      local _, ok = hs.execute(command)
      if not ok then
        self:complain(("%s: the service would not restart"):format(profile.name))
        return
      end
      self:resume(id)
      self.logger.i(("repair: restarted %s"):format(service.label))
      self:refreshSoon(nil, 3)
      return
    end
    local template = "do shell script %s with administrator privileges"
      .. ' with prompt "vpnbar is restarting the service behind %s."'
    runScript(template:format(appleQuoted(command), app), function(started, out)
      if not started then
        self.logger.w("service restart did not run: " .. tostring(out))
        return
      end
      self:resume(id)
      self.logger.i(("repair: restarted %s"):format(service.label))
      self:refreshSoon(nil, 3)
    end)
  end)
end

--- Take down everything the menu just said it would take down.
---
--- The list comes from `menu.disconnectAll`, the same call the menu item used to
--- name them, so the confirmation and what happens cannot disagree. Protected
--- connections are not in it and are not asked about.
function obj:disconnectAll()
  local plan = menu.disconnectAll(self.config, self.states)
  if #plan == 0 then
    return
  end
  local names = {}
  for _, entry in ipairs(plan) do
    names[#names + 1] = entry.name
  end
  if
    hs.dialog.blockAlert(
      ("Disconnect %d connection%s?"):format(#plan, #plan == 1 and "" or "s"),
      table.concat(names, ", ") .. ". Protected connections are left alone.",
      "Disconnect",
      "Cancel"
    ) ~= "Disconnect"
  then
    return
  end
  -- One mark for the whole run rather than one per connection: a `force` waits
  -- on a management interface and then on an app quitting, so this is seconds of
  -- work, and it is all the same click.
  work.begin(self.work, os.time())
  self:paint()
  hs.timer.doAfter(0, function()
    if not self.running then
      work.finish(self.work)
      return
    end
    local runtime = self:runtime(true)
    for _, entry in ipairs(plan) do
      local profile = store.get(self.config, entry.id)
      if profile then
        local called, ok, err = pcall(backends.act, profile, entry.verb, runtime, self.config)
        if not called then
          self:complain(("%s: %s"):format(entry.name, tostring(ok)))
        elseif not ok then
          -- Reported and carried on. One connection refusing to close is no
          -- reason to leave the others up.
          self:complain(("%s: %s"):format(entry.name, err or "the command failed"))
        end
      end
    end
    self:refreshSoon(nil, 2)
    work.finish(self.work)
  end)
end

--- Is the screen locked right now?
---
--- Two sources, because each has a hole. The lock and unlock events are what
--- keep `self.locked` current, and on this machine they are reliable — the lock
--- fires a second after `systemWillSleep`, so a Mac that sleeps unlocked wakes
--- with the flag already set. But a Spoon loaded or restarted while the screen
--- is locked has never seen an event, and would read the screen as unlocked
--- until the next lock. For that case only, the session properties are asked:
--- they carry `CGSSessionScreenIsLocked` while the screen is locked and not
--- otherwise, both measured here. Only for that case, because once an event
--- has been seen the events are the authority, and a dictionary that lagged an
--- unlock by a moment must not be able to overrule the unlock.
--- @return boolean
function obj:screenLocked()
  if self.locked ~= nil then
    return self.locked == true
  end
  local ok, props = pcall(hs.caffeinate.sessionProperties)
  return ok and type(props) == "table" and props.CGSSessionScreenIsLocked == true
end

--- Quit or restart the application behind one connection, having asked first.
---
--- What the dialog promises depends on the backend. Closing GlobalProtect closes
--- a user interface and its tunnel is held elsewhere; closing the AWS client
--- ends the session. `backends.canQuit` has already kept the second case away
--- from a protected connection, so the wording here only has to be honest about
--- which of the two this is.
--- @param id string
--- @param verb string "quit" or "restart"
function obj:controlApp(id, verb)
  local profile = store.get(self.config, id)
  if not profile then
    return
  end
  local app = profile.app or profile.name
  local backend = backends.byName[profile.backend]
  local owns = backend ~= nil and backend.appOwnsTunnel == true
  local consequence = owns and " This client is its own tunnel, so the connection goes down with it."
    or " Its tunnel is held by a service of its own rather than by this app, so it is not a disconnect."
  -- What happens next, which for a quit is now the opposite of what this used to
  -- promise: autoconnect stops asking rather than bringing the connection back.
  -- A quit is a decision (ADR 0031), and the dialog is where it has to be said.
  local safety = " Autoconnect leaves this client's connections alone afterwards, until you connect one again."
  if verb ~= "quit" then
    if owns then
      -- Measured on GlobalProtect: the agent exits, the tunnel drops and the
      -- gateway logs the session out, so what comes back is a client asking to
      -- log in rather than a tunnel ([ADR 0033]).
      safety = " It comes back when the client has started again, which may ask you to log in."
    else
      safety = profile.autoconnect and " If the connection does drop after all, autoconnect brings it back." or ""
    end
  end
  local button = verb == "quit" and "Quit" or "Restart"
  local question = verb == "quit" and ("Quit %s?"):format(app) or ("Restart %s?"):format(app)
  local what = verb == "quit" and ("%s closes and stays closed."):format(app)
    or ("%s closes and opens again."):format(app)
  if hs.dialog.blockAlert(question, what .. consequence .. safety, button, "Cancel") ~= button then
    return
  end
  if verb == "quit" then
    self:standDown(profile.app)
  else
    -- A restart is asked for to make a client work again, so it is the other
    -- half of the same decision.
    self:resume(id)
  end
  self:act(id, verb)
end

--- Close every VPN application the menu is allowed to close.
---
--- One pass over `menu.quitApps`, which is the same list the row named, so the
--- confirmation cannot promise a different set from the one that closes.
function obj:quitAllApps()
  local apps = menu.quitApps(self.config)
  if #apps == 0 then
    return
  end
  local names = {}
  for _, entry in ipairs(apps) do
    names[#names + 1] = entry.app
  end
  if
    hs.dialog.blockAlert(
      ("Quit %d VPN app%s?"):format(#apps, #apps == 1 and "" or "s"),
      table.concat(names, ", ")
        .. ". They close and stay closed. A client that holds its own tunnel takes the connection with it. "
        .. "Autoconnect leaves their connections alone afterwards, until you connect one again.",
      "Quit",
      "Cancel"
    ) ~= "Quit"
  then
    return
  end
  for _, entry in ipairs(apps) do
    self:standDown(entry.app)
  end
  work.begin(self.work, os.time())
  self:paint()
  hs.timer.doAfter(0, function()
    if not self.running then
      work.finish(self.work)
      return
    end
    local runtime = self:runtime(true)
    for _, entry in ipairs(apps) do
      local profile = store.get(self.config, entry.id)
      if profile then
        local called, ok, err = pcall(backends.act, profile, "quit", runtime, self.config)
        if not called then
          self:complain(("%s: %s"):format(entry.app, tostring(ok)))
        elseif not ok then
          self:complain(("%s: %s"):format(entry.app, err or "could not close it"))
        end
      end
    end
    self:refreshSoon(nil, 2)
    work.finish(self.work)
  end)
end

function obj:dispatch(action)
  local kinds = {
    connect = function()
      -- Somebody asking for a connection is somebody asking for its client back.
      self:resume(action.id)
      self:act(action.id, "connect")
    end,
    resume = function()
      self:resume(action.id)
      -- Asked for straight away rather than waiting for the timer: the row was
      -- clicked to make something happen.
      self:refreshSoon({ autoconnect = true }, 0)
    end,
    disconnect = function()
      self:act(action.id, "disconnect")
    end,
    add = function()
      self:addProfile(action.backend)
    end,
    edit = function()
      self:editProfile(action.id)
    end,
    switch = function()
      self:switchTo(action.id)
    end,
    remove = function()
      self:removeProfile(action.id)
    end,
    rename = function()
      local profile = store.get(self.config, action.id)
      local name = profile and ask("Rename " .. profile.name, "The name shown in the menu.", profile.name)
      if name and self:apply(store.update(self.config, action.id, { name = name })) then
        self:refresh()
      end
    end,
    move = function()
      self:apply(store.move(self.config, action.id, action.delta))
    end,
    toggleHidden = function()
      local profile = store.get(self.config, action.id)
      if profile and self:apply(store.update(self.config, action.id, { hidden = not profile.hidden })) then
        self:refresh()
      end
    end,
    force = function()
      self:act(action.id, "force")
    end,
    disconnectAll = function()
      self:disconnectAll()
    end,
    restart = function()
      self:controlApp(action.id, "restart")
    end,
    quitApp = function()
      self:controlApp(action.id, "quit")
    end,
    quitAllApps = function()
      self:quitAllApps()
    end,
    repair = function()
      self:repairService(action.id)
    end,
    toggleAutoconnect = function()
      local profile = store.get(self.config, action.id)
      if profile and self:apply(store.update(self.config, action.id, { autoconnect = not profile.autoconnect })) then
        -- A connection just switched on should be tried now, not after
        -- whatever its previous failures had earned it.
        autoconnect.forget(self.attempts, action.id)
        if not profile.autoconnect then
          -- It was off, so this click asked for the connection to come up by
          -- itself. A quit still standing would go on quietly denying that.
          self:resume(action.id)
        end
        self:refresh()
      end
    end,
    toggleSetting = function()
      local settings = store.settings(self.config)
      local updated, err = store.setSettings(self.config, { [action.setting] = not settings[action.setting] })
      if self:apply(updated, err) then
        -- Both settings change what autoconnect is allowed to do, so its
        -- history of failures under the old rules is no longer worth keeping.
        autoconnect.forget(self.attempts)
        self:refresh()
      end
    end,
    toggleProtected = function()
      local profile = store.get(self.config, action.id)
      if profile and self:apply(store.update(self.config, action.id, { protected = not profile.protected })) then
        self:refresh()
      end
    end,
    import = function()
      self:importFromScutil()
    end,
    reveal = function()
      ensureDirectory(self.configPath)
      if not io.open(self.configPath, "r") then
        self:save(self.config)
      end
      hs.execute(("/usr/bin/open -t %s"):format(backends.shellQuote(self.configPath)))
    end,
    reload = function()
      self:load()
      self:refresh()
    end,
    refresh = function()
      -- Explicitly asked for, so a panel read is fair; still no autoconnect,
      -- because what was asked for is a look and not a change. A panel read
      -- opens a window and waits for it, so this is the one refresh that is
      -- always worth marking as work.
      self:refreshSoon({ panelReads = true })
    end,
    quit = function()
      -- Confirmed, because the way back is a Hammerspoon reload and that is not
      -- something a menu which has just vanished can tell you.
      local answer = hs.dialog.blockAlert(
        "Quit vpnbar?",
        "The icon leaves the menu bar and nothing is watched any more. "
          .. "No connection is closed. Reload Hammerspoon to bring it back.",
        "Quit",
        "Cancel"
      )
      if answer == "Quit" then
        self:stop()
      end
    end,
  }
  local handler = kinds[action.kind]
  if handler then
    handler()
  end
end

-- ---------------------------------------------------------------------- menu

function obj:hammerspoonMenu(items)
  local out = {}
  for _, item in ipairs(items) do
    if item.separator then
      -- Collapse a run of them, and never open with one. Items that appear
      -- conditionally leave separators behind when they are absent, and two
      -- lines with nothing between them read as a bug.
      if #out > 0 and out[#out].title ~= "-" then
        out[#out + 1] = { title = "-" }
      end
    else
      local entry = {
        title = item.title,
        disabled = item.disabled or false,
        tooltip = item.tooltip,
        checked = item.checked,
      }
      if item.menu then
        entry.menu = self:hammerspoonMenu(item.menu)
      elseif item.action then
        local action = item.action
        entry.fn = function()
          self:dispatch(action)
        end
      end
      out[#out + 1] = entry
    end
  end
  return out
end

-- ---------------------------------------------------------------- life cycle

function obj:init()
  self.states = {}
  self.config = store.empty()
  -- What autoconnect has already tried, and when. Owned here, reasoned about
  -- in vpnbar/autoconnect.lua.
  self.attempts = {}
  -- The id somebody switched to, for this session. Not in the config, and not
  -- persisted, on purpose: the order is the lasting preference, a switch is
  -- about this afternoon (ADR 0030).
  self.preferred = nil
  -- The applications somebody closed from this menu, keyed by name. Not
  -- persisted, for the same reason `preferred` is not: it is a decision about
  -- now, and a restart of the Spoon is a fresh start for both (ADR 0031).
  self.quitByHand = {}
  -- When routes left behind were first seen, and when somebody last said no to
  -- clearing them up (ADR 0035). Not persisted: a reboot is one of the things
  -- that clears them.
  self.routeMemory = {}
  -- When each connection started saying `connecting`, so a handshake that never
  -- finishes can be told from one that is still going
  -- (ADR 0036). Not persisted: a restart is a fresh handshake.
  self.connectingSince = {}
  -- What is running, so the mark can say so. Owned here, reasoned about in
  -- vpnbar/work.lua.
  self.work = work.new()
  self.phase = 1
  self.running = false
  return self
end

function obj:start()
  -- Starting twice used to leave the first timer and the first wake watcher
  -- running: the fields were overwritten, the objects were not stopped, and
  -- Hammerspoon went on firing both. Two timers means two reads and two
  -- autoconnect attempts per interval, each unaware of the other. `stop` is the
  -- one place that takes everything down, so starting goes through it rather
  -- than trying to remember the list a second time.
  if self.running then
    self:stop()
  end
  self.running = true
  self:load()
  -- The second argument is an autosave name. Without one, macOS gives the
  -- status item a fresh identity on every reload and cannot restore its
  -- position.
  --
  -- It is only half the story of why this icon kept vanishing, and the smaller
  -- half. Bartender addresses items as `<bundle-id>-Item-<n>` — by *ordinal*,
  -- not by identity — so with Hammerspoon owning two status items, which one
  -- is Item-0 depends on which was created first. Its rules then land on
  -- whichever happened to be there. Nothing this Spoon can set changes that;
  -- see docs/adr/0016-the-menu-bar-item-has-a-name.md.
  self.menubar = self.menubar or hs.menubar.new(true, "vpnbar")
  self.menubar:setMenu(function()
    -- The config is re-read on every open, so an edit by hand shows up without
    -- a reload. The states are not: they come from the last read, and a fresh
    -- one is queued behind the menu instead of in front of it.
    --
    -- Reading here is what made the menu itself feel slow — the click waited on
    -- `ifconfig` and a shell helper before a single row appeared. The timer
    -- keeps this at most `interval` old, Refresh now is there for the impatient,
    -- and the queued read has the icon right by the time the menu closes.
    self:load()
    self:refreshSoon()
    return self:hammerspoonMenu(menu.build(self.config, self.states, self.preferred, self.quitByHand))
  end)
  -- Deferred, so the icon is in the bar before anything is read. Hammerspoon
  -- loads this Spoon while it is still starting up, and a synchronous first
  -- read there is a gap between login and an icon with nothing on screen to
  -- explain it.
  self:refreshSoon({ autoconnect = true })

  self.timer = hs.timer.doEvery(self.interval, function()
    -- Not `refreshSoon`: the timer's reads are cheap and unattended, and
    -- flashing the busy mark every ten seconds would spend the one signal that
    -- is supposed to mean something.
    self:refresh({ autoconnect = true })
  end)
  -- A tunnel does not survive sleep, and the title should not claim otherwise.
  -- An unlock counts for the same reason: a Mac that has been sitting locked
  -- has had no chance to notice the network change in front of it, and the
  -- person who just typed their password is about to want a VPN.
  self.wake = hs.caffeinate.watcher.new(function(event)
    local watcher = hs.caffeinate.watcher
    -- A locked screen is nobody there. Silent reconnects go on as before; the
    -- one thing held is a connect that would put a login window in front of an
    -- empty chair, and the unlock below is what lets it through.
    if event == watcher.screensDidLock then
      self.locked = true
      return
    end
    if event ~= watcher.systemDidWake and event ~= watcher.screensDidUnlock then
      return
    end
    local now = os.time()
    -- Waking a locked Mac fires both, so the second one is the same arrival.
    local arrival = work.freshStart(self.lastFreshStart, now)
    if event == watcher.screensDidUnlock then
      self.locked = false
      -- The arrival window reopens on every unlock, debounced or not. The
      -- debounce exists to stop a second `forget` and a second read schedule;
      -- it must not deny the person who typed a password sixteen seconds
      -- after the wake the one login window they came for, when the read
      -- fifteen seconds after the wake had held it for a locked screen.
      self.lastFreshStart = now
      self.freshSpent = false
    end
    if not arrival then
      -- One read of its own, so the window is used before it closes. Left to
      -- the timer, that only worked because the interval is shorter than the
      -- window, and nothing pins the two together.
      if event == watcher.screensDidUnlock then
        self:refreshSoon({ autoconnect = true }, 2)
      end
      return
    end
    self.lastFreshStart = now
    self.freshSpent = false
    -- Failures from before the lid closed say nothing about the network on
    -- the other side of it, so autoconnect starts again from nothing.
    autoconnect.forget(self.attempts)
    -- Several looks over the first quarter minute rather than one at the
    -- instant of the wake, when there is no route yet — see work.WAKE_READS.
    -- All of them are claimed now, which is what keeps the mark moving from
    -- the moment the screen comes back until the state has settled.
    -- Which of these may put a login window on screen is decided in `refresh`
    -- from `lastFreshStart`, so the whole window after the arrival counts and
    -- not one read of it.
    for _, read in ipairs(work.WAKE_READS) do
      self:refreshSoon({ autoconnect = read.autoconnect == true }, read.after)
    end
  end)
  self.wake:start()
  return self
end

function obj:stop()
  self.running = false
  if self.timer then
    self.timer:stop()
    self.timer = nil
  end
  if self.pulse then
    self.pulse:stop()
    self.pulse = nil
  end
  if self.wake then
    self.wake:stop()
    self.wake = nil
  end
  -- Anything already queued finds the mark idle and no menu bar to paint, which
  -- is what stops a read in flight from bringing the icon back.
  self.work = work.new()
  self.phase = 1
  if self.menubar then
    self.menubar:delete()
    self.menubar = nil
  end
  return self
end

return obj
