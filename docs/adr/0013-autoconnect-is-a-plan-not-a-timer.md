# 0013 — Autoconnect is a plan, not a timer

**Status:** accepted, 2026-09-01.

## The decision

`autoconnect.plan(config, states, memory, now)` returns **at most one** thing
to connect, or nothing. It has no timers, no state of its own and no side
effects; the adapter calls it on the refresh that already runs, acts on the
answer, and owns the memory table it passes in.

The policy that lives there:

| | |
| --- | --- |
| cooldown | 60 s before the same connection is asked again |
| attempts before the fallback | 2 |
| attempts before giving up | 6, until something clears the memory |
| cleared by | the connection coming up, a wake, switching autoconnect on |
| never touched | `connecting` (already on its way), `unknown` (nothing is known) |
| tidied up | the fallback is disconnected once the wanted one is up |

## Two tunnels to the same place

Not twice the connectivity: one routing table with an argument in it. So when
the connection somebody actually wanted comes up, the stand-in that was started
while it was down is taken back down again — and that check runs *before* the
connect rules, because the alternative is briefly having three.

Only what autoconnect itself started, tracked in the same memory table. A
tunnel opened by hand is not this function's to close, and neither is a
protected one ([ADR 0008](0008-an-always-on-vpn-is-protected-from-being-disconnected.md)).

## Why one action per refresh

Two VPNs coming up at the same moment is a routing table nobody asked for, and
the second one usually wins by accident. The next refresh takes the next one,
ten seconds later, by which time the first has an answer.

## Why a fallback is tried second and not in parallel

The connection somebody configured is the one they want. Falling back is an
admission that it is not available, and making that admission after two tries
rather than immediately is the difference between "the split-tunnel endpoint is
down" and "the wifi had not come up yet".

## Why it gives up

A laptop on a train would otherwise ask a portal it cannot reach every ten
seconds until the battery is flat. Six failures buys the state a wake, a
network change or a click to clear it — all three of which are events that make
the old failures meaningless anyway.

## Why the policy is not in the adapter

Because every one of those numbers, and the order the rules run in, is a
decision, and a decision inside a timer
callback can only be checked by waiting. In a module it is nineteen tests that
run in a hundredth of a second.
