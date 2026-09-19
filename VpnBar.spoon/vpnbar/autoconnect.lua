--- Bringing a connection up on its own, and falling back when it will not come.
---
--- One function, no timers, no state of its own: the adapter calls `plan` on
--- every refresh with what it knows and a memory table it owns, and gets back
--- at most one thing to do. Two settings steer it, both in the config file and
--- both toggled from the menu: `exclusive` (never more than one tunnel up) and
--- `fallback` (whether a fallback may be tried at all). That makes the whole policy — when to retry, when
--- to give up, when to try the other one — readable in one place and testable
--- without waiting for anything.

local store = require("vpnbar.store")
local backends = require("vpnbar.backends")

local autoconnect = {}

--- Seconds before the same connection is tried again the first time. A VPN that
--- failed because there is no network yet will fail again in one second, and a
--- menu that retries at the refresh interval is a menu that hammers a portal.
autoconnect.COOLDOWN = 60

--- The longest that gap is ever allowed to grow to.
---
--- A connection that will not come up is usually one whose session has ended
--- rather than one whose tunnel dropped, and no amount of asking connects that:
--- it wants a person and a browser. Fifteen minutes is slow enough that failing
--- all night costs four attempts an hour, and quick enough that a connection
--- which becomes possible again is picked up without anybody doing anything.
autoconnect.COOLDOWN_CEILING = 900

--- Seconds without a keystroke or a click before an automatic attempt may put
--- a client's user interface on the screen.
---
--- Connecting GlobalProtect or the AWS client is done through their windows,
--- and an agent whose session has ended answers a connect by opening a login
--- window. Retried on a schedule, that is the focus taken from whatever somebody
--- is typing into, every few minutes, for as long as the connection stays down
--- ([ADR 0029](../../docs/adr/0029-an-automatic-attempt-waits-until-nobody-is-typing.md)).
--- A minute of quiet is a pause, not a gap between two words.
autoconnect.IDLE_BEFORE_INTERRUPTING = 60

--- How many times to ask for the connection somebody actually chose before
--- accepting that it is not coming and trying its fallback.
---
--- One. A second identical attempt a minute later tells you nothing the first
--- did not, and the point of having a fallback is to be on *something* while the
--- preferred one is unavailable. After this the two are tried alternately, each
--- on its own backoff, for as long as both keep failing
--- ([ADR 0026](../../docs/adr/0026-one-at-a-time-outranks-protection.md)).
autoconnect.ATTEMPTS_BEFORE_FALLBACK = 1

--- How long to wait before the next attempt, given how many have already
--- failed. Doubles from `COOLDOWN`, then stops at `COOLDOWN_CEILING` and stays
--- there: 1, 2, 4, 8 minutes, then every 15 for as long as it takes.
---
--- It never returns nil, because there is no attempt count at which the right
--- answer is to stop. An always-on VPN that has given up is the case this whole
--- project exists to remove
--- ([ADR 0024](../../docs/adr/0024-autoconnect-backs-off-it-does-not-give-up.md)).
--- @param attempts number|nil how many have failed so far
--- @return number seconds
function autoconnect.cooldown(attempts)
  if type(attempts) ~= "number" or attempts < 1 then
    return autoconnect.COOLDOWN
  end
  local wait = autoconnect.COOLDOWN * (2 ^ (attempts - 1))
  if wait > autoconnect.COOLDOWN_CEILING then
    return autoconnect.COOLDOWN_CEILING
  end
  return wait
end

local function attemptsFor(memory, id)
  return (memory[id] and memory[id].attempts) or 0
end

local function lastTryFor(memory, id)
  return (memory[id] and memory[id].lastTry) or nil
end

--- Record that a connection was asked to come up.
--- @param memory table owned by the caller, keyed by profile id
--- @param id string
--- @param now number seconds
function autoconnect.remember(memory, id, now)
  memory[id] = { attempts = attemptsFor(memory, id) + 1, lastTry = now, started = true }
end

--- Forget a connection's history. Called when it comes up, and when something
--- happened that makes the old failures meaningless: a wake, a new network.
--- @param memory table
--- Forget what has failed, without forgetting who started it.
---
--- A connection that is up has no failures worth remembering: whatever stopped
--- it connecting is over. `started` survives, because that is not a failure
--- record, it is the answer to "may this menu close this tunnel again", and
--- [ADR 0015](../../docs/adr/0015-one-at-a-time-is-a-setting-not-a-rule.md)
--- turns on it.
--- @param memory table
--- @param id string
function autoconnect.succeeded(memory, id)
  local entry = memory[id]
  if entry == nil then
    return
  end
  memory[id] = { attempts = 0, lastTry = nil, started = entry.started }
end

--- @param id string|nil nil forgets everything
function autoconnect.forget(memory, id)
  if id == nil then
    for key in pairs(memory) do
      memory[key] = nil
    end
    return
  end
  memory[id] = nil
end

--- What, if anything, to connect now.
---
--- Returns at most one action, because two VPNs coming up at the same moment
--- is a routing table nobody asked for. The next refresh takes the next one.
---
--- A protected connection may be *connected* here: protection points at
--- bringing one down, and a tunnel that must stay up is exactly the one worth
--- bringing up on its own.
---
--- @param cfg table
--- @param states table map of profile id to state
--- @param memory table the caller's memory of what has been tried
--- @param now number seconds
--- @return table|nil { id, verb = "connect"|"disconnect", reason }
--- Would an automatic connect of this profile interrupt somebody right now?
---
--- `idle` is seconds since the last input, or nil where nobody measured it, and
--- nil means "go ahead": a caller that cannot say is not a caller that should be
--- held up. `fresh` is the read that follows a wake or an unlock, when the person
--- has just arrived and wants the connection now — a login window then is what
--- they came for.
--- @param profile table
--- @param idle number|nil
--- @param fresh boolean|nil
--- @return boolean
function autoconnect.wouldInterrupt(profile, idle, fresh)
  if fresh or type(idle) ~= "number" then
    return false
  end
  return backends.drivesUI(profile) and idle < autoconnect.IDLE_BEFORE_INTERRUPTING
end

function autoconnect.plan(cfg, states, memory, now, idle, fresh)
  states, memory = states or {}, memory or {}
  local settings = store.settings(cfg)

  local function startedByUs(id)
    return memory[id] ~= nil and memory[id].started == true
  end

  local function isUp(state)
    return state == "connected" or state == "connecting"
  end

  -- Tidying up comes first, and before anything is started: two tunnels to the
  -- same place is not twice the connectivity, it is one routing table with an
  -- argument in it.
  --
  -- Only ever what autoconnect itself started, and never something protected.
  -- A tunnel somebody opened by hand is not this function's to close, which is
  -- the same line the rest of the menu draws.
  -- With `exclusive` on, the rule is the plain one: the connection ranked
  -- highest wins and every other tunnel goes down. Rank is the order in the
  -- menu, which is what Move up and Move down change, so the question "which one
  -- survives" has an answer somebody can see and move.
  --
  -- This is the one place that may close a `protected` connection, and it asks
  -- for it under its own verb
  -- ([ADR 0026](../../docs/adr/0026-one-at-a-time-outranks-protection.md)). It
  -- does not care who opened the extra tunnel either: "one at a time" that makes
  -- an exception for a tunnel opened by hand is not one at a time.
  if settings.exclusive then
    local best
    for _, profile in ipairs(store.list(cfg, true)) do
      if isUp(states[profile.id]) then
        best = best or profile
        if profile.id ~= best.id then
          return { id = profile.id, verb = "supersede", reason = "outranked by " .. best.id }
        end
      end
    end
  else
    -- Off, the old and narrower rule stands: only the stand-in started for this
    -- very connection, only if autoconnect started it, never a protected one
    -- ([ADR 0015](../../docs/adr/0015-one-at-a-time-is-a-setting-not-a-rule.md)).
    for _, profile in ipairs(store.list(cfg, true)) do
      if profile.autoconnect and states[profile.id] == "connected" then
        for _, other in ipairs(store.list(cfg, true)) do
          local extra = other.id ~= profile.id and states[other.id] == "connected" and not other.protected
          if extra and other.id == profile.fallback and startedByUs(other.id) then
            return { id = other.id, verb = "disconnect", reason = "superseded" }
          end
        end
      end
    end
  end

  -- Anything that is up has arrived, so its failures are history. Deliberately
  -- not gated on `autoconnect`: a fallback is connected *by* autoconnect without
  -- being marked for it itself, and a record that was never cleared would only
  -- ever grow, until the stand-in nobody configured was the slowest thing on the
  -- machine to come back.
  for _, profile in ipairs(store.list(cfg, true)) do
    if states[profile.id] == "connected" then
      autoconnect.succeeded(memory, profile.id)
    end
  end

  for _, profile in ipairs(store.list(cfg, true)) do
    if profile.autoconnect then
      local state = states[profile.id] or "unknown"

      if state == "disconnected" then
        local blocked = false
        if settings.exclusive then
          -- Only something ranked *above* this one may hold it down.
          --
          -- Blocking on any other tunnel made the fallback a dead end: once the
          -- stand-in was up, the connection somebody actually chose could never
          -- be tried again, and the machine stayed on the second choice for as
          -- long as it kept working. A lower-ranked tunnel that is up is exactly
          -- what the supersede rule above takes down once this one arrives.
          local rank = 0
          for position, other in ipairs(store.list(cfg, true)) do
            if other.id == profile.id then
              rank = position
            end
          end
          for position, other in ipairs(store.list(cfg, true)) do
            if other.id ~= profile.id and position < rank and isUp(states[other.id]) then
              blocked = true
            end
          end
        end

        local attempts = attemptsFor(memory, profile.id)
        local last = lastTryFor(memory, profile.id)
        local ready = last == nil or (now - last) >= autoconnect.cooldown(attempts)

        if not blocked then
          -- The one somebody chose is asked for whenever its own backoff allows
          -- it, however many times it has failed and whatever the stand-in is
          -- doing. Reaching the fallback threshold used to end the matter: past
          -- it, only the fallback was ever considered, so once the stand-in was
          -- up the preferred connection was never tried again and the machine
          -- stayed on second best. A fallback is there to carry traffic while
          -- the preferred one is unavailable, not to replace the preference.
          if ready and not autoconnect.wouldInterrupt(profile, idle, fresh) then
            return { id = profile.id, verb = "connect", reason = "wanted" }
          end

          -- Not ready means this one is inside its cooldown, and that gap is
          -- where the stand-in gets its turn. The two therefore alternate, each
          -- on its own backoff, which is what "keep testing back and forth"
          -- amounts to once neither is answering.
          local wantsFallback = settings.fallback and profile.fallback ~= nil
          if wantsFallback and attempts >= autoconnect.ATTEMPTS_BEFORE_FALLBACK then
            local fallback = store.get(cfg, profile.fallback)
            local fallbackState = states[profile.fallback] or "unknown"
            -- `disconnected`, not merely "not up". `unknown` means nobody could
            -- read it, and asking an unreadable connection to connect is the
            -- thing [ADR 0013] says not to do — the rule was stated for the
            -- wanted connection and quietly not applied to its stand-in.
            if fallback and fallbackState == "disconnected" then
              local fallbackAttempts = attemptsFor(memory, profile.fallback)
              local fallbackLast = lastTryFor(memory, profile.fallback)
              local fallbackReady = fallbackLast == nil
                or (now - fallbackLast) >= autoconnect.cooldown(fallbackAttempts)
              if fallbackReady and not autoconnect.wouldInterrupt(fallback, idle, fresh) then
                return { id = profile.fallback, verb = "connect", reason = "fallback" }
              end
            end
          end
        end
      end
      -- "connecting" and "unknown" are left alone on purpose. Connecting is
      -- already on its way, and asking an unknown connection to connect is how
      -- a probe nobody configured turns into a login prompt every ten seconds.
    end
  end

  return nil
end

return autoconnect
