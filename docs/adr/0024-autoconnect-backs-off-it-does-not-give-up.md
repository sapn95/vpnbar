# 0024 — Autoconnect backs off, it does not give up

**Status:** accepted, 2026-09-11. Replaces the give-up rule in
[ADR 0013](0013-autoconnect-is-a-plan-not-a-timer.md).

## The decision

`autoconnect.ATTEMPTS_BEFORE_GIVING_UP` is gone. The gap between attempts
doubles instead, from `COOLDOWN` up to `COOLDOWN_CEILING`, and then stays there:
one minute, two, four, eight, then every fifteen for as long as it takes.

`autoconnect.cooldown(attempts)` always returns a number of seconds. There is no
attempt count at which it answers "stop".

## What went wrong

Same evening as [ADR 0023](0023-an-unlock-is-a-fresh-start.md), and the unlock
handler alone would not have been enough.

```text
20:15:56  the gateway ended the session
20:17:00  the protected connection: two tries, then over to its fallback
20:21:10  the fallback: six tries, then stop
20:52:57  still down, still nothing trying
```

Half an hour with an always-on VPN down and nothing in the machine attempting to
change that. Six failures inside four minutes is not evidence that a connection
is unreachable, it is evidence that six attempts went out inside four minutes.
The old rule confused a burst of failures with a verdict.

## Why a ceiling rather than a limit

The reasoning behind the limit was real: a laptop on a train should not spend its
battery on a portal it cannot see. A ceiling answers that without the part that
was wrong. Failing all night now costs four attempts an hour instead of
stopping, which is not a battery problem, and it removes the state this project
exists to remove, which is an always-on VPN that is down while the thing meant
to bring it up has decided not to.

Fifteen minutes is also about what an attempt costs on screen. Connecting the
`globalprotect` backend means opening the agent's panel and clicking in it
([ADR 0001](0001-globalprotect-is-not-a-scutil-vpn.md)), so a retry is visible.
Four an hour is a flicker; one a minute, forever, would be a fault of its own.

## What this does not buy

A session the gateway has **ended** does not come back by being asked. It wants
a federated login in a browser, finished by a person. Retrying cannot do that
and nothing here pretends otherwise.

What the backoff changes is the other case, and it is the common one: the tunnel
dropped while the session is still good. That comes back on its own now, at any
hour, without anybody being at the machine. Where it cannot, the connection is
retried slowly and quietly until somebody arrives, and an unlock puts it back on
the fast path immediately ([ADR 0023](0023-an-unlock-is-a-fresh-start.md)).

## What was rejected

- **Keeping the limit and only resetting it more often.** Every reset trigger is
  a guess about when the world changed. Locking the screen is not the only thing
  that happens while nobody is looking, and the next missed trigger would be
  another evening like this one.
- **A fixed short retry forever.** One attempt a minute all night is a panel
  opening on screen sixty times an hour when somebody is at the machine, and it
  is the portal hammering the original rule was written to prevent.
- **Backing off without a ceiling.** Doubling forever reaches a day between
  attempts by the twelfth failure. A VPN that would connect fine is then down
  until somebody notices, which is the failure this ADR is removing.
- **Giving up only on battery.** It makes the rule depend on the power state at
  the moment of the sixth failure, which is not something anybody could predict
  from the menu, and the ceiling already makes the battery question moot.
