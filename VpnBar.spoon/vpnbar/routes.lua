--- The routes a tunnel leaves behind when it dies without disconnecting.
---
--- A VPN that goes down tidily takes its routes with it: measured on this
--- machine, GlobalProtect removed all thirty-three of them within a second of a
--- clean teardown. One whose system extension has stopped answering does not,
--- and then every address it had claimed points at an interface that carries
--- nothing. The machine looks connected and reaches none of it, including the
--- login page of the VPN that would have replaced it
--- ([ADR 0035](../../docs/adr/0035-a-dead-tunnels-routes-are-swept-up.md)).
---
--- Everything here is a pure reading of two commands. What to do about it is
--- one offer, and the offer is the adapter's to make.

local parse = require("vpnbar.parse")

local routes = {}

--- Seconds the condition has to hold before it is offered.
---
--- A tunnel coming up is a tunnel that is briefly not up yet with its routes
--- already installed, and sweeping those away would break the connection it was
--- meant to repair. A minute is longer than any handshake here and shorter than
--- anybody's patience with a dead network.
routes.SETTLE = 60

--- Seconds before the same thing is offered again after a no.
---
--- "Not now" is an answer, not a postponement of fifteen seconds.
routes.COOLDOWN = 900

--- How long an unanswered question is believed to be still on the screen.
---
--- An hour. A dialog somebody walked away from is not a reason to never ask
--- again, and asking twice in an hour is not nagging.
routes.ASK_DEADLINE = 3600

--- Only these. A route on a physical interface is somebody's network and never
--- this function's business.
local function isTunnel(name)
  return type(name) == "string" and name:match("^utun%d+$") ~= nil
end

--- The rows of `netstat -rn`, as data.
---
--- Four columns are wanted and the fifth is `Expire`, which changes between two
--- reads of the same table. Header lines have fewer fields or a destination
--- that is the word `Destination`, and both fall out of the same check.
--- @param output string
--- @return table list of { destination, gateway, flags, netif }
function routes.parse(output)
  local parsed = {}
  if type(output) ~= "string" then
    return parsed
  end
  for line in output:gmatch("[^\n]+") do
    local destination, gateway, flags, netif = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
    if destination and destination ~= "Destination" and isTunnel(netif) then
      parsed[#parsed + 1] = {
        destination = destination,
        gateway = gateway,
        flags = flags,
        netif = netif,
      }
    end
  end
  return parsed
end

--- The CIDR a destination in `netstat -rn` stands for.
---
--- The table abbreviates, and the abbreviation is the old classful one: `10` is
--- 10.0.0.0/8, `172.16` is a /16 and `192.168.0` a /24, a destination with all
--- four octets and no prefix is a single host, and `default` is everything. A
--- written prefix wins over the count (`10.9.9/24`), with the octets left out
--- read as zeroes. Measured against this machine's own table on 10.11.2026,
--- which had `10`, `10.94.175/24` and plain host rows side by side.
---
--- Anything else is not a destination this can place: a `link#14`, an IPv6
--- row, a header.
--- @param destination string
--- @return string|nil network, number|nil prefix length
function routes.prefixOf(destination)
  if destination == "default" then
    return "0.0.0.0", 0
  end
  if type(destination) ~= "string" then
    return nil, nil
  end
  local digits, written = destination:match("^([%d%.]+)/(%d+)$")
  digits = digits or destination:match("^([%d%.]+)$")
  if not digits then
    return nil, nil
  end
  local octets = {}
  for octet in digits:gmatch("%d+") do
    octets[#octets + 1] = octet
  end
  -- More than four octets needs no check of its own: without a written prefix
  -- the count makes it wider than 32 bits, and with one the network is not an
  -- address.
  local count = #octets
  if count < 1 then
    return nil, nil
  end
  local prefix = written and tonumber(written) or count * 8
  for index = count + 1, 4 do
    octets[index] = "0"
  end
  local network = table.concat(octets, ".")
  if prefix > 32 or not parse.ipToInt(network) then
    return nil, nil
  end
  return network, prefix
end

--- Which interface a packet to this address leaves by, and how wide the route
--- is that sends it there.
---
--- The longest prefix that covers it wins, which is the rule the kernel uses
--- and the reason this cannot be a search for one line: on 10.11.2026 a tunnel
--- was up with host routes to its resolvers and nothing wider, so every other
--- address behind it matched only `default` and left by the Wi-Fi. Between two
--- rows of the same length the first one in the table is taken, as `netstat`
--- prints the one in use first.
---
--- Every interface counts here, unlike in `routes.parse`: the answer that
--- matters most is the one that is not a tunnel. Two kinds of row do not:
---
--- - Rows below `Internet6:`. The adapter hands over both families in one
---   string, and the IPv6 table has `default` rows of its own, one per tunnel
---   on this machine (`default fe80::%utun0 UGcIg utun0`). Read as IPv4, any of
---   them is a route to everything, and on a machine with no IPv4 default it
---   would have been the answer.
--- - Scoped rows, the ones flagged `I`. They serve traffic already bound to
---   their interface and are not what an ordinary packet is routed by.
--- @param output string `netstat -rn`
--- @param address string
--- @return string|nil interface name, nil when nothing covers the address
--- @return number|nil the prefix length of the route that won, 0 for `default`
function routes.interfaceFor(output, address)
  if type(output) ~= "string" or not parse.ipToInt(address) then
    return nil, nil
  end
  local best, bestPrefix
  local inet = true
  for line in output:gmatch("[^\n]+") do
    if line:match("^Internet6:") then
      inet = false
    elseif line:match("^Internet:") then
      inet = true
    elseif inet then
      local destination, _, flags, netif = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
      local network, prefix = routes.prefixOf(destination)
      local scoped = flags ~= nil and flags:find("I", 1, true) ~= nil
      local covers = network and not scoped and parse.inCidr(network .. "/" .. prefix, address)
      if covers and (not bestPrefix or prefix > bestPrefix) then
        best, bestPrefix = netif, prefix
      end
    end
  end
  return best, bestPrefix
end

--- Does the tunnel carry what it is there for?
---
--- A probe says a tunnel exists: an address on a live interface
--- ([ADR 0022](../../docs/adr/0022-a-probe-reads-the-interface-not-just-the-address.md)).
--- This asks the question somebody actually has, which is whether an address
--- on the far side leaves through it
--- ([ADR 0047](../../docs/adr/0047-a-tunnel-that-carries-nothing.md)).
---
--- The other two answers say what happened instead, which is what decides
--- whether reconnecting can help: an address that leaves by `default` has
--- nothing in the way of the route a fresh tunnel would install, and one that
--- leaves by a narrower route belongs to whatever installed that one.
--- @param output string `netstat -rn`
--- @param address string the address that has to go through the tunnel
--- @param interfaces table the interfaces the probe found the tunnel on
--- @return boolean carried
--- @return string|nil the interface it leaves by instead, nil when nothing routes it
--- @return number|nil the prefix length of that route, 0 for `default`
function routes.carries(output, address, interfaces)
  local via, prefix = routes.interfaceFor(output, address)
  for _, name in ipairs(interfaces or {}) do
    if via == name then
      return true, via, prefix
    end
  end
  return false, via, prefix
end

--- Seconds a tunnel may be up without its route before anybody is told.
---
--- A tunnel arrives address first and routes second, so every connect passes
--- through this condition on its way to working. On 10.11.2026 the routes
--- followed the address within two seconds, both times, and the tunnel that
--- never got them stood for three minutes and twenty seconds. Twenty seconds is
--- far from both.
routes.UNROUTED_SETTLE = 20

--- Which of the tunnels that carry nothing to show, and which to announce.
---
--- The memory is the caller's, keyed by connection. A connection that is no
--- longer in `found` is forgotten, so the next time it happens is a new
--- occurrence with its own settling time and its own announcement, and one that
--- stays is announced once and shown for as long as it lasts.
--- @param found table map of profile id to the address it does not reach
--- @param memory table owned by the caller
--- @param now number seconds
--- @return table shown map of id to address, table news list of ids, sorted
function routes.unrouted(found, memory, now)
  found = found or {}
  for id in pairs(memory) do
    if not found[id] then
      memory[id] = nil
    end
  end
  local shown, news = {}, {}
  for id, address in pairs(found) do
    local entry = memory[id] or { since = now }
    memory[id] = entry
    if now - entry.since >= routes.UNROUTED_SETTLE then
      shown[id] = address
      if not entry.told then
        entry.told = true
        news[#news + 1] = id
      end
    end
  end
  table.sort(news)
  return shown, news
end

--- Is this interface one that cannot carry anything right now?
---
--- Absent counts: an interface that has been destroyed with its routes still in
--- the table is the same problem by a shorter path. The flag is what decides,
--- never the address, because an address outlives the tunnel it belonged to
--- ([ADR 0022](../../docs/adr/0022-a-probe-reads-the-interface-not-just-the-address.md)).
--- @param interfaces table from `parse.ifconfigInterfaces`
--- @param name string
--- @return boolean
function routes.isDown(interfaces, name)
  if not isTunnel(name) then
    return false
  end
  local interface = (interfaces or {})[name]
  return interface == nil or interface.up ~= true
end

--- The routes that point at a tunnel which is down.
--- @param parsed table from `routes.parse`
--- @param interfaces table from `parse.ifconfigInterfaces`
--- @return table list of routes, table list of interface names
function routes.stranded(parsed, interfaces)
  local stranded, seen, names = {}, {}, {}
  for _, route in ipairs(parsed or {}) do
    if routes.isDown(interfaces, route.netif) then
      stranded[#stranded + 1] = route
      if not seen[route.netif] then
        seen[route.netif] = true
        names[#names + 1] = route.netif
      end
    end
  end
  table.sort(names)
  return stranded, names
end

--- Whether to offer to sweep them up, and what to say about it.
---
--- The memory is the caller's, keyed by nothing: there is one route table.
--- `since` is when the condition was first seen and `declined` is when somebody
--- last said no. A condition that goes away resets both, so the next occurrence
--- is a fresh question rather than the tail of an old one.
--- @param stranded table
--- @param names table interface names
--- @param memory table owned by the caller; set `asking` while a dialog is open
--- @param now number seconds
--- @return table|nil { count = number, interfaces = table }
function routes.offer(stranded, names, memory, now)
  stranded = stranded or {}
  names = names or {}
  memory = memory or {}
  if #stranded == 0 then
    memory.since, memory.declined, memory.key = nil, nil, nil
    return nil
  end
  -- One question at a time. The refresh that found this runs again while the
  -- dialog is still open and nobody has answered yet, so without this the same
  -- question stacks up on the screen once per refresh until somebody clicks
  -- through a pile of them. The caller sets `asking` to the time it opened one.
  --
  -- With a deadline, because the dialog no longer blocks the caller: a callback
  -- that never arrives would otherwise be a question that can never be asked
  -- again ([ADR 0038](../../docs/adr/0038-a-question-that-does-not-block.md)).
  if memory.asking then
    local age = type(memory.asking) == "number" and now - memory.asking or 0
    if age < routes.ASK_DEADLINE then
      return nil
    end
    memory.asking = nil
  end
  -- A second tunnel that has only just started coming up must serve its own
  -- settling time, not inherit the one the first tunnel has already served.
  -- Keyed on which tunnels are in the set rather than on how many routes they
  -- have: another route on a tunnel that is already known to be dead is the
  -- same occurrence, a new tunnel is not.
  local key = table.concat(names, ",")
  if memory.key ~= key then
    memory.key, memory.since, memory.declined = key, now, nil
  end
  memory.since = memory.since or now
  if now - memory.since < routes.SETTLE then
    return nil
  end
  if memory.declined and now - memory.declined < routes.COOLDOWN then
    return nil
  end
  return { count = #stranded, interfaces = names or {} }
end

--- What the dialog says. Here rather than in the adapter because the numbers in
--- it are the numbers the offer was made on, and a sentence that disagrees with
--- them is how a dialog talks somebody into the wrong click.
--- @param offer table
--- @return string
function routes.explain(offer)
  local many = offer.count ~= 1
  local counted = ("%d route%s on this machine point%s at %s, which %s down."):format(
    offer.count,
    many and "s" or "",
    many and "" or "s",
    table.concat(offer.interfaces, " and "),
    #offer.interfaces == 1 and "is" or "are"
  )
  local why = " Everything they cover goes to an interface that carries nothing,"
    .. " so the machine looks connected and reaches none of it."
  local scope = " Removing them needs an administrator, and nothing else is touched:"
    .. " a route is only swept up when its interface is a tunnel that is down."
  return counted .. why .. scope
end

return routes
