# 0047 — A tunnel that carries nothing

**Status:** accepted, 2026-11-10. Amends
[ADR 0030](0030-a-switch-is-a-preference-not-an-order.md): a switch is over
once its target carries, not once it reads `connected`. Adds `renew` beside
`supersede` ([ADR 0026](0026-one-at-a-time-outranks-protection.md)) and the
restart of [ADR 0034](0034-a-protected-connection-keeps-its-repair.md) as a way
down that protection allows.

## What happened

He switched from the AWS tunnel to GlobalProtect. The switch pressed until
GlobalProtect came up, the AWS tunnel went down, and the menu said
GlobalProtect was connected. Nothing behind it answered. From his logs and the
console, with the times of 10.11.2026:

| time | what | where it is written |
| --- | --- | --- |
| 23:11:25 | the switch presses GlobalProtect's Connect | console |
| 23:11:38 | `Route 10 shadows access route 10.0.0.0/8`, and the same for `172.16/12` and `192.168.0/16` | `PanGPS.log` |
| 23:11:39 | GlobalProtect's tunnel is up | `pan_gp_event.log` |
| 23:11:43 | the AWS tunnel is gone, and its routes with it | the AWS daemon's log |
| 23:11:43 | `route change detected`, and nothing installed after it | `PanGPS.log` |
| 23:11:45 | `switch: globalprotect is up and alone` | console |
| 23:15:03 | GlobalProtect taken down by **Disconnect everything** | `pan_gp_event.log` |
| 23:15:29 | up again, this time with all of its routes | `pan_gp_event.log` |

GlobalProtect installs its routes once, while the tunnel comes up, and skips
every one that is already routed somewhere else. At 23:11:38 the AWS tunnel held
all three private aggregates, so GlobalProtect installed none of them. Five
seconds later the AWS tunnel went, the aggregates went with it, and
GlobalProtect never looked again. For three minutes and twenty seconds the
interface was up, the address was on it, the mark said connected, and every
address behind the tunnel left by the Wi-Fi. The default route does not count
as taken: it was in the table both times, and at 23:15:28, with the AWS tunnel
gone, GlobalProtect installed all of its routes.

The AWS tunnel was disconnected by hand that evening, from its own tray menu.
The planner would have done the same one pass later: the switch takes the other
connection down once its target reads `connected`
([ADR 0030](0030-a-switch-is-a-preference-not-an-order.md)), and *Only one
connection at a time* takes the stand-in down once the preferred connection is
back. Every switch from the AWS tunnel to GlobalProtect, and every return from
that fallback, ends the same way.

## The decision

**A probe may name an address that has to leave through the tunnel.**

```json
"probe": { "cidr": "10.0.0.0/8", "interface": "utun", "reach": "10.0.0.10" }
```

A probe without `reach` says what it always said: a tunnel exists
([ADR 0022](0022-a-probe-reads-the-interface-not-just-the-address.md)). With
one, every refresh also asks which interface a packet to that address leaves
by, and whether that is the tunnel's. The question is answered from
`netstat -rn`, which the refresh already reads for
[ADR 0035](0035-a-dead-tunnels-routes-are-swept-up.md), by the rule the kernel
uses: the longest prefix that covers the address wins. Two kinds of row are left
out. The IPv6 table has `default` rows of its own, and one of those read as IPv4
is a route to everything. Scoped rows, flagged `I`, carry only traffic already
bound to their interface, with one exception the kernel makes: when the
unscoped lookup ends at `default`, it looks again in the scope of the primary
interface, so a narrower scoped row on that interface wins there. The tunnel's interface is every live one the probe
accepts, so a range two tunnels happen to share gives the same answer on every
read. A range only this VPN hands out, which is what a probe is for, has one.

**Up without its route is shown, and said once.** The row reads `⊘` and *up,
but carries nothing*, and its tooltip names the interface the address leaves by
instead. The mark keeps the filled body of a tunnel that is up and opens the
shackle, which is the one shape that means nothing goes through. A connection
that really is up speaks for the mark before this one does, and this one is not
counted among the tunnels that are up. After twenty seconds a notification says
the same sentence. A tunnel arrives address first and routes second, and on
10.11.2026 the routes followed the address within two seconds, so a tunnel
still without them after twenty seconds is not one that is still arriving.

Decisions keep reading the state as `connected`. The tunnel holds an interface
and an address, *Only one connection at a time* still counts it, and
**Disconnect everything** still has to take it down.

**A switch is over once its target carries.** `switch: … is up and alone` is
only written when it is true. A switch that runs out of patience with its target
up and carrying nothing says so.

**A tunnel that carries nothing is renewed: taken down once, so that it comes
back with routes of its own.** The planner asks for it under its own verb, after
any supersede, and only when all of this holds:

- Every other tunnel is down, so that the reconnect finds nothing in its way.
- Nothing but the default route covers the address. A narrower route belongs to
  something else, a network that is itself `10.0.0.0/8` for one, and a
  reconnect leaves it where it is: the same prefix shadows the new route the
  way the AWS tunnel did, and a longer one wins over it anyway.
- The planner brings it back up afterwards: it is marked to autoconnect, or it
  is the one somebody switched to. Anything else would be taken down and left
  there.
- Somebody is at the machine ([ADR 0042](0042-nothing-happens-while-nobody-is-there.md)),
  its client is running, and no switch is pressing for another connection.
- It is the first renew of the incident. A press that was refused (no panel, or
  no Disconnect in it) took nothing down and cost nobody a login, so it is tried
  again every thirty seconds for ten minutes, the way a switch keeps asking. A
  press that went through is not repeated within the hour. The record is
  dropped the moment the connection carries again, so the next incident gets a
  renew of its own at once.

Protection allows it, for the reason it allows a restart: it ends with the
tunnel up. Once the renew has taken it down, the connect that brings it back is
pressed for the way a switch's target is: every thirty seconds, not held for a
quiet moment, with nothing else started meanwhile, for as long as a switch would
press. The hold ends when the tunnel carries again, not when it says connected:
a tunnel reports connected before its routes arrive. It is also dropped for a
connection the loop would no longer start, one whose autoconnect was switched
off or whose client was closed, so that nothing else waits on it. Holding it back while somebody types would leave the machine on nothing
for as long as the typing lasts, and a stand-in that came up in the gap would
hold the routes again, so the connection would come back as empty as it went.

The first try of an incident is said, whatever came of it: that a reconnect is
under way, or what refused it and that it will be tried again. If every try is
refused, that is said once more when the ten minutes are up, so that somebody
knows to reconnect it by hand.

## What it costs

A renew is a disconnect, and GlobalProtect logs the session out on one (`User
was logged out of Gateway` at 23:15:05). The connect after it is a new login.
On 10.11.2026 that login finished by itself from the cached identity, with the
portal answering half a second after it was asked, and the tunnel was back 9.4
seconds after the connect started. A login window is still possible
once the cached identity has expired. It is the same window a reconnect by hand
would open, and the notification says it may come.

## What was rejected

- **Taking the old tunnel down before the new one connects.** It avoids the
  shadow. But that evening GlobalProtect could not be pressed at all for eight
  minutes, because it had no menu-bar item, and the AWS tunnel was the only
  thing carrying traffic meanwhile. Taking it down first would have made those
  eight minutes eight minutes without a VPN.
- **Adding the missing routes by hand.** It needs an administrator, and the set
  is GlobalProtect's: thirty-three routes on this machine, whatever its gateway
  pushes next week. Copying them would be a guess about somebody else's
  configuration.
- **A request to a host behind the tunnel.** One per refresh to a work host,
  with an answer that depends on that host. The route table answers the
  question that decides it, where the packet goes, for nothing.
  [ADR 0044](0044-the-doctor-asks-whether-there-is-an-internet.md) makes the
  same point about names that resolve.
- **Reading `PanGPS.log` for the shadow line.** A vendor's debug log, written
  in a format nobody promised to keep. The route table shows the result
  whatever caused it.
- **Renewing whenever it carries nothing.** On a network whose own routes cover
  the address, every reconnect would be shadowed again, and every one would be
  a login.
