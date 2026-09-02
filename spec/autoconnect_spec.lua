local autoconnect = require("vpnbar.autoconnect")
local store = require("vpnbar.store")

--- Two connections: `aws` wants to come up on its own and falls back to `alt`.
local function config(overrides)
  local primary = {
    id = "aws",
    name = "AWS",
    backend = "scutil",
    service = "AWS",
    autoconnect = true,
    fallback = "alt",
    order = 10,
  }
  for key, value in pairs(overrides or {}) do
    primary[key] = value
  end
  return assert(store.normalise({
    profiles = { primary, { id = "alt", name = "Alt", backend = "scutil", service = "Alt", order = 20 } },
  }))
end

describe("autoconnect.plan", function()
  it("asks for the connection somebody chose when it is down", function()
    local plan = autoconnect.plan(config(), { aws = "disconnected" }, {}, 1000)
    assert.same({ id = "aws", verb = "connect", reason = "wanted" }, plan)
  end)

  it("does nothing when it is already up", function()
    assert.is_nil(autoconnect.plan(config(), { aws = "connected" }, {}, 1000))
  end)

  it("does not interrupt a connection that is on its way", function()
    assert.is_nil(autoconnect.plan(config(), { aws = "connecting" }, {}, 1000))
  end)

  it("leaves an unreadable state alone rather than asking it to connect", function()
    -- Otherwise a probe nobody configured becomes a login prompt every tick.
    assert.is_nil(autoconnect.plan(config(), { aws = "unknown" }, {}, 1000))
  end)

  it("ignores a connection that was not asked to autoconnect", function()
    assert.is_nil(autoconnect.plan(config({ autoconnect = false }), { aws = "disconnected" }, {}, 1000))
  end)

  it("brings a protected connection UP, which is the direction protection allows", function()
    -- A tunnel that must stay up is exactly the one worth bringing up on its
    -- own. Protection points at taking one down, not at starting it.
    local cfg = config()
    cfg.profiles[1].protected = true
    local plan = autoconnect.plan(cfg, { aws = "disconnected" }, {}, 1000)
    assert.same({ id = "aws", verb = "connect", reason = "wanted" }, plan)
  end)
end)

describe("autoconnect, the cooldown", function()
  it("waits before asking the same connection again", function()
    local memory = {}
    local states = { aws = "disconnected" }
    assert.is_truthy(autoconnect.plan(config(), states, memory, 1000))
    autoconnect.remember(memory, "aws", 1000)
    assert.is_nil(autoconnect.plan(config(), states, memory, 1030))
    assert.is_truthy(autoconnect.plan(config(), states, memory, 1000 + autoconnect.COOLDOWN))
  end)

  it("starts again from nothing once the connection comes up", function()
    local memory = {}
    autoconnect.remember(memory, "aws", 1000)
    autoconnect.plan(config(), { aws = "connected" }, memory, 2000)
    assert.is_nil(memory.aws)
  end)

  it("can be told to forget everything, for a wake or a new network", function()
    local memory = {}
    autoconnect.remember(memory, "aws", 1000)
    autoconnect.remember(memory, "alt", 1000)
    autoconnect.forget(memory)
    assert.same({}, memory)
  end)
end)

describe("autoconnect, the fallback", function()
  local function afterAttempts(n, at)
    local memory = {}
    for _ = 1, n do
      autoconnect.remember(memory, "aws", at)
    end
    return memory
  end

  it("keeps asking for the wanted one until the attempts run out", function()
    local memory = afterAttempts(1, 0)
    assert.same(
      { id = "aws", verb = "connect", reason = "wanted" },
      autoconnect.plan(config(), { aws = "disconnected" }, memory, 1000)
    )
  end)

  it("moves to the fallback once it has asked enough times", function()
    local memory = afterAttempts(autoconnect.ATTEMPTS_BEFORE_FALLBACK, 0)
    local plan = autoconnect.plan(config(), { aws = "disconnected" }, memory, 1000)
    assert.same({ id = "alt", verb = "connect", reason = "fallback" }, plan)
  end)

  it("does not fall back to something that is already up", function()
    local memory = afterAttempts(autoconnect.ATTEMPTS_BEFORE_FALLBACK, 0)
    local states = { aws = "disconnected", alt = "connected" }
    assert.is_nil(autoconnect.plan(config(), states, memory, 1000))
  end)

  it("does not fall back to something that is already on its way", function()
    local memory = afterAttempts(autoconnect.ATTEMPTS_BEFORE_FALLBACK, 0)
    local states = { aws = "disconnected", alt = "connecting" }
    assert.is_nil(autoconnect.plan(config(), states, memory, 1000))
  end)

  it("may fall back to a protected connection, since that only starts it", function()
    local cfg = config()
    cfg.profiles[2].protected = true
    local memory = afterAttempts(autoconnect.ATTEMPTS_BEFORE_FALLBACK, 0)
    local plan = autoconnect.plan(cfg, { aws = "disconnected" }, memory, 1000)
    assert.same({ id = "alt", verb = "connect", reason = "fallback" }, plan)
  end)

  it("keeps asking for the wanted one when there is no fallback at all", function()
    -- Built by hand: a nil in the overrides table is the same as not passing
    -- one, so `config({ fallback = nil })` would still have a fallback.
    local cfg = assert(store.normalise({
      profiles = { { id = "aws", name = "AWS", backend = "scutil", service = "AWS", autoconnect = true } },
    }))
    local memory = afterAttempts(autoconnect.ATTEMPTS_BEFORE_FALLBACK, 0)
    assert.same(
      { id = "aws", verb = "connect", reason = "wanted" },
      autoconnect.plan(cfg, { aws = "disconnected" }, memory, 1000)
    )
  end)

  it("respects the fallback's own cooldown", function()
    local memory = afterAttempts(autoconnect.ATTEMPTS_BEFORE_FALLBACK, 0)
    autoconnect.remember(memory, "alt", 1000)
    assert.is_nil(autoconnect.plan(config(), { aws = "disconnected" }, memory, 1010))
  end)
end)

describe("autoconnect, giving up", function()
  it("stops after enough failures rather than retrying on a train forever", function()
    local memory = {}
    for _ = 1, autoconnect.ATTEMPTS_BEFORE_GIVING_UP do
      autoconnect.remember(memory, "aws", 0)
      autoconnect.remember(memory, "alt", 0)
    end
    assert.is_nil(autoconnect.plan(config(), { aws = "disconnected" }, memory, 100000))
  end)

  it("starts again after being told to forget", function()
    local memory = {}
    for _ = 1, autoconnect.ATTEMPTS_BEFORE_GIVING_UP do
      autoconnect.remember(memory, "aws", 0)
    end
    autoconnect.forget(memory)
    assert.is_truthy(autoconnect.plan(config(), { aws = "disconnected" }, memory, 100000))
  end)
end)

describe("autoconnect, more than one candidate", function()
  it("returns one action at a time, in menu order", function()
    local cfg = assert(store.normalise({
      profiles = {
        { id = "b", name = "B", backend = "scutil", service = "b", autoconnect = true, order = 20 },
        { id = "a", name = "A", backend = "scutil", service = "a", autoconnect = true, order = 10 },
      },
    }))
    local plan = autoconnect.plan(cfg, { a = "disconnected", b = "disconnected" }, {}, 1000)
    assert.equals("a", plan.id)
  end)
end)

describe("autoconnect, two tunnels to the same place", function()
  --- The wanted connection is up, and the stand-in that was started while it
  --- was down is still up beside it.
  local function bothUp()
    local memory = {}
    autoconnect.remember(memory, "alt", 500)
    return memory
  end

  it("takes the stand-in down once the wanted one is up", function()
    local plan = autoconnect.plan(config(), { aws = "connected", alt = "connected" }, bothUp(), 1000)
    assert.same({ id = "alt", verb = "disconnect", reason = "superseded" }, plan)
  end)

  it("leaves a tunnel it did not start alone", function()
    -- Opened by hand: not this function's to close.
    assert.is_nil(autoconnect.plan(config(), { aws = "connected", alt = "connected" }, {}, 1000))
  end)

  it("never takes down a protected stand-in", function()
    local cfg = config()
    cfg.profiles[2].protected = true
    assert.is_nil(autoconnect.plan(cfg, { aws = "connected", alt = "connected" }, bothUp(), 1000))
  end)

  it("does nothing while the wanted one is only on its way up", function()
    assert.is_nil(autoconnect.plan(config(), { aws = "connecting", alt = "connected" }, bothUp(), 1000))
  end)

  it("tidies up before it connects anything else", function()
    -- Both rules could fire on the same refresh; taking one down wins, because
    -- the alternative is briefly having three.
    local cfg = assert(store.normalise({
      profiles = {
        {
          id = "aws",
          name = "AWS",
          backend = "scutil",
          service = "AWS",
          autoconnect = true,
          fallback = "alt",
          order = 10,
        },
        { id = "alt", name = "Alt", backend = "scutil", service = "Alt", order = 20 },
        { id = "third", name = "Third", backend = "scutil", service = "T", autoconnect = true, order = 30 },
      },
    }))
    local states = { aws = "connected", alt = "connected", third = "disconnected" }
    assert.equals("disconnect", autoconnect.plan(cfg, states, bothUp(), 1000).verb)
  end)
end)

describe("autoconnect, only one connection at a time", function()
  local function exclusive(cfg)
    return assert(store.setSettings(cfg, { exclusive = true }))
  end

  it("does not start a second tunnel when one is already up", function()
    local cfg = exclusive(assert(store.normalise({
      profiles = {
        { id = "a", name = "A", backend = "scutil", service = "a", order = 10 },
        { id = "b", name = "B", backend = "scutil", service = "b", autoconnect = true, order = 20 },
      },
    })))
    assert.is_nil(autoconnect.plan(cfg, { a = "connected", b = "disconnected" }, {}, 1000))
  end)

  it("does not start one while another is still on its way up", function()
    local cfg = exclusive(assert(store.normalise({
      profiles = {
        { id = "a", name = "A", backend = "scutil", service = "a", order = 10 },
        { id = "b", name = "B", backend = "scutil", service = "b", autoconnect = true, order = 20 },
      },
    })))
    assert.is_nil(autoconnect.plan(cfg, { a = "connecting", b = "disconnected" }, {}, 1000))
  end)

  it("starts it once the other one has gone", function()
    local cfg = exclusive(assert(store.normalise({
      profiles = {
        { id = "a", name = "A", backend = "scutil", service = "a", order = 10 },
        { id = "b", name = "B", backend = "scutil", service = "b", autoconnect = true, order = 20 },
      },
    })))
    local plan = autoconnect.plan(cfg, { a = "disconnected", b = "disconnected" }, {}, 1000)
    assert.equals("b", plan.id)
  end)

  it("takes down any extra it started, not only a fallback", function()
    local cfg = exclusive(config())
    local memory = {}
    autoconnect.remember(memory, "alt", 500)
    local plan = autoconnect.plan(cfg, { aws = "connected", alt = "connected" }, memory, 1000)
    assert.same({ id = "alt", verb = "disconnect", reason = "superseded" }, plan)
  end)

  it("still leaves alone what it did not start", function()
    local cfg = exclusive(config())
    assert.is_nil(autoconnect.plan(cfg, { aws = "connected", alt = "connected" }, {}, 1000))
  end)

  it("is off by default, so an unconfigured menu behaves as before", function()
    local cfg = assert(store.normalise({
      profiles = {
        { id = "a", name = "A", backend = "scutil", service = "a", order = 10 },
        { id = "b", name = "B", backend = "scutil", service = "b", autoconnect = true, order = 20 },
      },
    }))
    assert.is_truthy(autoconnect.plan(cfg, { a = "connected", b = "disconnected" }, {}, 1000))
  end)
end)

describe("autoconnect, fallbacks switched off", function()
  local function noFallbacks(cfg)
    return assert(store.setSettings(cfg, { fallback = false }))
  end

  it("keeps asking for the connection that was chosen", function()
    local memory = {}
    for _ = 1, autoconnect.ATTEMPTS_BEFORE_FALLBACK do
      autoconnect.remember(memory, "aws", 0)
    end
    local plan = autoconnect.plan(noFallbacks(config()), { aws = "disconnected" }, memory, 1000)
    assert.same({ id = "aws", verb = "connect", reason = "wanted" }, plan)
  end)

  it("never reaches for the fallback, however many times it has failed", function()
    local memory = {}
    for _ = 1, autoconnect.ATTEMPTS_BEFORE_GIVING_UP - 1 do
      autoconnect.remember(memory, "aws", 0)
    end
    local plan = autoconnect.plan(noFallbacks(config()), { aws = "disconnected" }, memory, 1000)
    assert.equals("aws", plan.id)
  end)
end)
