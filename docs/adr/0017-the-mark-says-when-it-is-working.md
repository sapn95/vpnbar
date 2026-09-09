# 0017 — The mark says when it is working, and the busy state is a count

**Status:** accepted, 2026-09-10.

## The problem

The icon had four pictures and only ever showed two of them. On a machine with an
always-on tunnel the state is `connected` from login until shutdown, so starting
up, waking, and a click that takes several seconds to land all looked exactly
like an idle menu bar. The reading was right. What the mark could not say was
that a job was running, because it was drawn from the table of states alone and a
state table has nowhere to put that.

The busy picture existed all along. `menu.overall` ranks `connected` above
`connecting` on purpose, so on the machine that needed it most it was
unreachable.

## The decision

The mark is drawn from two inputs:

```lua
menu.indicator(states, busy)  --> the state to draw
```

`busy` wins over everything settled, and a connection reporting `connecting`
counts as busy too. `obj:paint` in the adapter is the only place that touches the
icon. A mark that depends on two inputs and is set from three places drifts
within a release.

Busy itself is a count with a deadline, in `vpnbar/work.lua`. A count, because
jobs overlap here as a matter of course: a click that opens an app's window while
the timer reads the state, and the read finishing first must not clear the mark
for the click. A deadline, because a release lost to an error somewhere else
would leave the mark up for the rest of the session. Past its deadline a job is
assumed gone and the icon goes back to reporting what it knows. Asking
`work.busy` is what expires it, so there is no timer to sweep it and no state
that only a restart clears.

Three things claim it: the first read after `start`, every read in the wake
schedule, and an action from the moment of the click to the state that comes back
after it.

## Why it moves

A still picture answers "is it working?" with a picture you have to remember the
previous value of. So the busy dot breathes instead, out and back over the four
frames of `icon.PULSE`, redrawn three times a second, and the timer that does it
runs only while there is something to say. Two frames alternating was tried
first and reads as a fault light rather than as progress.

The frames are cached like the settled marks, so the animation costs a `setIcon`
and not a new bitmap.

## What was rejected

- **Dimming the underlying mark while busy.** Composes nicely, needs no new
  picture, and is invisible at a glance on a bright screen — which is the whole
  job.
- **A fifth state, `working`, in the icon.** It would have made the existing
  `connecting` mark dead code from the adapter's side while keeping it alive in
  the tests. Reusing `connecting` is what makes the unreachable picture
  reachable, and `LABELS.connecting` already reads "working…".
- **A spinner glyph or `…` in the title.** Text next to the icon is reserved for
  the count of tunnels, and two things competing for that slot means neither is
  legible.
- **Reranking `PRECEDENCE` so `connecting` wins.** It answers a different
  question, the worst-to-best ranking of settled states, and it answers it
  correctly. That is why the busy signal went beside it rather than into it.
