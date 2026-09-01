local parse = require("vpnbar.parse")

-- The shapes are copied from real output; the names and addresses are not, so
-- nothing in this repository says which networks anybody actually uses.
local SCUTIL_LIST = [[
Available network connection services in the current set (*=enabled):
* (Disconnected)   1A2B3C4D-0000-4000-8000-0123456789AB PPP          "Home PPTP"        [PPP:PPTP]
* (Connected)      2B3C4D5E-0000-4000-8000-0123456789AB GlobalProtect "Work VPN"        [VPN:com.example.vpnplugin]
  (Disconnected)   3C4D5E6F-0000-4000-8000-0123456789AB VPN "Gateway VPN" [VPN:com.example.gateway]
]]

local IFCONFIG = [[
lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
	inet 127.0.0.1 netmask 0xff000000
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	inet 192.168.1.24 netmask 0xffffff00 broadcast 192.168.1.255
utun3: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1380
utun4: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1400
	inet 10.11.12.13 --> 10.11.12.13 netmask 0xffffffff
]]

describe("parse.state", function()
  it("knows the four words", function()
    assert.equals("connected", parse.state("Connected"))
    assert.equals("connecting", parse.state("Connecting..."))
    assert.equals("disconnected", parse.state("Disconnected"))
    assert.equals("unknown", parse.state("Whatever this is"))
  end)

  it("reads 'not connected' as disconnected, not as connected", function()
    assert.equals("disconnected", parse.state("Not Connected"))
  end)

  it("treats disconnecting as work in progress", function()
    assert.equals("connecting", parse.state("Disconnecting"))
  end)

  it("survives nothing at all", function()
    assert.equals("unknown", parse.state(nil))
    assert.equals("unknown", parse.state("   "))
    assert.equals("unknown", parse.state(42))
  end)
end)

describe("parse.scutilStatus", function()
  it("takes the first line and ignores the dictionary under it", function()
    assert.equals("connected", parse.scutilStatus("Connected\nExtended Status <dictionary> {\n  Status : 1\n}\n"))
  end)

  it("is unknown when the command printed nothing", function()
    assert.equals("unknown", parse.scutilStatus(""))
    assert.equals("unknown", parse.scutilStatus(nil))
  end)
end)

describe("parse.scutilList", function()
  it("reads every service", function()
    local services = parse.scutilList(SCUTIL_LIST)
    assert.equals(3, #services)
    assert.equals("Home PPTP", services[1].name)
    assert.equals("Work VPN", services[2].name)
    assert.equals("connected", services[2].state)
    assert.is_true(services[2].enabled)
    assert.is_false(services[3].enabled)
  end)

  it("ignores the header and anything without a uuid", function()
    assert.equals(0, #parse.scutilList("Available network connection services in the current set (*=enabled):"))
    assert.equals(0, #parse.scutilList(nil))
  end)
end)

describe("parse.ifconfigAddresses", function()
  it("groups addresses under their interface", function()
    local interfaces = parse.ifconfigAddresses(IFCONFIG)
    assert.same({ "127.0.0.1" }, interfaces.lo0)
    assert.same({ "10.11.12.13" }, interfaces.utun4)
    assert.same({}, interfaces.utun3, "an interface with no address is still an interface")
  end)

  it("survives nothing at all", function()
    assert.same({}, parse.ifconfigAddresses(nil))
  end)
end)

describe("parse.inCidr", function()
  it("matches inside the block and not outside it", function()
    assert.is_true(parse.inCidr("10.0.0.0/8", "10.11.12.13"))
    assert.is_false(parse.inCidr("10.0.0.0/8", "192.168.1.24"))
    assert.is_true(parse.inCidr("10.11.12.0/24", "10.11.12.13"))
    assert.is_false(parse.inCidr("10.11.13.0/24", "10.11.12.13"))
  end)

  it("takes a bare address as /32", function()
    assert.is_true(parse.inCidr("10.11.12.13", "10.11.12.13"))
    assert.is_false(parse.inCidr("10.11.12.14", "10.11.12.13"))
  end)

  it("treats /0 as any address", function()
    assert.is_true(parse.inCidr("0.0.0.0/0", "8.8.8.8"))
  end)

  it("refuses nonsense rather than guessing", function()
    assert.is_false(parse.inCidr("10.0.0.0/33", "10.0.0.1"))
    assert.is_false(parse.inCidr("10.0.0.0/8", "10.0.0.300"))
    assert.is_false(parse.inCidr("not a cidr", "10.0.0.1"))
    assert.is_false(parse.inCidr(nil, "10.0.0.1"))
    assert.is_nil(parse.ipToInt(nil))
  end)
end)

describe("parse.probeState", function()
  it("is connected when a matching interface carries a matching address", function()
    local state, address = parse.probeState(IFCONFIG, { cidr = "10.0.0.0/8", interface = "utun" })
    assert.equals("connected", state)
    assert.equals("10.11.12.13", address)
  end)

  it("ignores addresses on interfaces the probe does not name", function()
    assert.equals("disconnected", parse.probeState(IFCONFIG, { cidr = "192.168.0.0/16", interface = "utun" }))
  end)

  it("looks everywhere when no interface is named", function()
    assert.equals("connected", parse.probeState(IFCONFIG, { cidr = "192.168.0.0/16" }))
  end)

  it("is unknown, not disconnected, without a usable probe", function()
    assert.equals("unknown", parse.probeState(IFCONFIG, nil))
    assert.equals("unknown", parse.probeState(IFCONFIG, {}))
  end)
end)
