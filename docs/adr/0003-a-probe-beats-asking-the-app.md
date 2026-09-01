# 0003 — An interface probe beats asking the application

**Status:** accepted, 2026-09-01.

## The decision

A profile may carry a `probe` — a CIDR, optionally narrowed to an interface
name prefix. When it is set, the state is decided by looking for an address in
that block in one `ifconfig`, and the backend's own answer is not asked for.

Where a profile has no probe, the backend answers. For `scutil` that is one
cheap command. For GlobalProtect it means **opening the panel**, so that read
is allowed only on an explicit *Refresh now* — never on the timer, and never
when the menu is merely redrawn.

## Why

The timer runs every ten seconds for as long as the Mac is awake. A state read
that opens a panel, at that cadence, is a menu that takes the screen away from
whoever is using it. The probe is one `ifconfig` for the whole set — parsed
once per refresh, not once per profile — and it costs nothing.

It is also more truthful. The panel says what the agent believes; the interface
says what the routing table will actually do with a packet.

## What follows from it

A GlobalProtect profile with no probe shows as **unknown** rather than lying,
and its menu entry stays clickable anyway: refusing to act because a probe was
never configured would make an unconfigured probe look like a broken VPN.
