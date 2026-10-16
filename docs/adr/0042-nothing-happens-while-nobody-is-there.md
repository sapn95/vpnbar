# 0042 — Nothing happens while nobody is there

**Status:** accepted, 2026-10-16. Widens
[ADR 0029](0029-an-attempt-that-needs-a-person-waits-for-one.md), which held
only the one state that opens a login window.

## What was measured

The screen was locked from 2026-10-15 18:00 to 22:33, which
`~/.hammerspoon/logs/lock-sleep-policy.log` records as `locked` on every line in
that window. vpnbar pressed Connect on GlobalProtect twenty times across it, at
the fifteen-minute ceiling of the backoff, and every one of them came back:

    GlobalProtect offers no "connect" right now

Twenty attempts that could not succeed, because the panel they press is not
drawn while the screen is locked. Each of them also spent a slot in the backoff
that a real attempt would have wanted.

## The decision

While nobody is at the machine, the planner takes nothing down and presses no
window. A connection a command can reach is still connected, which is the case
autoconnect exists for.

"Nobody is there" is the screen being locked, or `IDLE_BEFORE_AWAY` seconds
without a keystroke or a click. Five minutes: long enough that reading a page is
not being away, short enough that a tunnel is not taken down under somebody who
stepped out. A context that measured neither says nobody is away, because a rule
that read "not measured" as "away" would stop an unattended machine from ever
connecting.

## Why nothing is taken down either

That is the half that was asked for. `supersede` and the stand-in's
`disconnect` both run unattended, so a person who locks the screen with two
tunnels up can come back to one, or to none, with nothing in the menu saying
why. One at a time is about what a person is using; nobody is using either of
them. The pass after the unlock sorts it out, which is seconds later and under
somebody who can see it happen.

## Why the split is per backend and not per profile

`scutil --nc start` and a `shell` profile's connect command run the same whether
or not anybody is at the machine. A GlobalProtect panel and the AWS client's
window are drawn for a person and are not there without one, so
`backends.pressesInterface` is a property of the backend, named once, rather
than a flag somebody has to remember to set on a profile.

## What is not changed

The backoff, the quit holds ([ADR 0031](0031-autoconnect-does-not-undo-a-quit.md))
and the login hold still apply while away: being away adds reasons to wait, it
removes none. **Disconnect everything** is a person asking by name and is not
affected ([ADR 0041](0041-everything-means-everything.md)), and neither is any
other menu row: this is a rule about what runs on a timer.

## What was rejected

- **Reading the lock state out of the policy's log file.** vpnbar already asks
  `hs.caffeinate` for it directly and gets the same answer sooner. The log is
  what the measurement above was checked against, not a source to parse.
- **Holding everything while away, commands included.** The one thing worth
  having on an unattended machine is a tunnel that comes back by itself.
- **Pressing anyway and treating the failure as a normal attempt.** It is what
  happened for twenty attempts, and the backoff spent on them is why the first
  attempt after the unlock was fifteen minutes away.
