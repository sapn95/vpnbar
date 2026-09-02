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

local autoconnect = {}

--- Seconds before the same connection is tried again. A VPN that failed
--- because there is no network yet will fail again in one second, and a menu
--- that retries at the refresh interval is a menu that hammers a portal.
autoconnect.COOLDOWN = 60

--- How many times to ask for the connection somebody actually chose before
--- accepting that it is not coming and trying its fallback.
autoconnect.ATTEMPTS_BEFORE_FALLBACK = 2

--- Give up on a connection that has failed this many times until something
--- changes — a wake, a network change, a click. Retrying forever is how a
--- laptop on a train spends its battery on a portal that is not reachable.
autoconnect.ATTEMPTS_BEFORE_GIVING_UP = 6

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
function autoconnect.plan(cfg, states, memory, now)
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
  for _, profile in ipairs(store.list(cfg, true)) do
    if profile.autoconnect and states[profile.id] == "connected" then
      for _, other in ipairs(store.list(cfg, true)) do
        local extra = other.id ~= profile.id and states[other.id] == "connected" and not other.protected
        -- Without `exclusive` this only applies to the stand-in that was
        -- started for this very connection; with it, to any second tunnel
        -- autoconnect is responsible for.
        local ours = settings.exclusive or other.id == profile.fallback
        if extra and ours and startedByUs(other.id) then
          return { id = other.id, verb = "disconnect", reason = "superseded" }
        end
      end
    end
  end

  for _, profile in ipairs(store.list(cfg, true)) do
    if profile.autoconnect then
      local state = states[profile.id] or "unknown"

      if state == "connected" then
        autoconnect.forget(memory, profile.id)
      elseif state == "disconnected" then
        local blocked = false
        if settings.exclusive then
          -- Somebody else is already up, or on the way: leave it at one.
          for _, other in ipairs(store.list(cfg, true)) do
            if other.id ~= profile.id and isUp(states[other.id]) then
              blocked = true
            end
          end
        end

        local attempts = attemptsFor(memory, profile.id)
        local last = lastTryFor(memory, profile.id)
        local ready = last == nil or (now - last) >= autoconnect.COOLDOWN

        if not blocked and ready and attempts < autoconnect.ATTEMPTS_BEFORE_GIVING_UP then
          local wantsFallback = settings.fallback and profile.fallback ~= nil
          if attempts < autoconnect.ATTEMPTS_BEFORE_FALLBACK or not wantsFallback then
            return { id = profile.id, verb = "connect", reason = "wanted" }
          end

          local fallback = store.get(cfg, profile.fallback)
          local fallbackState = states[profile.fallback] or "unknown"
          if fallback and not isUp(fallbackState) then
            local fallbackAttempts = attemptsFor(memory, profile.fallback)
            local fallbackLast = lastTryFor(memory, profile.fallback)
            local fallbackReady = fallbackLast == nil or (now - fallbackLast) >= autoconnect.COOLDOWN
            if fallbackReady and fallbackAttempts < autoconnect.ATTEMPTS_BEFORE_GIVING_UP then
              return { id = profile.fallback, verb = "connect", reason = "fallback" }
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
