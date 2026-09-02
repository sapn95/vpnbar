--- The profile store: the CRUD half of vpnbar, with no Hammerspoon in it.
---
--- Every mutator takes a config table and returns a *new* one, or `nil` plus a
--- message. A rejected edit therefore cannot leave a half-written config
--- behind, which matters because the caller writes whatever comes back
--- straight to disk.

local store = {}

store.VERSION = 1

-- Which backend knows how to talk to which kind of connection. `shell` is the
-- escape hatch: anything with a connect and a disconnect command fits it, so a
-- VPN this project has never heard of needs no code here.
local BACKENDS = { globalprotect = true, scutil = true, shell = true }

local ID_PATTERN = "^[a-z0-9][a-z0-9_-]*$"

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[k] = copy(v)
  end
  return out
end

store.copy = copy

local function isNonEmptyString(value)
  return type(value) == "string" and value:match("%S") ~= nil
end

-- Accented letters are folded by codepoint, not by byte. Lua patterns match
-- bytes, and every one of these characters starts with the same 0xC3 lead
-- byte in UTF-8 — a character class over them therefore matches half of a
-- letter it was never meant to touch and turns "Zürich" into "zaurich".
local FOLD = {
  ["Ä"] = "a",
  ["ä"] = "a",
  ["À"] = "a",
  ["à"] = "a",
  ["Á"] = "a",
  ["á"] = "a",
  ["Â"] = "a",
  ["â"] = "a",
  ["Ö"] = "o",
  ["ö"] = "o",
  ["Ò"] = "o",
  ["ò"] = "o",
  ["Ó"] = "o",
  ["ó"] = "o",
  ["Ô"] = "o",
  ["ô"] = "o",
  ["Ü"] = "u",
  ["ü"] = "u",
  ["Ù"] = "u",
  ["ù"] = "u",
  ["Ú"] = "u",
  ["ú"] = "u",
  ["Û"] = "u",
  ["û"] = "u",
  ["È"] = "e",
  ["è"] = "e",
  ["É"] = "e",
  ["é"] = "e",
  ["Ê"] = "e",
  ["ê"] = "e",
  ["Ë"] = "e",
  ["ë"] = "e",
  ["Ì"] = "i",
  ["ì"] = "i",
  ["Í"] = "i",
  ["í"] = "i",
  ["Î"] = "i",
  ["î"] = "i",
  ["Ï"] = "i",
  ["ï"] = "i",
  ["Ç"] = "c",
  ["ç"] = "c",
  ["Ñ"] = "n",
  ["ñ"] = "n",
  ["ß"] = "ss",
}

--- Turn a display name into a usable id. Ids are what the config, the menu and
--- the logs agree on, so they stay lower case and ASCII even when the name is
--- neither.
--- @param name string
--- @return string
function store.slug(name)
  -- Fold before lowering: `:lower()` is byte-wise too and leaves "Ü" as it is.
  local folded = tostring(name or ""):gsub("[\194-\244][\128-\191]*", function(char)
    return FOLD[char] or "-"
  end)
  local slug = folded:lower():gsub("[^a-z0-9]+", "-"):gsub("^-+", ""):gsub("-+$", "")
  if slug == "" then
    slug = "vpn"
  end
  return slug
end

--- A slug that is not taken yet, by appending -2, -3, … until it is free.
--- @param cfg table
--- @param name string
--- @return string
function store.freeId(cfg, name)
  local base = store.slug(name)
  local candidate, n = base, 1
  while store.get(cfg, candidate) do
    n = n + 1
    candidate = base .. "-" .. n
  end
  return candidate
end

local function validateProbe(probe)
  if probe == nil then
    return true
  end
  if type(probe) ~= "table" then
    return false, "probe must be an object"
  end
  if not isNonEmptyString(probe.cidr) then
    return false, "probe.cidr must be a CIDR string such as 10.0.0.0/8"
  end
  if probe.interface ~= nil and not isNonEmptyString(probe.interface) then
    return false, "probe.interface must be an interface name prefix"
  end
  return true
end

--- Check one profile in isolation. Uniqueness is not its business — that needs
--- the whole config and is checked by the mutators.
--- @param profile table
--- @return boolean ok, string|nil err
function store.validate(profile)
  if type(profile) ~= "table" then
    return false, "profile must be an object"
  end
  if not isNonEmptyString(profile.id) or not profile.id:match(ID_PATTERN) then
    return false, "id must be lower case letters, digits, - or _, starting with a letter or digit"
  end
  if not isNonEmptyString(profile.name) then
    return false, "name must not be empty"
  end
  if not BACKENDS[profile.backend] then
    return false, ("backend must be one of globalprotect, scutil, shell (got %s)"):format(tostring(profile.backend))
  end
  if profile.order ~= nil and type(profile.order) ~= "number" then
    return false, "order must be a number"
  end
  if profile.hidden ~= nil and type(profile.hidden) ~= "boolean" then
    return false, "hidden must be true or false"
  end
  if profile.protected ~= nil and type(profile.protected) ~= "boolean" then
    return false, "protected must be true or false"
  end
  if profile.autoconnect ~= nil and type(profile.autoconnect) ~= "boolean" then
    return false, "autoconnect must be true or false"
  end
  if profile.fallback ~= nil and not isNonEmptyString(profile.fallback) then
    return false, "fallback must be the id of another connection"
  end
  if profile.fallback == profile.id then
    return false, "a connection cannot fall back to itself"
  end

  if profile.backend == "scutil" and not isNonEmptyString(profile.service) then
    return false, "a scutil profile needs the service name shown by `scutil --nc list`"
  end
  if profile.backend == "globalprotect" and not isNonEmptyString(profile.app) then
    return false, "a globalprotect profile needs the menu-bar app name, normally GlobalProtect"
  end
  if profile.backend == "shell" then
    local commands = profile.commands
    if type(commands) ~= "table" then
      return false, "a shell profile needs a commands object"
    end
    if not isNonEmptyString(commands.connect) or not isNonEmptyString(commands.disconnect) then
      return false, "a shell profile needs commands.connect and commands.disconnect"
    end
    if commands.status ~= nil and not isNonEmptyString(commands.status) then
      return false, "commands.status must be a command that prints the state"
    end
    if commands.force ~= nil and not isNonEmptyString(commands.force) then
      return false, "commands.force must be a command that brings the tunnel down the hard way"
    end
  end

  return validateProbe(profile.probe)
end

--- The settings that are about the menu as a whole rather than one connection,
--- with what they mean when the file does not say.
store.DEFAULTS = {
  -- Only one tunnel up at a time. Governs what autoconnect does: it will not
  -- start a second one, and it takes down extras it started itself. A tunnel
  -- somebody opened by hand is reported, never closed — see
  -- docs/adr/0005-crud-is-over-the-menu-not-the-system.md for why that line is
  -- where it is.
  exclusive = false,
  -- Whether autoconnect is allowed to try a connection's `fallback` at all.
  -- Off, it keeps asking for the one that was actually chosen.
  fallback = true,
}

--- An empty, valid config.
--- @return table
function store.empty()
  return { version = store.VERSION, settings = copy(store.DEFAULTS), profiles = {} }
end

--- The settings, with every default filled in.
--- @param cfg table
--- @return table
function store.settings(cfg)
  local settings = copy(store.DEFAULTS)
  for key, value in pairs((cfg or {}).settings or {}) do
    settings[key] = value
  end
  return settings
end

--- @param cfg table
--- @param patch table
--- @return table|nil cfg, string|nil err
function store.setSettings(cfg, patch)
  local next_ = copy(cfg)
  next_.settings = store.settings(cfg)
  for key, value in pairs(patch) do
    if store.DEFAULTS[key] == nil then
      return nil, ("no such setting: %s"):format(tostring(key))
    end
    if type(value) ~= type(store.DEFAULTS[key]) then
      return nil, ("%s must be %s"):format(key, type(store.DEFAULTS[key]))
    end
    next_.settings[key] = value
  end
  return next_
end

--- Accept whatever came off disk and hand back something the rest of the code
--- may assume is well formed — or refuse it. Defaults are filled in here and
--- nowhere else, so there is one answer to "what does a missing `order` mean".
--- @param raw any
--- @return table|nil cfg, string|nil err
function store.normalise(raw)
  if raw == nil then
    return store.empty()
  end
  if type(raw) ~= "table" then
    return nil, "the config file must contain a JSON object"
  end
  if raw.version ~= nil and raw.version ~= store.VERSION then
    return nil, ("unsupported config version %s, this build reads %d"):format(tostring(raw.version), store.VERSION)
  end
  if raw.profiles ~= nil and type(raw.profiles) ~= "table" then
    return nil, "profiles must be an array"
  end

  if raw.settings ~= nil and type(raw.settings) ~= "table" then
    return nil, "settings must be an object"
  end
  for key, value in pairs(raw.settings or {}) do
    if store.DEFAULTS[key] == nil then
      return nil, ("no such setting: %s"):format(tostring(key))
    end
    if type(value) ~= type(store.DEFAULTS[key]) then
      return nil, ("setting %s must be %s"):format(key, type(store.DEFAULTS[key]))
    end
  end

  local cfg = { version = store.VERSION, settings = store.settings(raw), profiles = {} }
  local seen = {}
  for index, rawProfile in ipairs(raw.profiles or {}) do
    local profile = copy(rawProfile)
    if type(profile) == "table" then
      profile.order = profile.order or index * 10
      profile.hidden = profile.hidden or false
      profile.protected = profile.protected or false
      profile.autoconnect = profile.autoconnect or false
      if profile.backend == "globalprotect" then
        profile.app = profile.app or "GlobalProtect"
      end
    end
    local ok, err = store.validate(profile)
    if not ok then
      return nil, ("profile #%d: %s"):format(index, err)
    end
    if seen[profile.id] then
      return nil, ("profile #%d: duplicate id %q"):format(index, profile.id)
    end
    seen[profile.id] = true
    cfg.profiles[#cfg.profiles + 1] = profile
  end
  -- Checked once every id is known: a fallback naming a connection that is not
  -- there would be a silent dead end at exactly the moment it is needed.
  for index, profile in ipairs(cfg.profiles) do
    if profile.fallback and not seen[profile.fallback] then
      return nil, ("profile #%d: fallback %q is not a connection in this file"):format(index, profile.fallback)
    end
  end
  return cfg
end

--- Profiles in the order the menu shows them: by `order`, ties broken by name
--- so the list never reshuffles itself between two reads.
--- @param cfg table
--- @param includeHidden boolean|nil
--- @return table
function store.list(cfg, includeHidden)
  local out = {}
  for _, profile in ipairs(cfg.profiles or {}) do
    if includeHidden or not profile.hidden then
      out[#out + 1] = profile
    end
  end
  table.sort(out, function(a, b)
    if a.order == b.order then
      return a.name:lower() < b.name:lower()
    end
    return a.order < b.order
  end)
  return out
end

--- @param cfg table
--- @param id string
--- @return table|nil profile, number|nil index
function store.get(cfg, id)
  for index, profile in ipairs(cfg.profiles or {}) do
    if profile.id == id then
      return profile, index
    end
  end
  return nil, nil
end

--- @param cfg table
--- @param profile table
--- @return table|nil cfg, string|nil err
function store.add(cfg, profile)
  local candidate = copy(profile)
  candidate.order = candidate.order or (#(cfg.profiles or {}) + 1) * 10
  candidate.hidden = candidate.hidden or false
  candidate.protected = candidate.protected or false
  candidate.autoconnect = candidate.autoconnect or false
  if candidate.backend == "globalprotect" then
    candidate.app = candidate.app or "GlobalProtect"
  end
  local ok, err = store.validate(candidate)
  if not ok then
    return nil, err
  end
  if store.get(cfg, candidate.id) then
    return nil, ("a connection with the id %q already exists"):format(candidate.id)
  end
  local next_ = copy(cfg)
  next_.profiles[#next_.profiles + 1] = candidate
  return next_
end

--- Patch a profile. Keys set to `store.REMOVE` are deleted rather than set,
--- because a JSON null is indistinguishable from an absent key once it is a
--- Lua table.
store.REMOVE = setmetatable({}, {
  __tostring = function()
    return "store.REMOVE"
  end,
})

--- @param cfg table
--- @param id string
--- @param patch table
--- @return table|nil cfg, string|nil err
function store.update(cfg, id, patch)
  local _, index = store.get(cfg, id)
  if not index then
    return nil, ("no connection with the id %q"):format(tostring(id))
  end
  local next_ = copy(cfg)
  local merged = next_.profiles[index]
  for key, value in pairs(patch) do
    if value == store.REMOVE then
      merged[key] = nil
    else
      merged[key] = copy(value)
    end
  end
  local ok, err = store.validate(merged)
  if not ok then
    return nil, err
  end
  if merged.id ~= id and store.get(cfg, merged.id) then
    return nil, ("a connection with the id %q already exists"):format(merged.id)
  end
  return next_
end

--- @param cfg table
--- @param id string
--- @return table|nil cfg, string|nil err
function store.remove(cfg, id)
  local _, index = store.get(cfg, id)
  if not index then
    return nil, ("no connection with the id %q"):format(tostring(id))
  end
  local next_ = copy(cfg)
  table.remove(next_.profiles, index)
  return next_
end

--- Move a profile one place up or down in the menu. Reordering rewrites every
--- `order` to a fresh 10, 20, 30 … rather than swapping two numbers, so a
--- config hand-edited into ties sorts itself out on the first move.
--- @param cfg table
--- @param id string
--- @param delta number -1 for up, 1 for down
--- @return table|nil cfg, string|nil err
function store.move(cfg, id, delta)
  local ordered = store.list(cfg, true)
  local position
  for index, profile in ipairs(ordered) do
    if profile.id == id then
      position = index
    end
  end
  if not position then
    return nil, ("no connection with the id %q"):format(tostring(id))
  end
  local target = position + delta
  if target < 1 or target > #ordered then
    return cfg
  end
  ordered[position], ordered[target] = ordered[target], ordered[position]

  local next_ = copy(cfg)
  local orderById = {}
  for index, profile in ipairs(ordered) do
    orderById[profile.id] = index * 10
  end
  for _, profile in ipairs(next_.profiles) do
    profile.order = orderById[profile.id]
  end
  return next_
end

--- Add every discovered service that is not configured yet. Existing profiles
--- are never touched: an import is allowed to add, never to overwrite a name
--- or a backend somebody chose by hand.
--- @param cfg table
--- @param services table list of { name = string }
--- @return table cfg, table added ids
function store.import(cfg, services)
  local known = {}
  for _, profile in ipairs(cfg.profiles or {}) do
    if profile.backend == "scutil" and profile.service then
      known[profile.service] = true
    end
  end
  local next_, added = copy(cfg), {}
  for _, service in ipairs(services or {}) do
    if isNonEmptyString(service.name) and not known[service.name] then
      local profile = {
        id = store.freeId(next_, service.name),
        name = service.name,
        backend = "scutil",
        service = service.name,
      }
      local updated, err = store.add(next_, profile)
      if updated then
        next_ = updated
        added[#added + 1] = profile.id
      else
        -- A service whose name cannot be made into a valid profile is skipped
        -- rather than failing the whole import; the others are still worth
        -- having. Nothing has been written yet at this point.
        assert(err)
      end
    end
  end
  return next_, added
end

return store
