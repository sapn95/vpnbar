# 0032 — The AWS client is driven by keyboard

**Status:** accepted, 2026-09-29. Replaces the clicking half of
[ADR 0009](0009-the-aws-client-is-driven-through-openvpns-management-interface.md),
whose reading half [ADR 0027](0027-the-aws-client-stopped-having-a-management-interface.md)
already replaced.

## What the window actually looks like

Measured on the running client, not remembered:

    static  "Status:"                    static  "sbb"
    static  "Ready to connect"           static  "Connected"
    button  "sbb_full"                   button  "Disconnect"
    button  "Connect"                    button  "Other actions"

The left column starts a connection: one chooser naming the profile that will
be connected, and one Connect. The right column is the connections that are
already up, a block each. There is **no Connect on a profile**, and the chooser
lists only the profiles that are not up, so a name that is missing from it is
usually one that is already connected.

## The decision

Connecting a named profile is two steps, all keyboard: set the chooser to the
profile, then press Connect. Disconnecting stays what it was, the button inside
that profile's own block. `vpnbar/awsui.lua` decides which control each of those
is, from a flat list of roles and strings, so the part that can be wrong is
under test; the adapter presses.

## Why the keyboard

`AXPress` does nothing in this client. Measured on the chooser, on a plain
button and on a menu item: the action is offered, accepted, and no click
happens. The window is a web view, and its controls answer the keyboard they
would answer for a person: focus the control and send it a key, `space` to open
the chooser, `return` to press a button.

It is also the quieter of the two. The keystroke is addressed to the
application, so it works with the client in the background: nothing is brought
to the front, no focus is taken, and a focus that did not take sends a key the
client ignores rather than a space into whatever somebody is typing in. A
synthetic mouse click was the alternative and was rejected for the opposite
reasons: it needs the window raised and on screen, it moves the pointer, and a
click at a coordinate goes to whatever is topmost there, which on a busy desktop
is somebody else's window.

## Why the tree is followed deeper

The walk stopped at depth eight, which was enough for a panel. This client
draws its window in a web view behind seven nested groups, so its controls sit
at nine and ten: the walk found the groups, none of the buttons, and reported a
client that offered nothing. Twenty is past anything either client draws, and
the bound stays a number because a tree with a cycle in it would hang
Hammerspoon.

## Why the highlight is re-read instead of counted

The chooser opens with something highlighted and only an arrow key moves it, so
reaching a profile is a number of presses. That number is re-measured after
every press rather than worked out once in advance: the list is short, the
highlight is readable, and a count that was one out would connect a different
VPN than the one somebody asked for. If the highlight will not land on the
profile, the chooser is closed with an escape and nothing is pressed.

## A client with no window cannot be given one

`AXWindows` answers with one entry even when the client has none, and that
entry has the role `AXApplication` and a frame of nothing: a tree of menu bars
rather than an interface. Taken at face value it is a window where every
control is missing, which reads exactly like a client that stopped offering
them, so every window here is checked for its role first.

Getting one back is not something this menu can do. Measured, with the window
closed and the tunnel still up: `open -a` does nothing, activating the
application does nothing, pressing its icon in the menu bar through the
accessibility API does nothing, and the client has no Window menu to ask. Only
a person clicking that icon opens one, so that is what the message says instead
of a retry that would fail the same way.

## What is not proven

The last keystroke. Everything up to it was measured on the live client: the
chooser opens, the highlight moves, the selection sticks. Pressing Connect
starts a real VPN session and a SAML login, so it was left for the first real
use rather than tried on somebody's working machine to see what happens. The
button is the same kind of control as the one whose menu opened on `return`.

## What was rejected

- **Keeping `AXPress` with a click as a fallback.** Two mechanisms where the
  first never works is one mechanism and a decoration.
- **Reading the chooser by name.** It is titled after whatever is selected, so
  a client sitting on `sbb_full` has a button called `sbb_full`, which no rule
  about names could tell apart from the profile of that name in the list of
  live connections. Its position in front of Connect does not move.
- **Pressing Connect without checking first.** A profile that is already up
  answers a second Connect with a dialog, so a read that lagged behind would
  put a window on the screen for nothing.
