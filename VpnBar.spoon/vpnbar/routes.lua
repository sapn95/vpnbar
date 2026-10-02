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
--- @param memory table owned by the caller
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
