--- Parsers for the command output vpnbar reads, and the IPv4 arithmetic behind
--- the interface probe. Pure string in, table out: this is where the tests can
--- reach, and the adapters around it stay small enough to read in one sitting.

local parse = {}

--- The four words the rest of the code knows. Everything a backend says has to
--- come through here first, so a menu item never has to guess what
--- "Disconnecting" or "Verbunden" was supposed to mean.
--- The five words. `login` is down with a reason: the session has ended and
--- only a person can start another, so nothing automatic should keep asking
--- ([ADR 0029](../../docs/adr/0029-an-attempt-that-needs-a-person-waits-for-one.md)).
parse.STATES = { connected = true, connecting = true, disconnected = true, login = true, unknown = true }

local WORDS = {
  ["connected"] = "connected",
  ["connect"] = "connected",
  ["up"] = "connected",
  ["verbunden"] = "connected",
  ["connecting"] = "connecting",
  ["disconnecting"] = "connecting",
  ["reconnecting"] = "connecting",
  ["authenticating"] = "connecting",
  ["login"] = "login",
  ["needs login"] = "login",
  ["sign in"] = "login",
  ["disconnected"] = "disconnected",
  ["disconnect"] = "disconnected",
  ["down"] = "disconnected",
  ["not connected"] = "disconnected",
  ["getrennt"] = "disconnected",
  ["invalid"] = "unknown",
}

--- Normalise one word or line of status text.
--- @param text string|nil
--- @return string one of parse.STATES
function parse.state(text)
  if type(text) ~= "string" then
    return "unknown"
  end
  local trimmed = text:gsub("^%s+", ""):gsub("%s+$", ""):lower()
  if trimmed == "" then
    return "unknown"
  end
  -- Longest match first, so "not connected" is not read as "connected".
  local best, bestLength
  for word, state in pairs(WORDS) do
    if trimmed:find(word, 1, true) and (not bestLength or #word > bestLength) then
      best, bestLength = state, #word
    end
  end
  return best or "unknown"
end

--- `scutil --nc status <service>` prints the state on its own first line and
--- then a dictionary nobody here needs.
--- @param output string|nil
--- @return string
function parse.scutilStatus(output)
  if type(output) ~= "string" then
    return "unknown"
  end
  return parse.state(output:match("^[^\n]*") or "")
end

--- `scutil --nc list` prints one line per configured service:
---
---     * (Disconnected)   <uuid> <type> "<name>" [VPN:<plugin>]
---
--- @param output string|nil
--- @return table list of { name, uuid, kind, state, enabled }
function parse.scutilList(output)
  local services = {}
  if type(output) ~= "string" then
    return services
  end
  for line in output:gmatch("[^\n]+") do
    local uuid = line:match("%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x")
    local name = line:match('"([^"]+)"')
    if uuid and name then
      services[#services + 1] = {
        name = name,
        uuid = uuid,
        kind = line:match("%[([^%]]+)%]"),
        state = parse.state(line:match("%(([^%)]+)%)")),
        enabled = line:match("^%s*%*") ~= nil,
      }
    end
  end
  return services
end

-- `ifconfig` prints its flags as a comma-separated list inside angle brackets.
-- Matched whole rather than as a substring, so nothing here can be fooled by a
-- longer flag that happens to contain a shorter one.
local function hasFlag(flags, wanted)
  if type(flags) ~= "string" then
    return false
  end
  for flag in flags:gmatch("[^,]+") do
    if flag == wanted then
      return true
    end
  end
  return false
end

--- Interfaces out of `ifconfig`: what each carries, and whether the kernel says
--- it is actually running. Interface lines start in column one and carry the
--- flags; everything belonging to them is indented.
---
--- `up` wants **UP and RUNNING**, not either one. An interface line with no
--- flags at all reads as down, because guessing in the other direction is the
--- mistake this function exists to stop making.
--- @param output string|nil
--- @return table map of interface name to { up = boolean, addresses = string[] }
function parse.ifconfigInterfaces(output)
  local interfaces = {}
  if type(output) ~= "string" then
    return interfaces
  end
  local current
  for line in output:gmatch("[^\n]+") do
    local name, flags = line:match("^([%w%.%-]+):%s*flags=%x+<([^>]*)>")
    if not name then
      name = line:match("^([%w%.%-]+):")
    end
    if name then
      current = name
      interfaces[current] = interfaces[current]
        or { up = hasFlag(flags, "UP") and hasFlag(flags, "RUNNING"), addresses = {} }
    elseif current then
      local address = line:match("^%s+inet%s+([%d%.]+)")
      if address then
        table.insert(interfaces[current].addresses, address)
      end
    end
  end
  return interfaces
end

--- @param address string
--- @return number|nil
function parse.ipToInt(address)
  if type(address) ~= "string" then
    return nil
  end
  local a, b, c, d = address:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then
    return nil
  end
  local octets = { tonumber(a), tonumber(b), tonumber(c), tonumber(d) }
  local value = 0
  for _, octet in ipairs(octets) do
    if octet > 255 then
      return nil
    end
    value = value * 256 + octet
  end
  return value
end

--- Is an address inside a CIDR block? A prefix of 0 matches everything, which
--- is a legitimate way to say "any address on this interface will do".
--- @param cidr string
--- @param address string
--- @return boolean
function parse.inCidr(cidr, address)
  if type(cidr) ~= "string" then
    return false
  end
  local network, bits = cidr:match("^%s*([%d%.]+)%s*/%s*(%d+)%s*$")
  if not network then
    network, bits = cidr:match("^%s*([%d%.]+)%s*$"), "32"
  end
  local prefix = tonumber(bits)
  local networkValue, addressValue = parse.ipToInt(network), parse.ipToInt(address)
  if not networkValue or not addressValue or not prefix or prefix < 0 or prefix > 32 then
    return false
  end
  if prefix == 0 then
    return true
  end
  local mask = (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF
  return (networkValue & mask) == (addressValue & mask)
end

--- The interface probe: connected if any **live** interface the probe accepts
--- carries an address inside its CIDR. This is the only state read that costs
--- nothing and touches no user interface, which is why it wins over a backend's
--- own answer wherever it is configured.
---
--- The interface has to be up. An address outlives the tunnel that was given it:
--- GlobalProtect answers a keep-alive timeout by taking its routes away and
--- bringing the interface down, and it leaves the address sitting on it, so for
--- as long as the agent keeps trying there is a dead interface wearing the
--- number of a live one
--- ([ADR 0022](../../docs/adr/0022-a-probe-reads-the-interface-not-just-the-address.md)).
--- @param output string ifconfig output
--- @param probe table { cidr = string, interface = string|nil }
--- @return string state, string|nil the address that matched
function parse.probeState(output, probe)
  if type(probe) ~= "table" or type(probe.cidr) ~= "string" then
    return "unknown", nil
  end
  local wanted = probe.interface
  for name, interface in pairs(parse.ifconfigInterfaces(output)) do
    if interface.up and (not wanted or name:sub(1, #wanted) == wanted) then
      for _, address in ipairs(interface.addresses) do
        if parse.inCidr(probe.cidr, address) then
          return "connected", address
        end
      end
    end
  end
  return "disconnected", nil
end

--- Does GlobalProtect's own event log say the session has ended?
---
--- The agent writes one line per event to a world-readable log. A session that
--- the gateway has ended is announced ("User was logged out", "Auth Failed
--- during login", "Cleared user auth cookie", "Invalid user auth cookie"), and
--- the next connect starts a SAML login rather than a tunnel. A session that is
--- still good reconnects on its own and says so ("Auto Gateway login finished",
--- "IPSec tunnel creation finished", "Tunnel is restored"). The last of either
--- kind wins, so a logout followed by a login is not a logout.
---
--- Measured, and worth knowing: on the machine this was written for, that SAML
--- login usually completes inside the agent's own web view from a cached
--- identity in a few seconds, with no window. So `login` here means "the next
--- connect may need a person", and holding it is a bounded precaution rather
--- than the difference between a window and none.
---
--- Anything else — a keep-alive timeout, an unreachable gateway — says nothing
--- about the session and is ignored: those are exactly the failures worth
--- retrying without a person. The alive markers are checked first because the
--- agent writes "Cleared user auth cookie" without a newline, and whatever
--- follows on that physical line came later.
--- @param text string|nil the relevant lines of the event log, oldest first
--- @return boolean
function parse.globalprotectNeedsLogin(text)
  if type(text) ~= "string" then
    return false
  end
  local needs = false
  for line in text:gmatch("[^\n]+") do
    if
      line:find("Auto Gateway login finished", 1, true)
      or line:find("IPSec tunnel creation finished", 1, true)
      or line:find("Tunnel is restored", 1, true)
    then
      needs = false
    elseif
      line:find("User was logged out of Gateway", 1, true)
      or line:find("Auth Failed during login", 1, true)
      or line:find("Cleared user auth cookie", 1, true)
      or line:find("Invalid user auth cookie", 1, true)
    then
      needs = true
    end
  end
  return needs
end

return parse
