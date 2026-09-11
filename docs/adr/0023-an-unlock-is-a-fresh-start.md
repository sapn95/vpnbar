# 0023 — An unlock is a fresh start

**Status:** accepted, 2026-09-11.

## The decision

The `hs.caffeinate` watcher handles **`screensDidUnlock`** as well as
`systemDidWake`, and both run the same thing: forget what autoconnect has tried,
then read on the `work.WAKE_READS` schedule.

Because waking a locked Mac fires both, `work.freshStart(lastAt, now)` swallows
the second one. `work.FRESH_START_DEBOUNCE` is 20 seconds, which outlasts the
last of the wake reads.

## What went wrong

The gateway logged the session out at 20:15. Autoconnect did exactly what
[ADR 0013](0013-autoconnect-is-a-plan-not-a-timer.md) says it should:

```text
20:15:56  tunnel down, user logged out of the gateway
20:17:00  the protected connection: two tries, then over to its fallback
20:21:10  the fallback: six tries, then stop
20:52:57  unlocked, and nothing happens
```

Stopping after six is deliberate. A menu that retries a portal forever is a menu
that locks an account. The record clears when the connection comes up, when the
Mac wakes, or when the person toggles the setting.

The screen had been locked, not slept. `systemDidWake` never fired, so none of
those three happened, and half an hour of recorded failures from before the lock
still counted as current. The person came back to a machine that had given up
and had no way of knowing they had returned.

## Why an unlock earns it

ADR 0013 already makes the argument for a wake: a portal that was unreachable
behind a closed lid says nothing about the network in front of an open one. The
same sentence is true of a locked screen. A machine that has been sitting locked
has had no reason to notice that it moved, or that the Wi-Fi changed, and the
failures it recorded belong to the network it used to be on.

There is a second half that the wake case does not have. An unlock is a person
arriving. It is the moment they are about to want the VPN, and the moment they
are present to finish a login if one is needed. A wake can happen to an empty
desk; an unlock cannot.

## What this does not buy

It makes vpnbar try again. It does not make it able to log in. Where the gateway
has ended the session rather than dropped the tunnel, connecting means a fresh
federated login in a browser, and that is finished by a person no matter what
starts it ([ADR 0009](0009-the-aws-vpn-client-is-driven-through-openvpns-management-interface.md)
makes the same point about the AWS client). What changes is that the menu is
trying and saying so, instead of sitting on a stale verdict in silence.

## What was rejected

- **Dropping the stop-after-six rule.** It is the rule that keeps this from
  hammering a portal with an expired session, which is how an account gets
  locked. The problem was never the budget, it was that nothing was resetting it.
- **A timer that forgets failures every so often.** It reintroduces the retry
  loop through the back door, on a schedule nobody asked for, at a moment nobody
  is watching. The reset should be tied to something that actually happened.
- **`screensaverDidStop` and `sessionDidBecomeActive` as well.** The first fires
  without anybody having authenticated, and the second belongs to fast user
  switching. Neither carries the meaning "the owner is back".
- **Deduplicating by remembering which event arrived.** The order of a wake and
  its unlock depends on how fast somebody types a password. A window of time
  does not care about the order, and there is nothing to get wrong.
