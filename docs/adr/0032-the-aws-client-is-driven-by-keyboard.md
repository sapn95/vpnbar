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

## The two marks on the chooser, added 2026-10-09

The chooser's entries carry two marks, and the first version of this read
either of them as "the highlight". `selected` sits on the profile the chooser is
committed to and does not move. `focused` is what the arrow keys move. They
coincide only at the instant the chooser opens, which is the instant the
measurement above was taken at.

So every walk downwards from the committed profile failed, and did so the same
way three times before it was understood: the first Down moved the focus to the
wanted profile, the read still found the committed one first in tree order and
reported it, a second Down was pressed, the list wraps, and the focus was back
on the committed profile when the final check ran. `AWS VPN Client would not
move its chooser to sbb`, every time, at 1 s. A walk upwards to the first entry
passed, which is why the measurement did not catch it.

`awsui.highlighted` reads the focus first now and the committed entry only when
nothing has focus, and the walk waits for the focus to have moved before it
reads rather than reading once after a fixed pause.

## The name the focused entry carries, added 2026-10-16

The marks were half of it. `AWS VPN Client would not move its chooser to sbb`
went on failing at 1 s, every planner tick for days, and the measurement says
why:

    item 2, nothing pointing at it   AXValue = "sbb"
    item 2, with the focus on it     AXValue = "sbb not selected"

The web view writes an option's `aria-selected` into the name it hands the
accessibility API, and it does so for the option that has focus only. The
committed entry is the selected one and carries no suffix when the focus is on
it, so the chooser read correctly right up to the moment the walk arrived
somewhere.

The one entry a walk has to read by name is therefore the one entry whose name
the client rewrites. The first Down landed on the wanted profile every time. The
read came back `sbb not selected`, no entry of the list matched that, the step
count fell to nothing, the loop broke out, and the final check reported a
chooser that had in fact moved.

`awsui` takes the suffix back off, on the focused entry and only while it is not
the committed one. Every other entry keeps its value verbatim, so a profile
whose own name ends in those words is not shortened for having been read.

There is no attribute to read instead. On the live chooser `AXTitle` is empty on
every entry, so is `AXDescription`, and `AXDOMIdentifier` is `option-0` and
`option-1`: the position, with no name in it.

## The client says why, and nobody was reading it, added 2026-10-16

A connect the client turns down puts a notice on the same window and leaves it
standing:

    static  "AWS VPN Client"
    static  "Failed to connect"
    static  "The provided credentials are incorrect. Check your login details and try again."
    button  "Close"

Nothing read it. A connect the client had refused and a connect that did nothing
at all arrived at the menu as the same silence, which is what somebody pressing
*Switch to* saw.

`connectRow` reads the notice before it presses anything, reports the reason,
and presses Close. The reason rather than the headline: "Failed to connect" is
the part that was already obvious. It is dismissed in the same pass because a
notice left standing is reported again after the attempt that worked.

That pass connects nothing. The notice is the outcome of the attempt before it,
so reporting it records a failure that happened. The pass after it presses
Connect, thirty seconds later while a switch is being pressed for and one tick
later otherwise.

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
- **Pressing Connect in the same pass that dismissed a notice.** The pass would
  report a success, the reason would go unsaid, and the silence this ADR now
  reads the window to break would be back.
- **Leaving the notice on the window and reporting it every pass.** It would
  then be reported after the connect that worked as well, which is a client
  saying one thing and the menu saying another.
