# 0003 — An interface probe beats asking the app

**Status:** accepted, 2026-09-01.

## The problem

The menu polls. Every poll needs a state per connection, and the three ways of
getting one are not equally priced:

| Way | Cost |
| --- | --- |
| Read `ifconfig` | One command for the whole menu, nothing on screen |
| `scutil --nc status` | One command per connection |
| A `shell` status command | Whatever the user's command costs |
| Open an agent's panel | A window appears on screen, every time |

The last one is not a poll. It is a window opening every ten seconds.

## The decision

A profile may carry a `probe` — a CIDR that only that VPN hands out, and
optionally an interface prefix. Where a probe is configured it answers, and the
backend is not asked at all.

Panel reads are allowed **only** for an explicit refresh: the timer builds its
runtime with `allowPanelReads = false`, and `runtime.panel` then returns
`unknown` without touching anything.

## What follows from it

- A `globalprotect` connection without a probe shows `unknown` until somebody
  clicks **Refresh now**. That is a documented, visible gap rather than a
  window that opens by itself, and the fix is one line of config.
- `unknown` stays clickable. Refusing to act because a probe was not configured
  would make a missing setting look like a broken tunnel.
- A probe matching a range something else also uses reports a tunnel that is
  not there. The documentation says to pick a block unique to that VPN; nothing
  can check it.
