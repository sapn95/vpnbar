--- The fields a profile is made of, as data.
---
--- One list per backend, walked by the adapter to ask one question at a time,
--- and used for both adding and editing so the two can never drift. It exists
--- because the first version of Edit showed the whole profile as JSON in a
--- one-line text field, which is not an editor — it is a way to lose a config
--- to a typo you cannot see.
---
--- Nothing here talks to a dialog. A field says what to ask and where the
--- answer goes; `form.build` puts the answers back together and refuses the
--- result if it is not a valid profile.

local store = require("vpnbar.store")

local form = {}

--- The chooser shown before any field: what kind of connection this is.
form.BACKENDS = {
  { value = "scutil", label = "scutil", hint = "A VPN service macOS knows about." },
  { value = "globalprotect", label = "GlobalProtect", hint = "The Palo Alto agent, driven through its own panel." },
  { value = "shell", label = "Shell", hint = "Anything else, by way of commands you give." },
}

local COMMON = {
  {
    key = "name",
    label = "Name",
    informative = "What it is called in the menu.",
    required = true,
  },
}

local BY_BACKEND = {
  scutil = {
    {
      key = "service",
      label = "Service name",
      informative = "Exactly as `scutil --nc list` prints it, without the quotes.",
      required = true,
    },
  },
  globalprotect = {
    {
      key = "app",
      label = "Application",
      informative = "The name of the agent in the menu bar.",
      required = true,
      default = "GlobalProtect",
    },
  },
  shell = {
    {
      key = "commands.connect",
      label = "Connect command",
      informative = "Run by /bin/sh when you click to connect. Use absolute paths.",
      required = true,
    },
    {
      key = "commands.disconnect",
      label = "Disconnect command",
      informative = "Run by /bin/sh when you click to disconnect.",
      required = true,
    },
    {
      key = "commands.status",
      label = "Status command",
      informative = "Optional. Should print connected, connecting or disconnected.",
      required = false,
    },
    {
      key = "commands.force",
      label = "Force-disconnect command",
      informative = "Optional. The harder way down, for when the normal disconnect will not take. "
        .. "Without one, the menu offers no Force disconnect at all.",
      required = false,
    },
  },
}

local TAIL = {
  {
    key = "fallback",
    label = "Fallback connection",
    informative = "Optional. The id of another connection to try when this one will not come up. "
      .. "Only used when this connection is set to connect automatically.",
    required = false,
  },
}

local PROBE = {
  {
    key = "probe.cidr",
    label = "Interface probe",
    informative = "Optional. A CIDR only this VPN hands out, such as 10.0.0.0/8. "
      .. "With one, the state is read from `ifconfig` and costs nothing.",
    required = false,
  },
  {
    key = "probe.interface",
    label = "Probe interface",
    informative = "Optional. An interface-name prefix the probe is limited to.",
    required = false,
    default = "utun",
    onlyWith = "probe.cidr",
  },
}

--- Read a dotted path out of a table.
--- @param profile table
--- @param key string
--- @return any
function form.get(profile, key)
  local head, tail = key:match("^([^%.]+)%.(.+)$")
  if head then
    local nested = profile[head]
    return type(nested) == "table" and form.get(nested, tail) or nil
  end
  return profile[key]
end

--- Write a dotted path into a table. An empty value deletes the key rather
--- than storing `""`, and a nested table that ends up empty goes with it —
--- otherwise clearing a probe would leave `"probe": {}` behind, which is not
--- the same thing as having no probe.
--- @param profile table
--- @param key string
--- @param value string|nil
function form.set(profile, key, value)
  local head, tail = key:match("^([^%.]+)%.(.+)$")
  if head then
    local nested = profile[head]
    if type(nested) ~= "table" then
      if value == nil or value == "" then
        return
      end
      nested = {}
      profile[head] = nested
    end
    form.set(nested, tail, value)
    if next(nested) == nil then
      profile[head] = nil
    end
    return
  end
  if value == nil or value == "" then
    profile[key] = nil
  else
    profile[key] = value
  end
end

--- Every field to ask for, in order, for one backend.
--- @param backend string
--- @return table list of field descriptors
function form.fields(backend)
  local fields = {}
  for _, field in ipairs(COMMON) do
    fields[#fields + 1] = field
  end
  for _, field in ipairs(BY_BACKEND[backend] or {}) do
    fields[#fields + 1] = field
  end
  for _, field in ipairs(PROBE) do
    fields[#fields + 1] = field
  end
  for _, field in ipairs(TAIL) do
    fields[#fields + 1] = field
  end
  return fields
end

--- What to put in each field before the user types: the profile's current
--- value when editing, the field's own default when adding.
--- @param backend string
--- @param profile table|nil
--- @return table map of key to string
function form.defaults(backend, profile)
  local defaults = {}
  for _, field in ipairs(form.fields(backend)) do
    local current = profile and form.get(profile, field.key)
    defaults[field.key] = current or field.default or ""
  end
  return defaults
end

--- Should this field be asked at all, given what has been answered so far?
--- @param field table
--- @param answers table
--- @return boolean
function form.applies(field, answers)
  if not field.onlyWith then
    return true
  end
  local prerequisite = answers[field.onlyWith]
  return prerequisite ~= nil and prerequisite ~= ""
end

--- Assemble a profile from the answers, keeping anything the form does not
--- ask about — `order`, `hidden`, `protected` — exactly as it was.
--- @param backend string
--- @param answers table map of key to string
--- @param base table|nil the profile being edited
--- @return table|nil profile, string|nil err
function form.build(backend, answers, base)
  local profile = store.copy(base or {})
  profile.backend = backend

  -- A backend that changed takes its old fields with it: a profile that was a
  -- shell one keeping `commands` after becoming a scutil one is a profile with
  -- an unreachable half nobody will remember is there.
  for otherBackend, fields in pairs(BY_BACKEND) do
    if otherBackend ~= backend then
      for _, field in ipairs(fields) do
        form.set(profile, field.key, nil)
      end
    end
  end

  for _, field in ipairs(form.fields(backend)) do
    if form.applies(field, answers) then
      form.set(profile, field.key, answers[field.key])
    else
      form.set(profile, field.key, nil)
    end
  end

  if not profile.id then
    profile.id = store.slug(answers.name or "")
  end

  local ok, err = store.validate(profile)
  if not ok then
    return nil, err
  end
  return profile
end

return form
