local form = require("vpnbar.form")

local function answersFor(overrides)
  local answers = { name = "Work VPN", service = "Work VPN" }
  for key, value in pairs(overrides or {}) do
    answers[key] = value
  end
  return answers
end

describe("form.get and form.set", function()
  it("read and write a dotted path", function()
    local profile = {}
    form.set(profile, "commands.connect", "vpn up")
    assert.equals("vpn up", profile.commands.connect)
    assert.equals("vpn up", form.get(profile, "commands.connect"))
  end)

  it("read nothing out of a path that is not there", function()
    assert.is_nil(form.get({}, "commands.connect"))
    assert.is_nil(form.get({ commands = "not a table" }, "commands.connect"))
  end)

  it("delete rather than store an empty answer", function()
    local profile = { service = "Work VPN" }
    form.set(profile, "service", "")
    assert.is_nil(profile.service)
  end)

  it("never create a table just to leave it empty", function()
    local profile = {}
    form.set(profile, "probe.cidr", "")
    assert.is_nil(profile.probe)
  end)

  it("remove a nested table once its last key goes", function()
    local profile = { probe = { cidr = "10.0.0.0/8" } }
    form.set(profile, "probe.cidr", nil)
    assert.is_nil(profile.probe)
  end)

  it("keep a nested table that still has something in it", function()
    local profile = { probe = { cidr = "10.0.0.0/8", interface = "utun" } }
    form.set(profile, "probe.cidr", nil)
    assert.same({ interface = "utun" }, profile.probe)
  end)
end)

describe("form.fields", function()
  local function keys(backend)
    local out = {}
    for _, field in ipairs(form.fields(backend)) do
      out[#out + 1] = field.key
    end
    return out
  end

  it("asks about a fallback last, after everything else", function()
    for _, backend in ipairs({ "scutil", "globalprotect", "shell" }) do
      local fields = form.fields(backend)
      assert.equals("fallback", fields[#fields].key)
    end
  end)

  it("asks a shell profile whether it has a harder way down, and nobody else", function()
    local function has(backend, key)
      for _, field in ipairs(form.fields(backend)) do
        if field.key == key then
          return true
        end
      end
      return false
    end
    assert.is_true(has("shell", "commands.force"))
    assert.is_false(has("scutil", "commands.force"))
    assert.is_false(has("globalprotect", "commands.force"))
  end)

  it("asks for the name first, whatever the backend", function()
    for _, backend in ipairs({ "scutil", "globalprotect", "shell" }) do
      assert.equals("name", form.fields(backend)[1].key)
    end
  end)

  it("asks a scutil profile for its service", function()
    assert.same({ "name", "service", "probe.cidr", "probe.interface", "fallback" }, keys("scutil"))
  end)

  it("asks a shell profile for its three commands", function()
    assert.same({
      "name",
      "commands.connect",
      "commands.disconnect",
      "commands.status",
      "commands.force",
      "probe.cidr",
      "probe.interface",
      "fallback",
    }, keys("shell"))
  end)

  it("asks every backend about a probe, after its own fields", function()
    for _, backend in ipairs({ "scutil", "globalprotect", "shell" }) do
      local ordered = keys(backend)
      assert.equals("probe.cidr", ordered[#ordered - 2])
      assert.equals("probe.interface", ordered[#ordered - 1])
    end
  end)

  it("has nothing to ask about a backend it does not know", function()
    assert.same({ "name", "probe.cidr", "probe.interface", "fallback" }, keys("carrier-pigeon"))
  end)

  it("marks what may not be left empty", function()
    for _, field in ipairs(form.fields("shell")) do
      if
        field.key:match("^commands%.status$")
        or field.key:match("^commands%.force$")
        or field.key:match("^probe%.")
        or field.key == "fallback"
      then
        assert.is_falsy(field.required)
      else
        assert.is_true(field.required)
      end
    end
  end)
end)

describe("form.defaults", function()
  it("offers the field's own default when adding", function()
    assert.equals("GlobalProtect", form.defaults("globalprotect", nil)["app"])
    assert.equals("utun", form.defaults("scutil", nil)["probe.interface"])
  end)

  it("offers the current value when editing", function()
    local profile = { name = "Work", service = "Work VPN", probe = { cidr = "10.0.0.0/8" } }
    local defaults = form.defaults("scutil", profile)
    assert.equals("Work", defaults.name)
    assert.equals("10.0.0.0/8", defaults["probe.cidr"])
  end)

  it("offers an empty string rather than nil, which a text field cannot show", function()
    assert.equals("", form.defaults("scutil", nil).name)
  end)
end)

describe("form.applies", function()
  it("skips the probe interface until there is a probe", function()
    local field = { key = "probe.interface", onlyWith = "probe.cidr" }
    assert.is_false(form.applies(field, { ["probe.cidr"] = "" }))
    assert.is_false(form.applies(field, {}))
    assert.is_true(form.applies(field, { ["probe.cidr"] = "10.0.0.0/8" }))
  end)

  it("asks anything without a prerequisite", function()
    assert.is_true(form.applies({ key = "name" }, {}))
  end)
end)

describe("form.build", function()
  it("makes a valid profile out of answers", function()
    local profile = assert(form.build("scutil", answersFor()))
    assert.equals("work-vpn", profile.id)
    assert.equals("scutil", profile.backend)
    assert.equals("Work VPN", profile.service)
  end)

  it("refuses answers that would not validate, and says why", function()
    local profile, err = form.build("scutil", answersFor({ service = "" }))
    assert.is_nil(profile)
    assert.matches("scutil %-%-nc list", err)
  end)

  it("keeps the id, order, hidden and protection of the profile being edited", function()
    local base =
      { id = "kept", name = "Old", backend = "scutil", service = "Old", order = 40, hidden = true, protected = true }
    local profile = assert(form.build("scutil", answersFor(), base))
    assert.equals("kept", profile.id)
    assert.equals(40, profile.order)
    assert.is_true(profile.hidden)
    assert.is_true(profile.protected)
    assert.equals("Work VPN", profile.name)
  end)

  it("drops the probe when the cidr is cleared", function()
    local base =
      { id = "a", name = "A", backend = "scutil", service = "A", probe = { cidr = "10.0.0.0/8", interface = "utun" } }
    local profile =
      assert(form.build("scutil", answersFor({ ["probe.cidr"] = "", ["probe.interface"] = "utun" }), base))
    assert.is_nil(profile.probe)
  end)

  it("keeps a probe that was given both halves", function()
    local answers = answersFor({ ["probe.cidr"] = "10.0.0.0/8", ["probe.interface"] = "utun" })
    assert.same({ cidr = "10.0.0.0/8", interface = "utun" }, assert(form.build("scutil", answers)).probe)
  end)

  it("takes the old backend's fields away when the backend changes", function()
    local base = {
      id = "a",
      name = "A",
      backend = "shell",
      commands = { connect = "up", disconnect = "down" },
    }
    local profile = assert(form.build("scutil", answersFor(), base))
    assert.is_nil(profile.commands)
    assert.equals("Work VPN", profile.service)
  end)

  it("does not touch the profile it was given", function()
    local base = { id = "a", name = "Old", backend = "scutil", service = "Old" }
    form.build("scutil", answersFor(), base)
    assert.equals("Old", base.name)
  end)

  it("fills the GlobalProtect app name from the answer, not from the default", function()
    local answers = { name = "Corp", app = "GlobalProtect Beta" }
    assert.equals("GlobalProtect Beta", assert(form.build("globalprotect", answers)).app)
  end)
end)
