# 0009 — The AWS VPN Client is driven through OpenVPN's management interface

**Status:** accepted, 2026-09-01.

## What was measured

The AWS VPN Client on macOS offers no handle that either existing backend can
take:

- It does not appear in `scutil --nc list`. The tunnel is OpenVPN, started by
  its own root helper daemon (`com.amazonaws.acvc.helper`), not an
  `NEVPNConnection`.
- It appeared to have **no accessibility tree at all**: with the app running,
  the application element reported zero windows and an empty attribute list.
  That measurement was wrong, and the correction is below — it was taken while
  the client had no window open.
- Its bundle contains one executable and no command line.

What it does do is run its bundled OpenVPN with a management interface on
`127.0.0.1:35001`, with the session password written to
`~/.config/AWSVPNClient/ovpn-mgmt-<profile>`, readable by the user who owns the
session. The client's own logs show it using that interface (`MANAGEMENT: CMD
'status'`).

## The decision

A `shell` profile pointed at `scripts/aws-vpn-client.sh`, which speaks that
interface:

- **status** — `state`, and `,CONNECTED,` in the answer is the only thing that
  counts as up. Every other state OpenVPN reports is a session on its way
  somewhere, which the menu shows as working. A port nothing is listening on is
  disconnected, and that check comes first so the usual case costs one failed
  connect to loopback.
- **disconnect** — `signal SIGTERM`, which is how OpenVPN is asked to stop.
- **connect** — opens the app, and stops there. These endpoints authenticate
  through a browser, and finishing a federated login on someone's behalf is not
  something a menu should be doing.

That it is a script rather than a fourth backend is the point: the `shell`
backend exists so a VPN this project has never heard of needs a config entry
and not a patch, and this is the first proof that it does.

## What was rejected

- **Killing the OpenVPN process.** It runs as root, so it needs a password
  prompt, and the helper daemon may bring it back.
- **An interface probe.** It would work — the client CIDR is visible once
  connected — but it is per-endpoint, and this machine has two profiles with
  two different ones. The management interface answers for whichever is running.
- **Automating the federated login.** Out of scope for a menu, and a place to
  put credentials that should not exist.

## The correction: it does have an accessibility tree

**Measured wrong, 2026-09-03.** The claim above — *no accessibility tree at
all* — was taken while the client was running **with no window open**, which is
exactly the state in which it reports nothing: zero windows, an empty attribute
list. With its window up it exposes the whole tree, one group per profile
holding the name, the state and the button:

```text
AXGroup
  AXStaticText  v=work
  AXStaticText  v=Disconnected
  AXButton      t=Connect  AXPress
```

That matters because the client has **two** profiles here and the management
interface cannot tell them apart: `state` says a session is up, not which one.

So the work is split between two mechanisms, each doing what it is better at:

| | |
| --- | --- |
| `status` | the management interface — costs nothing, opens no window |
| `force` | the management interface, then quitting the client |
| `connect` / `disconnect` | the **`awsvpn` backend**, which clicks that profile's own row |

The row walk goes name, state, button, bounded to a few elements after the
name matches — so a row that does not offer the button being asked for cannot
reach into the next row and click that one instead. Verified against the live
window: `work` and `work-full` each find their own Connect, `work` + Disconnect
correctly finds nothing while it is down, and an unknown name finds nothing.

## Why the clicking is in Lua and not in the shell helper

It was written in AppleScript first, and it does not work: **System Events
cannot read this app.**

```applescript
count of UI elements of window 1   --> 10
count of (entire contents of window 1)   --> 0
```

`entire contents` comes back empty for a window that plainly has ten children —
a known hole with non-native toolkits — and it fails *silently*, returning an
empty string rather than an error. Hammerspoon's own accessibility bindings
read the same tree without trouble, so the clicking lives in the backend, in
Lua, and the shell helper keeps the two jobs that need no window at all.

One more thing that cost time on the way: accessibility access belongs to
whoever spawns the process. Hammerspoon has it. A terminal usually does not,
and `osascript` there fails with *not allowed assistive access* — an error
about the terminal, not about the client.

## What is not proved

The disconnect path is covered by tests against a stubbed socket, not against a
live tunnel. The read side — the port, the state line, the password file — was
taken from a real session's logs; the write side has not yet been used in anger.
