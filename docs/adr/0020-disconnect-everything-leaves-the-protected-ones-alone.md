# 0020 — Disconnect everything leaves the protected ones alone

**Status:** accepted, 2026-09-10.

## The decision

One row above **Connections**: **Disconnect everything**. It closes every
connection that is up or on its way up and is not protected, using each one's own
`force` where its config gives it one and a plain disconnect where it does not.
The list comes from `menu.disconnectAll`, and the confirmation names exactly the
connections that will be closed.

It is only there once something is up. It is greyed out, and says which
connection is holding it, when everything up is protected.

## Why the greyed-out case exists at all

[ADR 0012](0012-force-is-only-offered-where-one-exists.md) argues the opposite for
**Force disconnect**: a disabled entry claims "this exists but not now", and
where no force exists that is untrue.

Here it is true. On this machine both connections are protected, so the honest
answer is not "there is no such feature" but "there is nothing it is allowed to
close, and here is what is holding it". Hiding the row would read as a missing
feature. A row that quietly did nothing would read as a broken one. Neither of
those is the reason, and the reason is a config setting the same menu can change
two submenus away.

## Why it uses force where one exists

Because the click already means "get me off these networks". Making somebody
open a submenu and click a second, stronger item after the first one silently
did not take is exactly the moment this row exists to remove. Where no force is
configured, nothing stronger is invented for it: that is still
[ADR 0012](0012-force-is-only-offered-where-one-exists.md).

## Why hidden connections are included

Hiding keeps a connection out of the top level of the menu, not out of the
routing table. A tunnel nobody can see is a poor candidate for surviving a click
that says everything, and it is named in the confirmation, so nothing goes down
unannounced.

## Why one mark and one pass, in the adapter

The whole run is one job in `work` ([ADR 0017](0017-the-mark-says-when-it-is-working.md))
and one deferred call ([ADR 0018](0018-nothing-waits-for-a-read.md)), because a
`force` waits on a management interface and then on an app quitting. A connection
that refuses is reported and the loop carries on: one failure is no reason to
leave the others up.

## What was rejected

- **Overriding `protected` for this one item.** The protection is the only rule
  the rest of the project is built on ([ADR 0008](0008-an-always-on-vpn-is-protected-from-being-disconnected.md)).
  An item that breaches it under a plural name breaches it.
- **Asking per connection.** Two dialogs for two tunnels is worse than the two
  clicks it replaces.
- **Including connections whose state could not be read.** Sending a disconnect
  at an unknown state is how a profile with no probe turns a menu click into a
  panel opening by itself.
- **Putting it under Connections.** It acts on the tunnels, and Connections is
  where the menu's own list is managed ([ADR 0005](0005-crud-is-over-the-menu-not-the-system.md)).
