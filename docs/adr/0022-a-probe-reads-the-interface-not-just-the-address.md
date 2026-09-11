# 0022 — A probe reads the interface, not just the address

**Status:** accepted, 2026-09-11.

## The decision

`parse.probeState` only looks at interfaces whose `ifconfig` flags say **UP and
RUNNING**. An address on any other interface is ignored, whatever block it falls
in.

`parse.ifconfigAddresses` became `parse.ifconfigInterfaces` and now returns
`{ up = boolean, addresses = string[] }` per interface. The flags were always on
the line being parsed; the old version read the name off it and threw the rest
away.

## What went wrong

The agent's tunnel dropped at 04:04 on a sleeping laptop, on a keep-alive
timeout. It gave up retrying at 08:13. The connection came back at 08:16,
because somebody started it by hand in order to work.

For those four hours the menu said **connected**.

The agent's own log says exactly what it did on the way down:

```text
Uninstalling routes...
Uninstalling interface ...
Route change message RTM_IFINFO: iface status change, utun4 down
```

It pulled the routes, brought the interface down, and left the address sitting
on it, because it intended to retry into the same interface. `ifconfig` keeps
printing that address. The probe asked one question, "is there an address in
this block on an interface with this name", and the answer stayed yes long after
the tunnel had gone.

## Why this was worse than a wrong icon

[ADR 0013](0013-autoconnect-is-a-plan-not-a-timer.md) only ever asks a
`disconnected` connection to come up, and [ADR 0008](0008-an-always-on-vpn-is-protected-from-being-disconnected.md)
is why that connection is also the one set to autoconnect. A state that reads
`connected` is a state autoconnect leaves alone. So the false positive did not
merely draw the wrong glyph: it disarmed the reconnect and the fallback for the
whole four hours, and the repair a person had to perform by hand is the one the
menu exists to perform on its own.

The menu lying about a tunnel is the failure the README calls worse than having
no menu. This is that failure, found in the wild rather than in a test.

## Why UP and RUNNING, not UP alone

Clearing UP is what the incident did, so UP alone would have caught it. RUNNING
is the stricter half and it is free, because both come out of the same line.

The two directions of error are not symmetric. A false negative means the menu
says down while a tunnel is up: autoconnect asks it to connect, the backend
finds it already connected, and the next read corrects the display. A false
positive is four hours of a disarmed safety net. When the cost is that lopsided,
the stricter test wins, and an interface line with no flags on it at all reads
as down for the same reason.

Every interface on the machine that was genuinely carrying traffic had both
flags, tunnels included.

## What was rejected

- **Checking the routing table as well.** The agent uninstalls its routes 322 ms
  before it brings the interface down, so a route check closes a third of a
  second that the flag check does not. A refresh landing inside that window is
  corrected ten seconds later. It is a second command per refresh for a gap that
  heals itself.
- **Probing by reachability, a ping through the tunnel.** It answers the real
  question, and it was measured at 17 ms. But it turns a read that touches
  nothing into traffic every ten seconds, it needs a host that is willing to
  answer forever, and a host that stops answering becomes a VPN that reads as
  down. [ADR 0003](0003-a-probe-beats-asking-the-app.md) says a probe wins
  because it costs nothing; this would have spent that.
- **Reading the agent's event log.** It is authoritative and world-readable, and
  it is the thing that diagnosed this. It is also a vendor log format, at a path
  the vendor chose, rotated on the vendor's schedule. Parsing it would put a
  supported feature on an unsupported contract.
- **Treating a stale address as `connecting`.** It is a fair description of what
  the agent is doing during the retry, and it is the wrong answer anyway:
  `connecting` is also left alone by autoconnect, so the bug would have survived
  under a better name.
