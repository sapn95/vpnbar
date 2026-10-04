local routes = require("vpnbar.routes")

--- `netstat -rn -f inet` as it prints on this machine, with the tunnel that is
--- down carrying the routes it never took away.
local NETSTAT = [[
Routing tables

Internet:
Destination        Gateway            Flags               Netif Expire
default            192.168.1.1        UGScg               en0
10                 198.51.100.225     UGSc                utun4
203.0.113.29       198.51.100.225     UGHS                utun4
172.16/12          198.51.100.225     UGSc                utun4
192.168.1.0/24     link#12            UCS                 utun1
198.51.100.225/32  127.0.0.1          UGSc                lo0
]]

local function interfaces(overrides)
  local map = {
    en0 = { up = true, addresses = { "192.168.1.96" } },
    lo0 = { up = true, addresses = { "127.0.0.1" } },
    utun1 = { up = true, addresses = {} },
    utun4 = { up = false, addresses = { "198.51.100.225" } },
  }
  for name, value in pairs(overrides or {}) do
    map[name] = value
  end
  return map
end

describe("routes.parse", function()
  it("keeps the rows on a tunnel and drops everything else", function()
    local parsed = routes.parse(NETSTAT)
    assert.equals(4, #parsed)
    assert.same({ destination = "10", gateway = "198.51.100.225", flags = "UGSc", netif = "utun4" }, parsed[1])
  end)

  it("is not fooled by the header or by an empty read", function()
    assert.same({}, routes.parse("Destination Gateway Flags Netif Expire"))
    assert.same({}, routes.parse(""))
    assert.same({}, routes.parse(nil))
  end)

  it("leaves a physical interface alone, whatever is on it", function()
    -- Somebody's actual network. This file never has an opinion about it.
    local parsed = routes.parse("10.0.0.0/8        10.0.0.1          UGSc                 en0")
    assert.same({}, parsed)
  end)
end)

describe("routes.stranded", function()
  it("finds routes whose interface is not in ifconfig at all", function()
    -- The worst case, and the reason the route table is read every refresh
    -- rather than only when ifconfig shows a tunnel that is down: a tunnel
    -- that was destroyed with its routes still installed is in no ifconfig
    -- output to ask about.
    local stranded, names = routes.stranded(routes.parse(NETSTAT), { en0 = { up = true, addresses = {} } })
    assert.equals(4, #stranded)
    assert.same({ "utun1", "utun4" }, names)
  end)

  it("finds the routes on the tunnel that is down, and names it", function()
    local stranded, names = routes.stranded(routes.parse(NETSTAT), interfaces())
    assert.equals(3, #stranded)
    assert.same({ "utun4" }, names)
  end)

  it("finds nothing once that tunnel is up again", function()
    local stranded, names = routes.stranded(routes.parse(NETSTAT), interfaces({ utun4 = { up = true } }))
    assert.same({}, stranded)
    assert.same({}, names)
  end)

  it("counts an interface that is gone as one that is down", function()
    -- Destroyed with its routes still in the table: the same problem by a
    -- shorter path. Written out rather than overridden, because a nil in an
    -- override table is not an override at all.
    local gone = { en0 = { up = true, addresses = {} }, lo0 = { up = true, addresses = {} } }
    assert.equals(4, #routes.stranded(routes.parse(NETSTAT), gone))
  end)

  it("goes by the flag and not by the address, which outlives the tunnel", function()
    local held = interfaces({ utun4 = { up = false, addresses = { "198.51.100.225" } } })
    assert.equals(3, #routes.stranded(routes.parse(NETSTAT), held))
  end)
end)

describe("routes.offer", function()
  local stranded = { {}, {}, {} }
  local names = { "utun4" }

  it("waits out the settling time before it says anything", function()
    -- A tunnel coming up is briefly not up yet with its routes already in
    -- place. Sweeping those away breaks the connection this exists to repair.
    local memory = {}
    assert.is_nil(routes.offer(stranded, names, memory, 1000))
    assert.is_nil(routes.offer(stranded, names, memory, 1000 + routes.SETTLE - 1))
    assert.same({ count = 3, interfaces = names }, routes.offer(stranded, names, memory, 1000 + routes.SETTLE))
  end)

  it("says nothing at all while the table is clean", function()
    assert.is_nil(routes.offer({}, {}, {}, 1000))
  end)

  it("forgets the clock once the condition goes away", function()
    local memory = {}
    routes.offer(stranded, names, memory, 1000)
    routes.offer({}, {}, memory, 1010)
    -- The next occurrence is its own question, not the tail of the old one.
    assert.is_nil(routes.offer(stranded, names, memory, 1020))
    assert.is_table(routes.offer(stranded, names, memory, 1020 + routes.SETTLE))
  end)

  it("asks once, however many refreshes find the same thing", function()
    -- The refresh that found this runs again while the dialog is still open.
    -- Without the guard the same question stacks up on the screen, one per
    -- refresh, until somebody clicks through the pile.
    local memory = {}
    routes.offer(stranded, names, memory, 1000)
    assert.is_table(routes.offer(stranded, names, memory, 1000 + routes.SETTLE))
    memory.asking = 1000 + routes.SETTLE
    assert.is_nil(routes.offer(stranded, names, memory, 1000 + routes.SETTLE + 10))
    assert.is_nil(routes.offer(stranded, names, memory, 1000 + routes.SETTLE + 20))
    memory.asking = nil
    assert.is_table(routes.offer(stranded, names, memory, 1000 + routes.SETTLE + 30))
  end)

  it("asks again when the answer never came", function()
    -- The dialog does not hold the caller any more, so a callback that never
    -- arrives would otherwise be a question that can never be asked again.
    local memory = { since = 0, key = "utun4", asking = 1000 }
    assert.is_nil(routes.offer(stranded, names, memory, 1000 + routes.ASK_DEADLINE - 1))
    assert.is_table(routes.offer(stranded, names, memory, 1000 + routes.ASK_DEADLINE))
    assert.is_nil(memory.asking)
  end)

  it("takes no for an answer for a quarter of an hour", function()
    local memory = { since = 0, declined = 1000, key = "utun4" }
    assert.is_nil(routes.offer(stranded, names, memory, 1000 + routes.COOLDOWN - 1))
    assert.is_table(routes.offer(stranded, names, memory, 1000 + routes.COOLDOWN))
  end)

  it("starts the clock again when another tunnel joins the set", function()
    -- A second tunnel that has only just started coming up must serve its own
    -- settling time. Inheriting the first one's would sweep away the routes of
    -- a connection that is still starting, which is the one thing the wait is
    -- for.
    local memory, four = {}, { {}, {}, {}, {} }
    routes.offer(stranded, names, memory, 1000)
    assert.is_table(routes.offer(stranded, names, memory, 1000 + routes.SETTLE))
    local both = { "utun4", "utun5" }
    assert.is_nil(routes.offer(four, both, memory, 1000 + routes.SETTLE + 1))
    assert.is_table(routes.offer(four, both, memory, 1000 + 2 * routes.SETTLE + 1))
  end)

  it("does not restart the clock for another route on the same tunnel", function()
    local memory = {}
    routes.offer(stranded, names, memory, 1000)
    assert.is_table(routes.offer({ {}, {}, {}, {} }, names, memory, 1000 + routes.SETTLE))
  end)
end)

describe("routes.explain", function()
  it("agrees with the numbers the offer was made on", function()
    local said = routes.explain({ count = 33, interfaces = { "utun4" } })
    assert.matches("33 routes", said)
    assert.matches("utun4, which is down", said)
    assert.matches("administrator", said)
  end)

  it("says one route in the singular, and names two tunnels as two", function()
    assert.matches("1 route on this machine points at", routes.explain({ count = 1, interfaces = { "utun4" } }))
    local two = routes.explain({ count = 2, interfaces = { "utun4", "utun5" } })
    assert.matches("utun4 and utun5, which are down", two)
  end)
end)
