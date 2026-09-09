# 0021 — Restarting the agent is not a disconnect

**Status:** accepted, 2026-09-10.

## The decision

A `globalprotect` connection's submenu offers **Restart GlobalProtect**: quit the
agent, insist if it does not go, open it again. It is confirmed first, and it is
offered on a **protected** connection, which no other write is.

`backends.PROTECTED_VERBS` is now `connect` and `restart` rather than `connect`
alone.

## Why this is not a breach of ADR 0008

[ADR 0008](0008-an-always-on-vpn-is-protected-from-being-disconnected.md) protects
the **tunnel**. GlobalProtect's tunnel is not held by the process in the menu bar:
it is held by a root service and a system extension of its own, which is the
finding this whole project started from
([ADR 0001](0001-globalprotect-is-not-a-scutil-vpn.md)). Quitting the agent closes
a user interface.

The rule that matters is therefore not "never touch a protected connection" but
"never take a protected tunnel down", and this does not.

## Why it is offered on the protected one especially

Everything vpnbar can do with this backend goes through the panel: the state is
read from it and both verbs are clicks in it. When the agent stops answering —
no window, or a Disconnect that does nothing — there is nothing for `press` to
find and the connection is stuck.

A rule that refused a restart because the connection is protected would leave the
one connection that may not be disconnected as the one whose only repair is not
available either. So it is offered, and where autoconnect is on for that
connection the confirmation says what happens if the tunnel does drop after all:
it comes back on the next refresh.

## Why not for the other backends

`awsvpn` is the exact opposite case. That client **is** the tunnel's parent
process, and quitting it takes the session with it — which is what its `force`
already does, deliberately and under a name that says so
([ADR 0012](0012-force-is-only-offered-where-one-exists.md)). Offering the same
kill as a "restart" would be one click promising the opposite of what it does.
`scutil` has no app to restart, and a `shell` profile's app, if it has one, is
something only its own commands know about.

`backends.canRestart` therefore asks the backend, not the config: it is true for a
backend that has a `restart` and a profile that names an app, and nothing else.

## Why TERM, then KILL, then open

In that order, in one command, with a wait between each.

TERM first, because an agent wedged in its panel may still shut down cleanly, and
a clean shutdown leaves its own state tidy. KILL after the grace period, because
this is asked for exactly when the app has stopped answering, which is when TERM
alone is least likely to land — the second `pkill` is a no-op when the first one
worked.

`open` is last so that it, and not the kill, is the exit status the caller sees:
`pkill` reports "nothing matched" as a failure, and an agent that had already
crashed would otherwise be reported as an error at the moment it was being fixed.

The waits are `/bin/sleep` inside the command, so this blocks Hammerspoon for
three seconds, and Hammerspoon here also runs the lock and sleep policy. Accepted
rather than solved: it is a deliberate click on an app that is already broken, it
happens under the busy mark, and three seconds of that beats the two async
callbacks and the intermediate state a chained version would need. The same
reasoning is why `force` may quit an app in one blocking call.

## What was rejected

- **`killall` instead of `pkill -x`.** Same effect, no exact-match flag, and a
  substring match against every process on the machine is not something a menu
  item should be doing.
- **Restarting the root service too.** It needs `sudo`, and asking for an
  administrator password from a menu-bar VPN switcher is a bad habit to build.
  That one is macOS's job.
- **Doing it automatically when a panel read fails.** A read failing is common
  and usually means the agent is busy; killing an app in the background because
  a poll came back empty is how a background poll turns into a support case.
