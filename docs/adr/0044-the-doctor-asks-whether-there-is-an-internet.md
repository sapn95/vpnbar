# 0044 — The doctor asks whether there is an internet

**Status:** accepted, 2026-10-17.

## What happened

An evening tethered to a phone. The Mac had joined the hotspot, a default route
was installed, the phone answered every packet addressed to it, and there was
nothing behind the phone: it had grown hot and switched its own mobile data off.

From inside the machine this is indistinguishable from working. `vpnbar doctor`
said everything was in place, and everything it looked at was. A reboot changed
nothing, because nothing on the Mac was broken. The time went instead on the
VPN, which was the one part of the picture that could not have been at fault.

## The decision

`vpnbar doctor` asks three questions about the network before it asks anything
about a tunnel, and reports the first one that fails:

1. **Is there a default route at all?** Without one nothing leaves the machine,
   and no VPN and nothing in this menu can change that.
2. **Does a name resolve?** Reaching anything by name needs this first, and a
   failure here is on the machine rather than beyond it.
3. **Is there anything behind the first hop?** This is the hotspot, and it is
   the only one of the three that the machine cannot answer on its own.

The first hop is pinged, but afterwards and only where it adds something: when
nothing answers, it tells a hotspot with no data of its own from a Wi-Fi that
joined and was handed nothing. It is never a prerequisite for the probe. Plenty
of gateways drop ICMP, and reporting a broken first hop on a working connection
is a wrong answer in the direction this section exists to avoid.

The third is asked of `http://captive.apple.com/hotspot-detect.html`, which is
the endpoint macOS itself polls whenever a network changes. Asking it once more
names nobody the machine was not already talking to and sends nothing about the
machine. What it serves is one short page titled `Success`, which is what makes
a captive portal a separate answer rather than a missing one: a portal replies,
and replies something different.

The match is on `<TITLE>Success</TITLE>` rather than on the word. A portal's own
page can carry "Success" in its prose, a sign-in form promising to say so once
you are through, and a portal read as reachable is the one answer this must
never give.

The lookup is asked on its own, with `dig`, before the page is requested. Left
inside `curl` it is indistinguishable from the thing it has to be told apart
from: a resolver that has stopped answering spends the whole of `--max-time` in
the lookup and `curl` reports a timeout, which reads exactly like a gateway with
nothing behind it. So the name gets its own question and its own line, and
`curl`'s own "could not resolve host" is kept as a second line of defence.

That answer is the fault being on this machine, which is the opposite of what
the third question would otherwise report, and this script already finds two
ways to get there: a dead VPN that left its resolvers behind, and resolvers
whose route went with an aggregate. The report points at those two lines
instead of at the phone.

Each question gets three seconds. A doctor nobody waits for is a doctor nobody
runs.

## Why this section comes first

Every other line in the report reads differently once the uplink is known to be
down. A tunnel that will not come up, a resolver that answers nothing, a client
whose window says *Failed to connect*: with no internet behind the gateway all
three are consequences, and reporting them above the cause is how an evening
goes into the wrong half of the machine.

## What was rejected

- **Pinging a public address, or making the local ping a gate.** ICMP is dropped
  often enough, on the way out and at the first hop, that either would report a
  working network as broken.
- **Resolving a name through the configured resolvers, as the whole test.** A
  name that resolves says nothing about the uplink: on 16.10.2026 `curl`
  returned 200 from the system resolver's cache while every configured resolver
  was timing out, so the answer and the state of the network had come apart in
  both directions at once. On a captive portal a resolver answers with the
  portal's own address, which reads as success.
- **An endpoint of our own.** It would name a third party the machine was not
  already speaking to, and it would have to be kept alive for a diagnostic.
- **Watching it on a timer in the Spoon.** A menu bar item that asks the
  internet every ten seconds whether it exists is a different program. The
  question belongs to `doctor`, which somebody runs when something is wrong.
