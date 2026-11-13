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

--- The table of 10.11.2026 at 23:14, with the addresses changed: a tunnel that
--- is up on utun4 with host routes to its two resolvers and nothing wider, so
--- everything else behind it leaves by the Wi-Fi.
local NO_AGGREGATE = [[
Routing tables

Internet:
Destination        Gateway            Flags               Netif Expire
default            192.168.1.1        UGScg                 en0
10.9.9.29          10.11.12.13        UGHS                utun4
10.9.9.30          10.11.12.13        UGHS                utun4
10.11.12.13/32     127.0.0.1          UGSc                  lo0
192.168.1          link#14            UCS                   en0      !
192.168.1.1        de:73:31:b:a3:b6   UHLWIir               en0   1191
]]

--- The same machine a minute later, once the tunnel had its aggregate.
local WITH_AGGREGATE =
  NO_AGGREGATE:gsub("10%.9%.9%.29 ", "10                 10.11.12.13        UGSc                utun4\n10.9.9.29 ", 1)

describe("routes.prefixOf", function()
  it("reads the abbreviations netstat writes", function()
    assert.same({ "0.0.0.0", 0 }, { routes.prefixOf("default") })
    assert.same({ "10.0.0.0", 8 }, { routes.prefixOf("10") })
    assert.same({ "172.16.0.0", 16 }, { routes.prefixOf("172.16") })
    assert.same({ "192.168.1.0", 24 }, { routes.prefixOf("192.168.1") })
    assert.same({ "10.9.9.29", 32 }, { routes.prefixOf("10.9.9.29") })
  end)

  it("lets a written prefix win over the number of octets", function()
    assert.same({ "172.16.0.0", 12 }, { routes.prefixOf("172.16/12") })
    assert.same({ "10.9.9.0", 24 }, { routes.prefixOf("10.9.9/24") })
    assert.same({ "10.11.12.13", 32 }, { routes.prefixOf("10.11.12.13/32") })
    assert.same({ "192.168.1.0", 24 }, { routes.prefixOf("192.168.1.0/24") })
  end)

  it("places nothing it cannot read", function()
    for _, wrong in ipairs({
      "Destination",
      "link#14",
      "fe80::1",
      "Internet:",
      "",
      "10/33",
      "192.0.2.1.5",
      "192.0.2.1.5/24",
      "300",
      ".",
      "10/",
    }) do
      assert.same({}, { routes.prefixOf(wrong) }, wrong)
    end
    assert.same({}, { routes.prefixOf(nil) })
    assert.same({}, { routes.prefixOf(10) })
  end)
end)

describe("routes.interfaceFor", function()
  it("sends an address behind the tunnel out by the Wi-Fi when only the default covers it", function()
    assert.equals("en0", routes.interfaceFor(NO_AGGREGATE, "10.0.0.10"))
  end)

  it("takes the longest prefix, wherever in the table it stands", function()
    assert.equals("utun4", routes.interfaceFor(WITH_AGGREGATE, "10.0.0.10"))
    -- A host route beats the aggregate, and the tunnel's own address is local.
    assert.equals("utun4", routes.interfaceFor(WITH_AGGREGATE, "10.9.9.29"))
    assert.equals("lo0", routes.interfaceFor(WITH_AGGREGATE, "10.11.12.13"))
    -- The longer one listed first must not lose to a shorter one after it.
    local reversed = "10.9.9.29 10.11.12.13 UGHS utun4\n10 10.11.12.13 UGSc utun7\ndefault 192.168.1.1 UGScg en0\n"
    assert.equals("utun4", routes.interfaceFor(reversed, "10.9.9.29"))
    assert.equals("utun7", routes.interfaceFor(reversed, "10.9.9.30"))
  end)

  it("keeps the first of two rows of the same length", function()
    local twice = "10 10.11.12.13 UGSc utun4\n10 10.11.13.13 UGSc utun5\n"
    assert.equals("utun4", routes.interfaceFor(twice, "10.0.0.10"))
  end)

  it("has no answer where nothing covers the address or nothing was asked", function()
    assert.is_nil(routes.interfaceFor("10.9.9.29 10.11.12.13 UGHS utun4\n", "10.0.0.10"))
    assert.is_nil(routes.interfaceFor("", "10.0.0.10"))
    assert.is_nil(routes.interfaceFor(nil, "10.0.0.10"))
    assert.is_nil(routes.interfaceFor(NO_AGGREGATE, "example.invalid"))
    assert.is_nil(routes.interfaceFor(NO_AGGREGATE, nil))
  end)
end)

describe("routes.carries", function()
  it("is false for the tunnel of 10.11.2026 and true once it has its aggregate", function()
    assert.is_false(routes.carries(NO_AGGREGATE, "10.0.0.10", { "utun4" }))
    assert.is_true(routes.carries(WITH_AGGREGATE, "10.0.0.10", { "utun4" }))
  end)

  it("asks about this tunnel, not about any tunnel", function()
    assert.is_false(routes.carries(WITH_AGGREGATE, "10.0.0.10", { "utun5" }))
  end)

  it("takes any of the interfaces the probe accepts, wherever it stands in the list", function()
    assert.is_true(routes.carries(WITH_AGGREGATE, "10.0.0.10", { "utun2", "utun4" }))
    assert.is_true(routes.carries(WITH_AGGREGATE, "10.0.0.10", { "utun4", "utun9" }))
    assert.is_false(routes.carries(WITH_AGGREGATE, "10.0.0.10", { "utun2", "utun9" }))
  end)

  it("is false without an interface, even where nothing covers the address either", function()
    assert.is_false(routes.carries("", "10.0.0.10", {}))
    assert.is_false(routes.carries("", "10.0.0.10", nil))
  end)
end)

describe("routes.unrouted", function()
  local SETTLE = routes.UNROUTED_SETTLE

  it("says nothing while a tunnel may still be on its way to its routes", function()
    local memory = {}
    assert.same({ {}, {} }, { routes.unrouted({ gp = "10.0.0.10" }, memory, 1000) })
    assert.same({ {}, {} }, { routes.unrouted({ gp = "10.0.0.10" }, memory, 1000 + SETTLE - 1) })
  end)

  it("shows it and announces it once it has lasted, and announces it once only", function()
    local memory = {}
    routes.unrouted({ gp = "10.0.0.10" }, memory, 1000)
    assert.same({ { gp = "10.0.0.10" }, { "gp" } }, { routes.unrouted({ gp = "10.0.0.10" }, memory, 1000 + SETTLE) })
    assert.same({ { gp = "10.0.0.10" }, {} }, { routes.unrouted({ gp = "10.0.0.10" }, memory, 1000 + SETTLE + 30) })
  end)

  it("starts over when the route came back in between", function()
    local memory = {}
    routes.unrouted({ gp = "10.0.0.10" }, memory, 1000)
    routes.unrouted({ gp = "10.0.0.10" }, memory, 1000 + SETTLE)
    assert.same({ {}, {} }, { routes.unrouted({}, memory, 1100) })
    assert.same({}, memory)
    assert.same({ {}, {} }, { routes.unrouted({ gp = "10.0.0.10" }, memory, 1200) })
    assert.same({ { gp = "10.0.0.10" }, { "gp" } }, { routes.unrouted({ gp = "10.0.0.10" }, memory, 1200 + SETTLE) })
  end)

  it("times each connection by itself and names the news in a fixed order", function()
    local memory = {}
    routes.unrouted({ b = "10.0.0.10" }, memory, 1000)
    routes.unrouted({ b = "10.0.0.10", a = "10.0.0.11" }, memory, 1000 + SETTLE - 5)
    local shown, news = routes.unrouted({ b = "10.0.0.10", a = "10.0.0.11" }, memory, 1000 + SETTLE)
    assert.same({ b = "10.0.0.10" }, shown)
    assert.same({ "b" }, news)
    -- Eight at once, so that `pairs` handing them over in order by chance is
    -- one run in forty thousand rather than one in two.
    memory = {}
    local many = {}
    for _, id in ipairs({ "h", "c", "f", "a", "e", "b", "g", "d" }) do
      many[id] = { address = "10.0.0.10" }
    end
    routes.unrouted(many, memory, 1000)
    local _, all = routes.unrouted(many, memory, 1000 + SETTLE)
    assert.same({ "a", "b", "c", "d", "e", "f", "g", "h" }, all)
  end)

  it("reads no finding at all as nothing found", function()
    assert.same({ {}, {} }, { routes.unrouted(nil, {}, 1000) })
  end)
end)

describe("routes.interfaceFor, the table as the adapter hands it over", function()
  --- Both families in one string, as `runtime.routeTable` returns them: the IPv4
  --- table without a default route, then the IPv6 one with a default per tunnel.
  local BOTH = [[
Routing tables

Internet:
Destination        Gateway            Flags               Netif Expire
10.9.9.29          10.11.12.13        UGHS                utun4
192.168.1          link#14            UCS                   en0      !

Routing tables

Internet6:
Destination                             Gateway                                 Flags               Netif Expire
default                                 fe80::1%en0                             UGcg                  en0
default                                 fe80::%utun0                            UGcIg               utun0
default                                 fe80::%utun1                            UGcIg               utun1
::1                                     ::1                                     UHL                   lo0
]]

  it("reads no IPv6 row as a route for an IPv4 address", function()
    -- Read as IPv4, an IPv6 `default` is a route to everything, and with no
    -- IPv4 default it would have been the answer. The first one here is not
    -- scoped, which is what a network with IPv6 of its own hands out, so the
    -- scope rule alone would not have kept it out.
    assert.same({}, { routes.interfaceFor(BOTH, "10.0.0.10") })
    assert.same({ "utun4", 32 }, { routes.interfaceFor(BOTH, "10.9.9.29") })
  end)

  it("reads the IPv4 table again where it comes after the IPv6 one", function()
    local reversed = "Internet6:\ndefault fe80::%utun0 UGcIg utun0\nInternet:\ndefault 192.168.1.1 UGScg en0\n"
    assert.same({ "en0", 0 }, { routes.interfaceFor(reversed, "10.0.0.10") })
  end)

  it("leaves scoped rows out of an ordinary lookup", function()
    -- `I` is RTF_IFSCOPE: the row serves traffic already bound to its interface.
    local scoped = "default 192.168.1.1 UGScIg en1\ndefault 192.168.1.1 UGScg en0\n10 10.11.12.13 UGScI utun9\n"
    assert.same({ "en0", 0 }, { routes.interfaceFor(scoped, "10.0.0.10") })
  end)

  it("takes a scoped row on the primary interface where the lookup would end at default", function()
    -- The kernel looks again in the primary interface's scope when the
    -- unscoped answer is `default`, so a narrower scoped route there wins.
    local primary = "default 192.168.1.1 UGScg en0\n10 192.168.1.1 UGScI en0\n10 10.11.12.13 UGScI utun9\n"
    assert.same({ "en0", 8 }, { routes.interfaceFor(primary, "10.0.0.10") })
    -- The same row is still left out when an unscoped route already covers it.
    local covered = primary .. "10.0/16 10.11.12.13 UGSc utun4\n"
    assert.same({ "utun4", 16 }, { routes.interfaceFor(covered, "10.0.0.10") })
    -- Nor against an unscoped route narrower than `default`, however narrow
    -- the scoped one is: the second look happens only after `default`.
    local narrower = "default 192.168.1.1 UGScg en0\n10 10.11.12.13 UGSc utun4\n10.0/16 192.168.1.1 UGScI en0\n"
    assert.same({ "utun4", 8 }, { routes.interfaceFor(narrower, "10.0.0.10") })
    -- The primary interface is the first unscoped `default`, the one in use.
    local two = "default 192.168.1.1 UGScg en0\ndefault 192.0.2.1 UGSc en1\n10 192.0.2.1 UGScI en1\n"
    assert.same({ "en0", 0 }, { routes.interfaceFor(two, "10.0.0.10") })
    -- And a scoped row on another interface never counts.
    local other = "default 192.168.1.1 UGScg en0\n10 10.11.12.13 UGScI utun9\n"
    assert.same({ "en0", 0 }, { routes.interfaceFor(other, "10.0.0.10") })
  end)

  it("says how wide the winning route is", function()
    assert.same({ "en0", 0 }, { routes.interfaceFor(NO_AGGREGATE, "10.0.0.10") })
    assert.same({ "utun4", 8 }, { routes.interfaceFor(WITH_AGGREGATE, "10.0.0.10") })
    assert.same({ "en0", 24 }, { routes.interfaceFor(NO_AGGREGATE, "192.168.1.50") })
  end)
end)

describe("routes.carries, what happened instead", function()
  it("names the interface and the width of the route the address took", function()
    assert.same({ false, "en0", 0 }, { routes.carries(NO_AGGREGATE, "10.0.0.10", { "utun4" }) })
    assert.same({ true, "utun4", 8 }, { routes.carries(WITH_AGGREGATE, "10.0.0.10", { "utun4" }) })
    assert.same({ false, "utun4", 8 }, { routes.carries(WITH_AGGREGATE, "10.0.0.10", { "utun5" }) })
    assert.same({ false }, { routes.carries("", "10.0.0.10", { "utun4" }) })
  end)
end)
