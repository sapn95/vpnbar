# 0031 — Autoconnect does not undo a quit

**Status:** accepted, 2026-09-24. Narrows
[ADR 0013](0013-autoconnect-is-a-plan-not-a-timer.md) and completes
[ADR 0028](0028-quit-and-restart-are-per-application.md).

## The decision

Autoconnect never asks a connection to come up while the application behind it
is closed. Two reasons, one rule, both keyed by application name:

- **It is not running.** Every way into these clients goes through their own
  user interface, so there is nothing to click in.
- **Somebody quit it.** **Quit `<app>`** and **Quit every VPN app** record that
  decision, and it stands until a person says otherwise — including while the
  application is running again.

`autoconnect.mayStart(profile, context)` is the whole rule. The adapter measures
the first half each refresh (`appsRunning`) and remembers the second half for
the session (`self.quitByHand`).

Lifting it is anything that means *I want this working again*: **Connect**,
**Switch to**, **Restart `<app>`**, switching **Connect automatically** on,
**Resume autoconnect for `<app>`**, or the connection arriving on its own.
Restarting vpnbar forgets it, the same as the switch preference in
[ADR 0030](0030-a-switch-is-a-preference-not-an-order.md).

## Why a closed client is not simply an attempt that fails

It already failed, every time, and it always would: `hs.application.get` returns
nothing, the press has nowhere to go. What the failure cost was the backoff —
one minute, then two, then four, up to fifteen
([ADR 0024](0024-autoconnect-backs-off-it-does-not-give-up.md)) — so a client
that was closed for a quarter of an hour was a connection that then waited a
quarter of an hour after it came back. Holding instead of attempting means the
connect happens on the first refresh after the client returns.

It is also the only way a quit made *outside* this menu is noticed at all. The
AWS client is `protected` on the machine this was written for, so vpnbar is not
allowed to close it ([ADR 0028](0028-quit-and-restart-are-per-application.md))
and a ⌘Q in the client itself is the only quit there is.

## Why the quit is remembered separately

Because the application comes back by itself. GlobalProtect ships
`/Library/LaunchAgents/com.paloaltonetworks.gp.pangpa.plist` with `KeepAlive`
set, so it is running again within seconds of being closed, and a rule that only
looked at what is running would have reconnected the tunnel a person had just
stood down. Measured on this machine, not assumed.

## Why the arrival lifts it and the state does not

A tunnel that has just come up was not being left alone by anybody, whoever
brought it up, so the hold goes. That is checked as a *transition* into
`connected`, not as the state itself: closing GlobalProtect leaves its tunnel up
([ADR 0001](0001-globalprotect-is-not-a-scutil-vpn.md)), so a rule reading
`connected` would drop the hold one refresh after the quit took it, and the one
client whose app outlives its tunnel would be the one client this could not hold.

## Why the hold follows the click and not the kill

`pkill` against an agent with `KeepAlive` set races its own launch agent: the
command TERMs, waits two seconds, KILLs and then asks whether anything of that
name is left ([ADR 0028](0028-quit-and-restart-are-per-application.md)), and by
then launchd may have started it again. "Did it stay closed" has no stable
answer. What somebody asked for has one, so the hold is taken when the
confirmation is accepted. A quit that failed therefore leaves a running client
autoconnect will not touch — which the connection's row says, and **Resume
autoconnect** undoes.

## Why the fallback gets its turn immediately

A stand-in is normally tried only after the connection somebody chose has failed
once. A closed client never records that failure, so the threshold would never be
met and the stand-in would never be tried: `mayStart` returning false counts as
the attempt being exhausted. The stand-in has to pass the same rule — a fallback
whose own client is closed is not a fallback.

## Why the menu says so out loud

A connection autoconnect has been told to leave alone looks exactly like one
that is failing. So the row's tooltip names the client and what will lift it, the
**Quit** rows and their confirmations say it before anything is closed, and the
connection's submenu grows **Resume autoconnect for `<app>`** while the hold is
on. Its previous promise — "if the connection does drop after all, autoconnect
brings it back" — was the one being kept and is now wrong for a quit.

## What was rejected

- **Holding a connection somebody disconnected by hand.** Tempting for the same
  reason, and a different decision: an always-on VPN that stays down because a
  click took it down once is the thing this project exists to prevent, and
  **Connect automatically** is already the per-connection switch for it.
- **Persisting the hold.** The clients are opened at login. A hold that survived
  a reboot would be a connection that never came back, from a quit nobody
  remembers.
- **Treating "the app is not running" as a failure with a notification.** It is
  the normal state of a client somebody closed, and a menu that complains about
  it once a minute is a menu that gets switched off.
