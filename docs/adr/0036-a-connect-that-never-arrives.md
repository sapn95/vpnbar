# 0036 — A connect that never arrives

**Status:** accepted, 2026-10-04. Narrows
[ADR 0013](0013-autoconnect-is-a-plan-not-a-timer.md), which said to leave
`connecting` alone, and
[ADR 0026](0026-one-at-a-time-outranks-protection.md), which counts it as up.

## The decision

A connection that has said `connecting` for two minutes is planned from as
though it said `disconnected`. The state the menu shows is untouched: the agent
says connecting, so the row says connecting.

## Why it was left alone in the first place

Because it is already on its way. Asking again presses Connect on top of a
handshake, and a menu that does that is a menu that opens two sessions or ruins
one. That reasoning holds for every handshake that finishes.

It stops holding when one does not. The agent goes on reporting `connecting`,
nothing arrives, and because one-at-a-time treats a connection that is coming up
as one that is up, the stand-in ranked below it is held down for as long as the
agent keeps saying it. The connection that was supposed to be the safety net is
the one thing the stuck handshake switches off. That is the cost, and it is
unbounded.

## Why two minutes

A GlobalProtect connect that works is done in seconds on this machine: the
measured sequence from the event log is `Auto Gateway login finished` to `IPSec
tunnel creation finished` in two seconds, and the SAML round trip in front of it
is a person at a browser rather than a handshake. Two minutes is longer than any
of that and short enough that a stand-in is useful while it is still the same
afternoon.

## Why the view and not the state

`autoconnect.settled` returns a copy. The menu draws from the same table, and a
row reading "disconnected" while the agent is still reporting a handshake would
be the planner lying to the person rather than to itself. What the person sees
stays what the agent said; what the planner does is based on how long it has
been saying it.

## What was rejected

- **Pressing Disconnect first.** It is the repair a person would do by hand, and
  it is also a disconnect, which is refused on a protected connection
  ([ADR 0008](0008-an-always-on-vpn-is-protected-from-being-disconnected.md)).
  Reading the state as down reaches the same place through rules that already
  exist: the connect is asked for again, its own backoff applies, and the
  fallback gets its turn.
- **Restarting the client.** Too large for a handshake that may simply be slow,
  and it ends the session ([ADR 0033](0033-stopping-an-agent-that-launchd-restarts.md)).
- **Showing it as disconnected in the menu.** The agent is the source of what a
  connection's state is. Two minutes of patience is a planning decision, not a
  correction of what the agent reported.
