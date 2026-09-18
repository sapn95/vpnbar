# 0028 — Quit and restart are per application

**Status:** accepted, 2026-09-18. Generalises
[ADR 0021](0021-restarting-the-agent-is-not-a-disconnect.md).

## The decision

Every connection whose config names an `app` offers **Quit `<app>`** and
**Restart `<app>`** in its submenu, and one row above **Connections** closes all
of them at once: **Quit every VPN app**.

Restart was GlobalProtect's alone. It is not a property of that agent, it is a
property of having an application.

## Why the same command is two different promises

Closing GlobalProtect closes a user interface. Its tunnel is held by a root
service and a system extension
([ADR 0001](0001-globalprotect-is-not-a-scutil-vpn.md)), so the connection
survives the app. Closing the AWS VPN Client ends the session, because that
client is the tunnel's own parent process — which is exactly what its `force` is
for.

Same `pkill`, two different things to say about it. `appOwnsTunnel` on the
backend is where that difference lives, and it is the only thing the menu needs
in order to word a dialog honestly.

## Why a protected connection keeps one and not the other

[ADR 0021](0021-restarting-the-agent-is-not-a-disconnect.md) allows restarting a
protected GlobalProtect, and the reason holds: it closes an application, not a
tunnel, and the connection that may not be disconnected is exactly the one whose
only repair this is.

The reason does not travel. For a client that *is* the tunnel, quitting is a
disconnect, and no button in this menu performs one on a protected connection
([ADR 0008](0008-an-always-on-vpn-is-protected-from-being-disconnected.md)). So
`backends.canQuit` refuses that case, and the row is absent rather than greyed
out — there is a feature and it does not apply here, which is
[ADR 0012](0012-force-is-only-offered-where-one-exists.md)'s rule.

The consequence is worth stating plainly: with the AWS connection marked
`protected`, **Quit every VPN app** closes GlobalProtect and leaves the AWS
client alone. Taking `protected` off that connection is a one-word config change
and the row picks it up on the next open.

Note that this is a narrower rule than the one **Only one connection at a time**
follows. That may close a protected tunnel
([ADR 0026](0026-one-at-a-time-outranks-protection.md)) because it is a rule
acting on a machine already connected elsewhere, under a verb no button
produces. A button is a person asking, and the answer there has not changed.

## Why one row for all of them, and one entry per application

Two connections through the same client are one thing to quit. `menu.quitApps`
deduplicates by application name, so a machine with two AWS profiles offers one
row, not two identical ones.

The row sits beside **Disconnect everything** rather than inside a connection's
submenu, because closing the clients is a different job from taking the tunnels
down, and because it is the repair for a client that has stopped answering —
which is not a thing you go looking for under one particular connection.

## What was rejected

- **Making Quit a greyed-out row where the client owns the tunnel.** The menu
  already has a disabled row that is honest, and it is honest because the
  feature exists and a setting is suppressing it. Here the honest answer is that
  this button would be a disconnect, and a disconnect is what **Force
  disconnect** is called.
- **Quitting the clients as part of Disconnect everything.** It takes tunnels
  down; closing an application is a different intention, and a row that does
  both is a row nobody can predict.
- **Reporting a failure when the app was not running.** `pkill` calls "nothing
  matched" a failure, and an app that was not running is an app that is now
  closed, which is what was asked for.
