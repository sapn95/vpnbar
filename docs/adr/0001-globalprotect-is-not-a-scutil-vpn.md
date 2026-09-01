# 0001 — GlobalProtect is not a `scutil` VPN

**Status:** accepted, 2026-09-01.

## What was found

This Mac has a VPN service that macOS knows about, pushed by device
management, named for the GlobalProtect agent and visible in `scutil --nc
list`. It is not the tunnel. With traffic flowing over a `utun` interface, that
service still reported:

```text
$ scutil --nc status "<the managed service>"
Disconnected
```

The agent runs its own system extension and manages the tunnel itself. The
managed service is a leftover the agent does not use.

Nor is there another door. The application bundle ships:

- no command-line tool,
- no AppleScript dictionary (`.sdef`),
- one URL scheme, and it is the SAML login callback, not a control channel.

Its panel, however, is a native accessibility tree — an `AXWindow` with an
`AXPopUpButton` for the options menu and `AXStaticText` for the status, not a
web view.

## The decision

The `globalprotect` backend drives the agent's menu-bar panel through the
accessibility API, and reads its state either from a probe or from that same
panel.

## What follows from it

- Hammerspoon needs Accessibility permission for this backend. The other two
  work without it.
- Reading the state costs a panel appearing on screen, so it happens on demand
  and never on the timer — [ADR 0003](0003-a-probe-beats-asking-the-app.md).
- Controls are found by their text, not by position, so an agent update that
  moves Disconnect from the panel into the options menu changes nothing here.
- Nothing presses *Disable*. On that panel it is a different action with a
  different meaning, and this menu cannot undo it.

## What was not settled

The panel was captured while the agent was *connecting*. The exact element that
appears once it is connected was not, which is why the search covers the panel
and the options menu and matches on text. The first real disconnect is still
the first real disconnect.
