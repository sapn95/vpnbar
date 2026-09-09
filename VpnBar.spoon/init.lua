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

--- Depth-first walk, calling `visit` on every element. Bounded, because an
--- accessibility tree with a cycle in it would otherwise hang Hammerspoon.
local function walk(element, visit, depth)
  depth = depth or 0
  if depth > 8 or not element then
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
local function windowOf(appName)
  local app = hs.application.get(appName)
  if not app then
    return nil, appName .. " is not running"
  end
  local element = hs.axuielement.applicationElement(app)
  local window = (element:attributeValue("AXWindows") or {})[1]
  if window then
    return window, nil
  end
  hs.execute("/usr/bin/open -a " .. backends.shellQuote(appName))
  for _ = 1, 25 do
    window = (element:attributeValue("AXWindows") or {})[1]
    if window then
      return window, nil
    end
    hs.timer.usleep(200000)
  end
  return nil, appName .. " has no window to click in"
end

--- Press a button on the row belonging to one name.
---
--- The tree runs name, state, button per row, so: walk it in order, remember
--- when the name matches, and take the first button of the right title within
--- the few elements that follow. Bounded on purpose — a row that does not
--- offer the button being asked for must not reach into the next row and click
--- that one instead.
---
--- Done here rather than in the shell helper because System Events cannot read
--- this app: `entire contents of window 1` comes back empty while the window
--- plainly has ten children, and it fails silently.
local function pressRow(appName, row, buttonTitle)
  local window, err = windowOf(appName)
  if not window then
    return false, err
  end
  local matched, since = false, 0
  local target = walk(window, function(element)
    local role = element:attributeValue("AXRole")
    if role == "AXStaticText" then
      if element:attributeValue("AXValue") == row then
        matched, since = true, 0
        return nil
      end
    elseif role == "AXButton" and matched and since <= 4 then
      if element:attributeValue("AXTitle") == buttonTitle then
        return element
      end
    end
    if matched then
      since = since + 1
    end
    return nil
  end)
  if not target then
    return false, ("%s offers no %s on a row called %s"):format(appName, buttonTitle, tostring(row))
  end
  target:performAction("AXPress")
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
          hs.eventtap.keyStroke({}, "escape", 0)
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
    panel = function(app)
      if not (allowPanelReads and self.panelReads) then
        return "unknown"
      end
      return panelState(app)
    end,
    press = function(app, verbs)
      return panelPress(app, verbs)
    end,
    pressRow = function(app, row, buttonTitle)
      return pressRow(app, row, buttonTitle)
    end,
  }
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
  self.states = states

  -- At most one connection is started per refresh, and only from this one
  -- place. The policy — cooldown, how many tries before the fallback, when to
  -- give up — is all in vpnbar/autoconnect.lua and under test there.
  --
  -- Only when the caller allows it, which the timer and a wake do and opening
  -- the menu does not. Otherwise looking at the menu would start a VPN: the
  -- awsvpn backend brings a window up and clicks it, and having that happen
  -- because somebody wanted to read a status is not acceptable.
  local plan = options.autoconnect and autoconnect.plan(self.config, states, self.attempts, os.time()) or nil
  if plan then
    local profile = store.get(self.config, plan.id)
    self.logger.i(("autoconnect: %s %s (%s)"):format(plan.verb, plan.id, plan.reason))
    if plan.verb == "connect" then
      autoconnect.remember(self.attempts, plan.id, os.time())
    else
      -- Taking the stand-in back down ends its history: it is not a failure,
      -- and the next time it is needed it should start from nothing.
      autoconnect.forget(self.attempts, plan.id)
    end
    if profile then
      backends.act(profile, plan.verb, runtime)
    end
  end

  self:paint()
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
    local called, ok, err = pcall(backends.act, profile, verb, self:runtime(true))
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

function obj:dispatch(action)
  local kinds = {
    connect = function()
      self:act(action.id, "connect")
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
    toggleAutoconnect = function()
      local profile = store.get(self.config, action.id)
      if profile and self:apply(store.update(self.config, action.id, { autoconnect = not profile.autoconnect })) then
        -- A connection just switched on should be tried now, not after
        -- whatever its previous failures had earned it.
        autoconnect.forget(self.attempts, action.id)
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
  -- What is running, so the mark can say so. Owned here, reasoned about in
  -- vpnbar/work.lua.
  self.work = work.new()
  self.phase = 1
  self.running = false
  return self
end

function obj:start()
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
    return self:hammerspoonMenu(menu.build(self.config, self.states))
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
  self.wake = hs.caffeinate.watcher.new(function(event)
    if event == hs.caffeinate.watcher.systemDidWake then
      -- Failures from before the lid closed say nothing about the network on
      -- the other side of it, so autoconnect starts again from nothing.
      autoconnect.forget(self.attempts)
      -- Several looks over the first quarter minute rather than one at the
      -- instant of the wake, when there is no route yet — see work.WAKE_READS.
      -- All of them are claimed now, which is what keeps the mark moving from
      -- the moment the screen comes back until the state has settled.
      for _, read in ipairs(work.WAKE_READS) do
        self:refreshSoon({ autoconnect = read.autoconnect == true }, read.after)
      end
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
