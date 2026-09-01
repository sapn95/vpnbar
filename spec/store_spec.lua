local store = require("vpnbar.store")

local function scutilProfile(overrides)
  local profile = { id = "work", name = "Work", backend = "scutil", service = "Work VPN" }
  for key, value in pairs(overrides or {}) do
    profile[key] = value
  end
  return profile
end

describe("store.slug", function()
  it("lower-cases and hyphenates", function()
    assert.equals("work-globalprotect", store.slug("Work GlobalProtect"))
  end)

  it("folds the umlauts a Swiss connection name is likely to carry", function()
    assert.equals("buro-zurich", store.slug("Büro Zürich"))
    assert.equals("strasse", store.slug("Straße"))
  end)

  it("folds by codepoint, not by byte", function()
    -- Every one of these starts with the same UTF-8 lead byte, so a character
    -- class over them would match half a letter and leave the other half in.
    assert.equals("aoue", store.slug("äöüé"))
    assert.equals("vpn", store.slug("日本"))
  end)

  it("falls back to something usable when nothing survives", function()
    assert.equals("vpn", store.slug("///"))
    assert.equals("vpn", store.slug(nil))
  end)
end)

describe("store.freeId", function()
  it("counts up until the id is free", function()
    local cfg = store.empty()
    cfg = assert(store.add(cfg, scutilProfile({ id = "work" })))
    assert.equals("work-2", store.freeId(cfg, "Work"))
  end)
end)

describe("store.validate", function()
  it("accepts a complete scutil profile", function()
    assert.is_true((store.validate(scutilProfile())))
  end)

  it("rejects an id that is not a slug", function()
    local ok, err = store.validate(scutilProfile({ id = "Work VPN" }))
    assert.is_false(ok)
    assert.matches("id must be", err)
  end)

  it("rejects an unknown backend", function()
    local ok, err = store.validate(scutilProfile({ backend = "wireguard" }))
    assert.is_false(ok)
    assert.matches("backend must be", err)
  end)

  it("insists on the service name for scutil", function()
    local ok, err = store.validate({ id = "work", name = "Work", backend = "scutil" })
    assert.is_false(ok)
    assert.matches("scutil %-%-nc list", err)
  end)

  it("insists on both commands for shell", function()
    local ok = store.validate({ id = "a", name = "A", backend = "shell", commands = { connect = "up" } })
    assert.is_false(ok)
  end)

  it("insists on the app name for globalprotect", function()
    local ok = store.validate({ id = "a", name = "A", backend = "globalprotect" })
    assert.is_false(ok)
  end)

  it("rejects a probe without a cidr", function()
    local ok, err = store.validate(scutilProfile({ probe = { interface = "utun" } }))
    assert.is_false(ok)
    assert.matches("probe.cidr", err)
  end)

  it("rejects things that are not profiles at all", function()
    assert.is_false((store.validate("nope")))
  end)
end)

describe("store.normalise", function()
  it("turns nothing into an empty config", function()
    assert.same(store.empty(), store.normalise(nil))
  end)

  it("fills in order, hidden and the GlobalProtect app name", function()
    local cfg = assert(store.normalise({ profiles = { { id = "gp", name = "GP", backend = "globalprotect" } } }))
    assert.equals(10, cfg.profiles[1].order)
    assert.is_false(cfg.profiles[1].hidden)
    assert.equals("GlobalProtect", cfg.profiles[1].app)
  end)

  it("refuses a version it does not read", function()
    local cfg, err = store.normalise({ version = 99, profiles = {} })
    assert.is_nil(cfg)
    assert.matches("unsupported config version", err)
  end)

  it("refuses duplicate ids", function()
    local cfg, err = store.normalise({ profiles = { scutilProfile(), scutilProfile() } })
    assert.is_nil(cfg)
    assert.matches("duplicate id", err)
  end)

  it("names the profile that is wrong", function()
    local cfg, err = store.normalise({ profiles = { scutilProfile(), scutilProfile({ id = "b", backend = "nope" }) } })
    assert.is_nil(cfg)
    assert.matches("^profile #2", err)
  end)

  it("refuses a file that is not an object", function()
    assert.is_nil((store.normalise("[]")))
    assert.is_nil((store.normalise({ profiles = "no" })))
  end)
end)

describe("store.add", function()
  it("returns a new config and leaves the old one alone", function()
    local before = store.empty()
    local after = assert(store.add(before, scutilProfile()))
    assert.equals(0, #before.profiles)
    assert.equals(1, #after.profiles)
  end)

  it("refuses a duplicate id", function()
    local cfg = assert(store.add(store.empty(), scutilProfile()))
    local again, err = store.add(cfg, scutilProfile())
    assert.is_nil(again)
    assert.matches("already exists", err)
  end)

  it("refuses an invalid profile", function()
    local cfg, err = store.add(store.empty(), { id = "x" })
    assert.is_nil(cfg)
    assert.is_string(err)
  end)
end)

describe("store.update", function()
  local cfg
  before_each(function()
    cfg = assert(store.add(store.empty(), scutilProfile()))
  end)

  it("patches one key", function()
    local after = assert(store.update(cfg, "work", { name = "Office" }))
    assert.equals("Office", after.profiles[1].name)
    assert.equals("Work", cfg.profiles[1].name)
  end)

  it("deletes a key with store.REMOVE", function()
    local withProbe = assert(store.update(cfg, "work", { probe = { cidr = "10.0.0.0/8" } }))
    local without = assert(store.update(withProbe, "work", { probe = store.REMOVE }))
    assert.is_nil(without.profiles[1].probe)
  end)

  it("rejects a patch that breaks the profile", function()
    local after, err = store.update(cfg, "work", { service = "" })
    assert.is_nil(after)
    assert.is_string(err)
  end)

  it("rejects renaming an id onto an existing one", function()
    cfg = assert(store.add(cfg, scutilProfile({ id = "other", name = "Other" })))
    local after, err = store.update(cfg, "other", { id = "work" })
    assert.is_nil(after)
    assert.matches("already exists", err)
  end)

  it("reports an unknown id", function()
    local after, err = store.update(cfg, "ghost", { name = "x" })
    assert.is_nil(after)
    assert.matches("no connection", err)
  end)
end)

describe("store.remove", function()
  it("removes by id", function()
    local cfg = assert(store.add(store.empty(), scutilProfile()))
    assert.equals(0, #assert(store.remove(cfg, "work")).profiles)
  end)

  it("reports an unknown id", function()
    local cfg, err = store.remove(store.empty(), "ghost")
    assert.is_nil(cfg)
    assert.matches("no connection", err)
  end)
end)

describe("store.list", function()
  it("sorts by order and then by name", function()
    local cfg = store.empty()
    cfg = assert(store.add(cfg, scutilProfile({ id = "b", name = "Beta", order = 5 })))
    cfg = assert(store.add(cfg, scutilProfile({ id = "a", name = "Alpha", order = 5 })))
    cfg = assert(store.add(cfg, scutilProfile({ id = "c", name = "Gamma", order = 1 })))
    local names = {}
    for _, profile in ipairs(store.list(cfg)) do
      names[#names + 1] = profile.name
    end
    assert.same({ "Gamma", "Alpha", "Beta" }, names)
  end)

  it("hides hidden profiles unless asked", function()
    local cfg = assert(store.add(store.empty(), scutilProfile({ hidden = true })))
    assert.equals(0, #store.list(cfg))
    assert.equals(1, #store.list(cfg, true))
  end)
end)

describe("store.move", function()
  local cfg
  before_each(function()
    cfg = store.empty()
    cfg = assert(store.add(cfg, scutilProfile({ id = "a", name = "A" })))
    cfg = assert(store.add(cfg, scutilProfile({ id = "b", name = "B" })))
    cfg = assert(store.add(cfg, scutilProfile({ id = "c", name = "C" })))
  end)

  local function order(config)
    local ids = {}
    for _, profile in ipairs(store.list(config, true)) do
      ids[#ids + 1] = profile.id
    end
    return ids
  end

  it("moves one place up", function()
    assert.same({ "a", "c", "b" }, order(assert(store.move(cfg, "c", -1))))
  end)

  it("moves one place down", function()
    assert.same({ "b", "a", "c" }, order(assert(store.move(cfg, "a", 1))))
  end)

  it("does nothing at the ends", function()
    assert.same({ "a", "b", "c" }, order(assert(store.move(cfg, "a", -1))))
    assert.same({ "a", "b", "c" }, order(assert(store.move(cfg, "c", 1))))
  end)

  it("renumbers every order, so hand-written ties sort themselves out", function()
    local tied = assert(store.update(cfg, "b", { order = 10 }))
    local moved = assert(store.move(tied, "c", -1))
    for _, profile in ipairs(moved.profiles) do
      assert.equals(0, profile.order % 10)
    end
  end)

  it("reports an unknown id", function()
    local after, err = store.move(cfg, "ghost", 1)
    assert.is_nil(after)
    assert.matches("no connection", err)
  end)
end)

describe("store.import", function()
  it("adds services that are not configured yet", function()
    local cfg, added = store.import(store.empty(), { { name = "Work VPN" }, { name = "Home VPN" } })
    assert.same({ "work-vpn", "home-vpn" }, added)
    assert.equals("scutil", cfg.profiles[1].backend)
  end)

  it("never touches a service that is already there", function()
    local cfg = assert(store.add(store.empty(), scutilProfile({ name = "Renamed by hand", service = "Work VPN" })))
    local after, added = store.import(cfg, { { name = "Work VPN" } })
    assert.same({}, added)
    assert.equals("Renamed by hand", after.profiles[1].name)
  end)

  it("skips entries with no name", function()
    local _, added = store.import(store.empty(), { { name = "" }, {} })
    assert.same({}, added)
  end)
end)

describe("store, protected profiles", function()
  it("defaults protected to false and keeps it when set", function()
    local cfg =
      assert(store.normalise({ profiles = { scutilProfile(), scutilProfile({ id = "gp", protected = true }) } }))
    assert.is_false(cfg.profiles[1].protected)
    assert.is_true(cfg.profiles[2].protected)
  end)

  it("rejects a protected that is not a boolean", function()
    local ok, err = store.validate(scutilProfile({ protected = "yes" }))
    assert.is_false(ok)
    assert.matches("protected must be", err)
  end)

  it("can be turned on and off by a patch", function()
    local cfg = assert(store.add(store.empty(), scutilProfile()))
    assert.is_true(assert(store.update(cfg, "work", { protected = true })).profiles[1].protected)
  end)
end)

describe("store, autoconnect and fallback", function()
  local function pair(primary)
    local first = { id = "a", name = "A", backend = "scutil", service = "a" }
    for key, value in pairs(primary or {}) do
      first[key] = value
    end
    return { profiles = { first, { id = "b", name = "B", backend = "scutil", service = "b" } } }
  end

  it("defaults autoconnect to false", function()
    assert.is_false(assert(store.normalise(pair())).profiles[1].autoconnect)
  end)

  it("accepts a fallback that names another connection", function()
    assert.is_truthy(store.normalise(pair({ autoconnect = true, fallback = "b" })))
  end)

  it("refuses a fallback that names nothing in the file", function()
    -- A dead end exactly when it is needed is worse than no fallback at all.
    local cfg, err = store.normalise(pair({ fallback = "ghost" }))
    assert.is_nil(cfg)
    assert.matches("is not a connection in this file", err)
  end)

  it("refuses a connection that falls back to itself", function()
    local ok, err = store.validate({ id = "a", name = "A", backend = "scutil", service = "a", fallback = "a" })
    assert.is_false(ok)
    assert.matches("fall back to itself", err)
  end)

  it("allows a protected connection to autoconnect, which is the whole point", function()
    -- Protection points at bringing a tunnel down. A tunnel that must stay up
    -- is exactly the one worth bringing up on its own.
    assert.is_true((store.validate({
      id = "a",
      name = "A",
      backend = "scutil",
      service = "a",
      protected = true,
      autoconnect = true,
    })))
  end)

  it("rejects an autoconnect that is not a boolean", function()
    assert.is_false((store.validate({ id = "a", name = "A", backend = "scutil", service = "a", autoconnect = "yes" })))
  end)
end)
