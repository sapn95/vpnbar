# 0046 — A switch presses what it cannot read

**Status:** accepted, 2026-10-30. Amends the "never touched" row of
[ADR 0013](0013-autoconnect-is-a-plan-not-a-timer.md), which stands for
everything autoconnect does on its own.

## What happened

He pressed *Switch to AWS VPN (sbb)* and nothing happened, for the third time
in two weeks. The log of his own click says it in two lines:

    09:49:14  switch: aws is preferred until restart
    09:49:15  AWS VPN (sbb): AWS VPN Client offers no Connect right now

And then nothing, for the whole ten minutes a switch is supposed to keep
asking. `switchTo` presses once by itself, which is the press that failed. Every
press after that is the planner's, and the planner never pressed, because the
state it had for that connection was `unknown` and `unknown` is the one state it
never touches.

The state was `unknown` because the AWS client changed what it writes to its
log. Measured across three days of his own logs:

| log | lines the reader knew | lines it did not |
| --- | --- | --- |
| 28.10. | 213 | 285 |
| 29.10. | 0 | 439 |
| 30.10. | 0 | 198 |

Client 6.0.3 stopped writing `Tray state changed to` and `Refresh state:`
between the 28th and the 29th, and writes `[poll] Profile disconnected: <name>`
instead. The reader knew none of it, found nothing, and answered `unknown` from
the 29th of October until he said the switch did nothing on the 30th.

## The decision

Two changes, and the second is the one that matters.

**The reader learns the line.** `[poll] Profile disconnected: <name>`, named the
same way the connected line is, because another profile going down says nothing
about this one. His `sbb` reads `login` again instead of `unknown`.

**A switch presses a state nobody could read.** `unknown` stays untouchable for
everything autoconnect does on its own, for the reason ADR 0013 gives: pressing
an unreadable connection on a timer is how a probe nobody configured turns into
a login prompt every ten seconds. A switch is the exception and the only one.
Somebody is standing there having said "this one, now"; the asking is already
bounded to `SWITCH_PATIENCE` and paced at `SWITCH_RETRY`, and it stops the
moment anything is readable. Being wrong therefore costs at worst a press every
thirty seconds for ten minutes, each one logged, on a connection somebody had
just asked for by hand.

That is the half that survives the next time a vendor renames a log line. The
first half fixes today.

## The reader says when it has gone deaf

A log that exists and holds nothing this reader knows is a different thing from
no log at all, and it is the one worth shouting about: silently unreadable is
how a day went by with a button that did nothing and said nothing. The answer
on stdout is still `unknown`, because callers parse it, and the complaint goes
to stderr, where a person reads it. One list of known markers serves both the
parser and the complaint, so the client cannot change its wording and leave the
warning quiet, and it lists the state *values* rather than their prefixes: a
`Tray state changed to idle` would satisfy a check on the prefix and still
leave the parser with nothing.

## What was rejected

- **Reading the client's window instead of its log.** The window is the thing
  being pressed. Asking it what state it is in means opening it, which is the
  cost ADR 0027 moved away from.
- **Treating `unknown` as down everywhere.** It is a guess, and it was wrong
  about a live tunnel once already, which is what ADR 0027 was written about.
- **A `vpnbar doctor` check for an unreadable log.** `doctor` has no profile
  name to ask about, and inventing the config plumbing to give it one is more
  than this fault is worth.
- **Leaving the switch alone and only fixing the marker.** It would work until
  the next release of somebody else's client, and the symptom it leaves behind
  is a button that does nothing and says nothing.
