# 0019 — Quit stops the Spoon and nothing else

**Status:** accepted, 2026-09-10.

## The decision

The menu ends with **Quit vpnbar**. It calls `obj:stop()`: the timers stop, the
pulse stops, the status item is deleted, and anything already queued finds no
menu bar to paint and returns without reading. It is confirmed first, and both
the confirmation and the item's tooltip say the two things that are not obvious
from a menu about to disappear — that no connection is closed, and that the way
back is a Hammerspoon reload.

## Why it is there at all

Every other menu-bar app on this Mac has one. Without it, the only way to get rid
of the icon is to know that this is a Hammerspoon Spoon, find the config, and
comment out a line — which is fine for the person who wrote it and no answer for
anybody else.

## Why it does not quit Hammerspoon

Hammerspoon on this machine also runs the lock and sleep policy. A Quit in a VPN
menu that took all of that down with it would do what the word says and nothing
anybody meant by it. The Hammerspoon menu has its own Quit for that.

## Why it does not disconnect anything

Quitting a menu is not a network operation. Bringing tunnels down on the way out
would also breach the one rule the rest of this project is built around — a
protected connection is never closed by vpnbar
([ADR 0008](0008-an-always-on-vpn-is-protected-from-being-disconnected.md)) — and
a Quit that behaved differently depending on which connections happened to be
protected would be worse than one that behaves the same way every time.

## What was rejected

- **Quitting without a confirmation.** Standard for a menu-bar app whose icon
  comes back from Spotlight. This one comes back from a Hammerspoon reload, and
  that is worth one dialog.
- **Putting it under Connections with the rest of the management items.** It
  manages the menu, not the connections, and it is the one item somebody will go
  looking for without knowing what this is.
- **`Hide the icon` instead, remembered in the config.** A hidden icon and a
  running poll is a program you cannot see and cannot stop.
