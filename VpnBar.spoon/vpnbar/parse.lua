--- Parsers for the command output vpnbar reads, and the IPv4 arithmetic behind
--- the interface probe. Pure string in, table out: this is where the tests can
--- reach, and the adapters around it stay small enough to read in one sitting.

local parse = {}

--- The four words the rest of the code knows. Everything a backend says has to
--- come through here first, so a menu item never has to guess what
--- "Disconnecting" or "Verbunden" was supposed to mean.
parse.STATES = { connected = true, connecting = true, disconnected = true, unknown = true }

local WORDS = {
  ["connected"] = "connected",
  ["connect"] = "connected",
  ["up"] = "connected",
  ["verbunden"] = "connected",
  ["connecting"] = "connecting",
  ["disconnecting"] = "connecting",
  ["reconnecting"] = "connecting",
  ["authenticating"] = "connecting",
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

--- Addresses per interface, out of `ifconfig`. Interface lines start in column
--- one; everything belonging to them is indented.
--- @param output string|nil
--- @return table map of interface name to a list of IPv4 addresses
function parse.ifconfigAddresses(output)
  local interfaces = {}
  if type(output) ~= "string" then
    return interfaces
  end
  local current
  for line in output:gmatch("[^\n]+") do
    local name = line:match("^([%w%.%-]+):")
    if name then
      current = name
      interfaces[current] = interfaces[current] or {}
    elseif current then
      local address = line:match("^%s+inet%s+([%d%.]+)")
      if address then
        table.insert(interfaces[current], address)
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

--- The interface probe: connected if any interface the probe accepts carries
--- an address inside its CIDR. This is the only state read that costs nothing
--- and touches no user interface, which is why it wins over a backend's own
--- answer wherever it is configured.
--- @param output string ifconfig output
--- @param probe table { cidr = string, interface = string|nil }
--- @return string state, string|nil the address that matched
function parse.probeState(output, probe)
  if type(probe) ~= "table" or type(probe.cidr) ~= "string" then
    return "unknown", nil
  end
  local wanted = probe.interface
  for name, addresses in pairs(parse.ifconfigAddresses(output)) do
    if not wanted or name:sub(1, #wanted) == wanted then
      for _, address in ipairs(addresses) do
        if parse.inCidr(probe.cidr, address) then
          return "connected", address
        end
      end
    end
  end
  return "disconnected", nil
end

return parse
