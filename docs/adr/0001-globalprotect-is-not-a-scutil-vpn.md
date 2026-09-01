# 0001 — GlobalProtect is not a `scutil` VPN, so it is driven through its panel

**Status:** accepted, 2026-09-01.

## What was measured

On the Mac this was built for, with the tunnel demonstrably up — `ifconfig`
showing a `utun` interface holding an address out of the corporate pool —
`scutil --nc status` for the VPN service the MDM had pushed answered
`Disconnected`, and its `LastStatusChangeTime` was two weeks old.

The service macOS knows about and the tunnel that is actually carrying traffic
are two different things. The Palo Alto agent runs its own network system
extension and does not go through the `NEVPNConnection` the MDM profile
defines. `scutil --nc stop` on that service therefore stops nothing, and
reports success while doing it.

The app offers no other handle: its bundle declares one URL scheme, and that
one is the SAML callback. There is no scripting dictionary, no CLI, and the
agent's IPC socket is root-only.

## The decision

`scutil` stays the backend for VPN services macOS genuinely owns. GlobalProtect
gets its own backend which clicks its menu-bar panel through the accessibility
API — open the panel, find the control whose text contains the verb, press it,
close the panel.

The control is located **by its text at runtime**, searched for on the panel
first and in its options menu second. Which of the two holds Disconnect depends
on the state the agent is in, and hard-coding a path through that tree is how
this breaks on the next agent release.

Deliberately excluded: **Disable**. It sits in the same menu, reads like a
stronger Disconnect, and is not — it is a different action, in some
configurations one this menu could not reverse.

## What was rejected

- **`scutil --nc stop`** — measured above; it does nothing here.
- **Killing the agent processes.** The tunnel is held by a root daemon; killing
  the user-facing agent leaves it up and leaves nothing to reconnect from.
- **Parsing the agent's log for the state.** It is written for support cases,
  is 3 MB of WebKit noise per session, and its lines are not a contract.

## What follows from it

A GlobalProtect profile needs Accessibility permission for Hammerspoon, and its
state cannot be read without opening a panel — which is what
[ADR 0003](0003-a-probe-beats-asking-the-app.md) is about.
