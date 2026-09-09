# 0018 — Nothing waits for a read

**Status:** accepted, 2026-09-10.

## The problem

Every read here is synchronous: `ifconfig`, a shell helper, and on demand an
accessibility tree that sleeps in tenth-of-a-second steps waiting for a window to
appear. One at a time they are cheap. `ifconfig` and the AWS status helper both
come back in about twenty-five milliseconds on this machine. What was expensive
was *when* they ran.

- `start` read the state before the status item was drawn, and Hammerspoon loads
  a Spoon while it is still starting up. So after login there was a gap with no
  icon and nothing on screen to explain it.
- `setMenu`'s callback read the state before returning any rows, so the click that
  opens the menu waited for the shell.
- The wake watcher read once, at the instant `systemDidWake` fires. Wi-Fi has not
  associated by then. That read saw a machine with no route, reported every tunnel
  as down, and let autoconnect spend an attempt, plus its sixty-second cooldown,
  on a connection that could not possibly have come up.

## The decision

The icon goes up first and the reading happens behind it. `obj:refreshSoon` claims
the busy mark, paints, hands the run loop back with `hs.timer.doAfter(delay, …)`,
and reads in the callback. `start` uses it, so there is a marked, moving icon in
the bar from the moment the Spoon loads.

The menu is built from the last read. The config is still re-read on every open,
because a hand edit should show up without a reload and that is one cheap
`io.read`. The states are not. They come from the last poll, and a fresh read is
queued behind the menu rather than in front of it. The poll interval bounds how
stale that can be, the queued read has the icon right by the time the menu closes,
and **Refresh now** is there for anyone who wants to force it.

A wake gets a schedule. `work.WAKE_READS` looks at two, six and fifteen seconds,
and only the last of the three may start something. The early looks report, so the
menu bar stops claiming a tunnel that sleep took down. The decision to bring one
up waits until there is a network to bring it up over. All three are claimed at
the moment of the wake, which is also what keeps the mark moving until the state
has settled.

The reading itself is wrapped in `pcall`, so a read that throws still releases
the mark, and a `running` flag makes a job queued before a quit return without
running commands for a menu that is no longer there.

## Why not make the reads asynchronous

`hs.task` and a callback per read is the textbook answer, and it would be the
right one if any single read were slow. None of them are. What it would cost is
the shape of the thing. `backends.status(profile, runtime)` returns a state, and
that is what lets `backends_spec.lua` drive every branch of every backend with a
table of canned answers ([ADR 0002](0002-a-pure-core-and-a-thin-shell.md)).
Making it asynchronous turns the pure core inside out to solve a scheduling
problem that scheduling solved.

## What was rejected

- **A shorter poll interval.** More reads, same latency at the two moments that
  actually looked broken.
- **Reading synchronously in `setMenu` but only when the states are stale.** Half
  the opens fast and half of them slow is worse than all of them fast: an
  interface that is sometimes quick teaches you nothing about what to expect.
- **Blocking on `hs.network.reachability` after a wake.** Waiting for a route is
  the same wait, spent inside the wake handler where nothing can be drawn.
