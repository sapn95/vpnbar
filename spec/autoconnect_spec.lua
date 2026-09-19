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
    assert.equals(0, memory.aws.attempts)
    assert.is_nil(memory.aws.lastTry)
  end)

  -- `started` is not a failure record. It is the answer to whether this menu is
  -- allowed to close the tunnel again, and clearing it would leave a stand-in
  -- running with nothing willing to take it down.
  it("remembers that it started it, even after it has arrived", function()
    local memory = {}
    autoconnect.remember(memory, "aws", 1000)
    autoconnect.plan(config(), { aws = "connected" }, memory, 2000)
    assert.is_true(memory.aws.started)
  end)

  -- The fallback is connected *by* autoconnect without being marked for it, so
  -- a rule that only cleared profiles carrying the flag never cleared the one
  -- connection whose record was guaranteed to keep growing.
  it("clears the record of a fallback that came up, though it autoconnects nothing", function()
    local cfg = assert(store.normalise({
      profiles = {
        { id = "aws", name = "AWS", backend = "scutil", service = "a", autoconnect = true, fallback = "alt" },
        { id = "alt", name = "Alt", backend = "scutil", service = "b" },
      },
    }))
    local memory = {}
    for _ = 1, 5 do
      autoconnect.remember(memory, "alt", 1000)
    end
    autoconnect.plan(cfg, { aws = "disconnected", alt = "connected" }, memory, 2000)
    assert.equals(0, memory.alt.attempts, "a fallback that arrived starts its next backoff from the bottom")
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

  it("asks for the wanted one first, before it has failed at all", function()
    assert.same(
      { id = "aws", verb = "connect", reason = "wanted" },
      autoconnect.plan(config(), { aws = "disconnected" }, {}, 1000)
    )
  end)

  -- One failure is enough to try the other one, and the stand-in gets its turn
  -- inside the gap the failure bought. `at = 1000` with `now = 1000` is the
  -- wanted connection mid-cooldown, which is the only moment a fallback is the
  -- right answer: while the preferred one is ready, the preferred one is asked.
  it("reaches for the fallback after a single failure", function()
    local plan =
      autoconnect.plan(config(), { aws = "disconnected", alt = "disconnected" }, afterAttempts(1, 1000), 1000)
    assert.same({ id = "alt", verb = "connect", reason = "fallback" }, plan)
  end)

  -- "Keep testing back and forth until one of them works again."
  --
  -- The earlier version of this only checked that each id turned up somewhere,
  -- which it did: the wanted one on the first pass and the stand-in ever after.
  -- That is not alternating, and the weak assertion is what let the real
  -- behaviour through — the preferred connection was abandoned for good the
  -- moment it hit the fallback threshold.
  it("alternates between the two for as long as both keep failing", function()
    local memory, asked, now = {}, {}, 1000
    for _ = 1, 12 do
      local plan = autoconnect.plan(config(), { aws = "disconnected", alt = "disconnected" }, memory, now)
      if plan then
        asked[#asked + 1] = plan.id
        autoconnect.remember(memory, plan.id, now)
      end
      now = now + 30
    end
    assert.is_true(#asked >= 6, "it never stops asking")

    local wanted, stand_in = 0, 0
    for _, id in ipairs(asked) do
      if id == "aws" then
        wanted = wanted + 1
      else
        stand_in = stand_in + 1
      end
    end
    assert.is_true(wanted >= 2, "the chosen one is asked again, not abandoned: " .. table.concat(asked, " "))
    assert.is_true(stand_in >= 2, "and so is the stand-in: " .. table.concat(asked, " "))
  end)

  it("goes on asking for the wanted one even while the stand-in is up", function()
    local plan = autoconnect.plan(config(), { aws = "disconnected", alt = "connected" }, {}, 1e6)
    assert.same({ id = "aws", verb = "connect", reason = "wanted" }, plan)
  end)

  it("asks the wanted one rather than the stand-in whenever it is ready", function()
    local plan = autoconnect.plan(config(), { aws = "disconnected", alt = "disconnected" }, afterAttempts(5, 0), 1e6)
    assert.equals("aws", plan.id, "ready beats any number of past failures")
  end)

  it("does not fall back to something that is already up", function()
    local memory = afterAttempts(1, 1000)
    local states = { aws = "disconnected", alt = "connected" }
    assert.is_nil(autoconnect.plan(config(), states, memory, 1000))
  end)

  it("does not fall back to something that is already on its way", function()
    local memory = afterAttempts(1, 1000)
    local states = { aws = "disconnected", alt = "connecting" }
    assert.is_nil(autoconnect.plan(config(), states, memory, 1000))
  end)

  -- The rule ADR 0013 states for the wanted connection, which was quietly not
  -- applied to its stand-in: nobody could read it, so nobody should poke it.
  it("does not fall back to something nobody could read", function()
    local memory = afterAttempts(1, 1000)
    assert.is_nil(autoconnect.plan(config(), { aws = "disconnected", alt = "unknown" }, memory, 1000))
    assert.is_nil(autoconnect.plan(config(), { aws = "disconnected" }, memory, 1000))
  end)

  it("may fall back to a protected connection, since that only starts it", function()
    local cfg = config()
    cfg.profiles[2].protected = true
    local memory = afterAttempts(1, 1000)
    local plan = autoconnect.plan(cfg, { aws = "disconnected", alt = "disconnected" }, memory, 1000)
    assert.same({ id = "alt", verb = "connect", reason = "fallback" }, plan)
  end)

  it("keeps asking for the wanted one when there is no fallback at all", function()
    -- Built by hand: a nil in the overrides table is the same as not passing
    -- one, so `config({ fallback = nil })` would still have a fallback.
    local cfg = assert(store.normalise({
      profiles = { { id = "aws", name = "AWS", backend = "scutil", service = "AWS", autoconnect = true } },
    }))
    local memory = afterAttempts(1, 0)
    assert.same(
      { id = "aws", verb = "connect", reason = "wanted" },
      autoconnect.plan(cfg, { aws = "disconnected" }, memory, 1e6)
    )
  end)

  it("respects the fallback's own cooldown", function()
    local memory = afterAttempts(1, 1000)
    autoconnect.remember(memory, "alt", 1000)
    assert.is_nil(autoconnect.plan(config(), { aws = "disconnected", alt = "disconnected" }, memory, 1010))
  end)
end)

describe("autoconnect.cooldown", function()
  it("waits the plain cooldown before the first retry", function()
    assert.equals(autoconnect.COOLDOWN, autoconnect.cooldown(0))
    assert.equals(autoconnect.COOLDOWN, autoconnect.cooldown(nil))
    assert.equals(autoconnect.COOLDOWN, autoconnect.cooldown(1))
  end)

  it("doubles the gap for each failure after that", function()
    assert.equals(autoconnect.COOLDOWN * 2, autoconnect.cooldown(2))
    assert.equals(autoconnect.COOLDOWN * 4, autoconnect.cooldown(3))
    assert.equals(autoconnect.COOLDOWN * 8, autoconnect.cooldown(4))
  end)

  it("stops growing at the ceiling and stays there", function()
    assert.equals(autoconnect.COOLDOWN_CEILING, autoconnect.cooldown(50))
    assert.equals(autoconnect.COOLDOWN_CEILING, autoconnect.cooldown(5000))
  end)

  it("never answers 'stop', because there is no such answer", function()
    for _, attempts in ipairs({ 0, 1, 7, 100, 10000 }) do
      local wait = autoconnect.cooldown(attempts)
      assert.is_number(wait)
      assert.is_true(wait <= autoconnect.COOLDOWN_CEILING)
    end
  end)
end)

describe("autoconnect, backing off", function()
  -- The rule this replaced stopped after six failures and stayed stopped until
  -- a wake, a click or the connection coming up. A locked screen is none of
  -- those, so an always-on VPN stayed down with nothing trying to fix it.
  it("keeps asking however many times it has failed, given long enough", function()
    local memory = {}
    for _ = 1, 40 do
      autoconnect.remember(memory, "aws", 0)
      autoconnect.remember(memory, "alt", 0)
    end
    assert.is_truthy(autoconnect.plan(config(), { aws = "disconnected" }, memory, 100000))
  end)

  it("holds off inside the backed-off gap rather than hammering", function()
    local memory = {}
    for _ = 1, 40 do
      autoconnect.remember(memory, "aws", 1000)
      autoconnect.remember(memory, "alt", 1000)
    end
    assert.is_nil(autoconnect.plan(config(), { aws = "disconnected" }, memory, 1000 + autoconnect.COOLDOWN))
    local ready = 1000 + autoconnect.COOLDOWN_CEILING
    assert.is_truthy(autoconnect.plan(config(), { aws = "disconnected" }, memory, ready))
  end)

  it("starts again at once after being told to forget", function()
    local memory = {}
    for _ = 1, 40 do
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

  it("takes down any extra, not only a fallback", function()
    local cfg = exclusive(config())
    local memory = {}
    autoconnect.remember(memory, "alt", 500)
    local plan = autoconnect.plan(cfg, { aws = "connected", alt = "connected" }, memory, 1000)
    assert.equals("alt", plan.id)
    assert.equals("supersede", plan.verb)
  end)

  -- Reversed deliberately. One at a time that makes an exception for a tunnel
  -- somebody opened by hand is not one at a time.
  it("takes down an extra nobody's autoconnect started", function()
    local cfg = exclusive(config())
    local plan = autoconnect.plan(cfg, { aws = "connected", alt = "connected" }, {}, 1000)
    assert.equals("alt", plan.id)
    assert.equals("supersede", plan.verb)
  end)

  it("keeps the one ranked highest, and rank is the order in the menu", function()
    local cfg = exclusive(config())
    local plan = autoconnect.plan(cfg, { aws = "connected", alt = "connected" }, {}, 1000)
    assert.equals("alt", plan.id, "aws is ordered first, so alt is the one that goes")

    -- Move the stand-in above it and the answer swaps: this is what Move up does.
    local moved = assert(store.move(cfg, "alt", -1))
    local after = autoconnect.plan(moved, { aws = "connected", alt = "connected" }, {}, 1000)
    assert.equals("aws", after.id, "now aws is the extra one")
  end)

  it("takes down a protected extra, under its own verb", function()
    local cfg = exclusive(assert(store.normalise({
      settings = { exclusive = true },
      profiles = {
        { id = "a", name = "A", backend = "scutil", service = "a", order = 10, autoconnect = true },
        { id = "b", name = "B", backend = "scutil", service = "b", order = 20, protected = true },
      },
    })))
    local plan = autoconnect.plan(cfg, { a = "connected", b = "connected" }, {}, 1000)
    assert.equals("b", plan.id)
    assert.equals("supersede", plan.verb, "never plain disconnect, which protection refuses")
  end)

  it("leaves a protected one alone when it is the one ranked highest", function()
    local cfg = exclusive(assert(store.normalise({
      settings = { exclusive = true },
      profiles = {
        { id = "a", name = "A", backend = "scutil", service = "a", order = 10, protected = true },
      },
    })))
    assert.is_nil(autoconnect.plan(cfg, { a = "connected" }, {}, 1000))
  end)

  it("with exclusive off, a hand-opened tunnel is still nobody's to close", function()
    local plan = autoconnect.plan(config(), { aws = "connected", alt = "connected" }, {}, 1000)
    assert.is_nil(plan)
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
    for _ = 1, 20 do
      autoconnect.remember(memory, "aws", 0)
    end
    local plan = autoconnect.plan(noFallbacks(config()), { aws = "disconnected" }, memory, 1000)
    assert.equals("aws", plan.id)
  end)
end)

describe("autoconnect, exclusive must not strand the preferred connection", function()
  local function pair()
    return assert(store.normalise({
      settings = { exclusive = true, fallback = true },
      profiles = {
        {
          id = "first",
          name = "First",
          backend = "scutil",
          service = "a",
          order = 10,
          autoconnect = true,
          fallback = "second",
        },
        { id = "second", name = "Second", backend = "scutil", service = "b", order = 20, autoconnect = true },
      },
    }))
  end

  -- Blocking on any other tunnel made the fallback a one-way door: once the
  -- stand-in was up, the connection somebody chose was never tried again.
  it("still asks for the preferred one while the stand-in is up", function()
    local plan = autoconnect.plan(pair(), { first = "disconnected", second = "connected" }, {}, 1e6)
    assert.equals("first", plan.id)
    assert.equals("connect", plan.verb)
  end)

  it("takes the stand-in down once the preferred one has arrived", function()
    local plan = autoconnect.plan(pair(), { first = "connected", second = "connected" }, {}, 1e6)
    assert.equals("second", plan.id)
    assert.equals("supersede", plan.verb)
  end)

  it("is finished once only the preferred one is up", function()
    assert.is_nil(autoconnect.plan(pair(), { first = "connected", second = "disconnected" }, {}, 1e6))
  end)

  it("does not start a lower-ranked one while a higher-ranked one is up", function()
    local plan = autoconnect.plan(pair(), { first = "connected", second = "disconnected" }, {}, 1e6)
    assert.is_nil(plan, "the stand-in has no business starting under a working first choice")
  end)

  it("leaves the preferred one alone while it is on its way up", function()
    assert.is_nil(autoconnect.plan(pair(), { first = "connecting", second = "disconnected" }, {}, 1e6))
  end)

  -- The whole cycle, in the order a machine would actually walk it.
  it("walks from the stand-in back to the preferred one and stops", function()
    local cfg, seen = pair(), {}
    local states = { first = "disconnected", second = "connected" }
    for _ = 1, 4 do
      local plan = autoconnect.plan(cfg, states, {}, 1e6)
      if not plan then
        seen[#seen + 1] = "done"
        break
      end
      seen[#seen + 1] = plan.verb .. " " .. plan.id
      states[plan.id] = plan.verb == "connect" and "connected" or "disconnected"
    end
    assert.same({ "connect first", "supersede second", "done" }, seen)
  end)
end)

describe("autoconnect, an automatic attempt waits until nobody is typing", function()
  local function ui()
    return assert(store.normalise({
      settings = { fallback = true },
      profiles = {
        {
          id = "gp",
          name = "GP",
          backend = "globalprotect",
          app = "GP",
          order = 10,
          autoconnect = true,
          fallback = "aws",
        },
        { id = "aws", name = "AWS", backend = "awsvpn", app = "AWS", row = "w", order = 20 },
      },
    }))
  end
  local down = { gp = "disconnected", aws = "disconnected" }

  it("holds a connect that would open a client's window while somebody is active", function()
    assert.is_nil(autoconnect.plan(ui(), down, {}, 1e6, 3, false))
  end)

  it("makes it once there has been a minute of quiet", function()
    local plan = autoconnect.plan(ui(), down, {}, 1e6, autoconnect.IDLE_BEFORE_INTERRUPTING, false)
    assert.equals("gp", plan.id)
  end)

  -- The person has just arrived. A login window then is what they came for.
  it("makes it at once on the read that follows a wake or an unlock", function()
    local plan = autoconnect.plan(ui(), down, {}, 1e6, 0, true)
    assert.equals("gp", plan.id)
  end)

  it("holds the fallback by the same rule", function()
    local memory = { gp = { attempts = 1, lastTry = 1e6, started = true } }
    assert.is_nil(autoconnect.plan(ui(), down, memory, 1e6, 3, false), "gp mid-cooldown, aws would interrupt")
    local plan = autoconnect.plan(ui(), down, memory, 1e6, 120, false)
    assert.equals("aws", plan.id)
  end)

  it("does not hold a backend that opens nothing", function()
    local plan = autoconnect.plan(config(), { aws = "disconnected" }, {}, 1e6, 0, false)
    assert.equals("aws", plan.id, "scutil connects without a window")
  end)

  it("goes ahead where nobody measured the idle time", function()
    assert.equals("gp", autoconnect.plan(ui(), down, {}, 1e6, nil, false).id)
    assert.equals("gp", autoconnect.plan(ui(), down, {}, 1e6).id)
  end)

  -- A deferral is not a plan. `plan` never writes the memory itself — that is
  -- the adapter's `remember`, and it only runs on a returned connect — so the
  -- thing to assert here is that nothing is returned to remember.
  it("returns nothing for a connect it held back, so there is nothing to remember", function()
    assert.is_nil(autoconnect.plan(ui(), down, {}, 1e6, 3, false))
  end)

  -- A stand-in that opens nothing may carry the traffic while the preferred
  -- connection waits for a quiet moment.
  it("lets a silent stand-in through while the preferred one is held back", function()
    local cfg = assert(store.normalise({
      settings = { fallback = true },
      profiles = {
        {
          id = "gp",
          name = "GP",
          backend = "globalprotect",
          app = "GP",
          order = 10,
          autoconnect = true,
          fallback = "s",
        },
        { id = "s", name = "S", backend = "scutil", service = "s", order = 20 },
      },
    }))
    local memory = { gp = { attempts = 1, lastTry = 0, started = true } }
    local plan = autoconnect.plan(cfg, { gp = "disconnected", s = "disconnected" }, memory, 1e6, 3, false)
    assert.same({ id = "s", verb = "connect", reason = "fallback" }, plan)
  end)

  it("holds a stand-in that would interrupt just as it holds the preferred one", function()
    local memory = { gp = { attempts = 1, lastTry = 0, started = true } }
    assert.is_nil(autoconnect.plan(ui(), down, memory, 1e6, 3, false))
  end)

  it("still takes an extra tunnel down while somebody is active", function()
    local cfg = assert(store.setSettings(ui(), { exclusive = true }))
    local plan = autoconnect.plan(cfg, { gp = "connected", aws = "connected" }, {}, 1e6, 0, false)
    assert.equals("supersede", plan.verb, "closing is not the thing that opens a login window")
  end)
end)

describe("autoconnect.wouldInterrupt", function()
  local gp = { id = "gp", backend = "globalprotect", app = "GP" }
  it("is the three conditions and nothing else", function()
    assert.is_true(autoconnect.wouldInterrupt(gp, 5, false))
    assert.is_false(autoconnect.wouldInterrupt(gp, 5, true), "fresh start")
    assert.is_false(autoconnect.wouldInterrupt(gp, 60, false), "quiet enough")
    assert.is_false(autoconnect.wouldInterrupt(gp, nil, false), "unmeasured")
    assert.is_false(autoconnect.wouldInterrupt({ id = "s", backend = "scutil" }, 0, false), "no window")
  end)
end)
