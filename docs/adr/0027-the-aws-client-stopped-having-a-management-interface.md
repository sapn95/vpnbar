# 0027 — The AWS client stopped having a management interface

**Status:** accepted, 2026-09-17. Replaces the mechanism in
[ADR 0009](0009-the-aws-vpn-client-is-driven-through-openvpns-management-interface.md).

## The decision

`aws-vpn-client status` reads the client's own log. The management interface is
still tried first, so an older client is unaffected, and when neither can answer
the reply is **`unknown`** rather than a guess.

`status` takes an optional profile name and reports on that profile alone.

## What went wrong

Version 6.0.3 of the client ships no OpenVPN. There is no binary in
`Contents/Helpers`, no process, and nothing listening on 35001. `listening` is
therefore false while a tunnel is up, and the old code answered that with
`disconnected`.

Measured on the machine this happened to: `utun5` up and running with six routes
installed, and `aws-vpn-client status` saying `disconnected`. vpnbar read both
VPNs as down, so **Only one connection at a time** had nothing to act on, and
autoconnect went on asking an already-connected client to connect.

The rule added the day before was not the fault. Its input was.

## Why the log is a better source than the one it replaces

[ADR 0009](0009-the-aws-vpn-client-is-driven-through-openvpns-management-interface.md)
records that the management interface reports that *a* session is up and cannot
say whose, and the whole `awsvpn` backend is shaped around that: the row is
clicked because the state cannot be asked for by name.

The log does not have that limitation.

```text
[renderer] [poll] Profile connected: <profile>
[poll] Tray state changed to connected | connecting | none
[renderer] [poll] SAML authentication required for profile: <profile>
[shutdown] Disconnecting all connections before OS shutdown/logout
```

It names the profile. So `status <profile>` answers the question ADR 0009 called
unanswerable, and two profiles configured at once no longer both read as
connected.

## Why unknown rather than disconnected

"Nothing is listening" used to mean "there is no session". It now means "there is
no way to ask", and the two deserve different answers. `unknown` is left alone by
autoconnect ([ADR 0013](0013-autoconnect-is-a-plan-not-a-timer.md)), which is the
right thing to do with a connection nobody can read, and it is what stops a
misreading from turning into repeated connect attempts against a live tunnel.

A genuine disconnection still reads as one, because the client writes
`Tray state changed to none` when it happens. The fallback still works.

## Why the client being closed changes the answer

A log is a record, not a reading. With the client shut, its last word may be
hours old, and the tunnel is held by a root daemon that is a different process
from the one that wrote the line.

So a positive answer from a closed client is downgraded to `unknown`, and a
negative one is kept: a client that wrote `none` and then quit has not connected
since.

## What was rejected

- **A probe on the AWS profile.** The client CIDR belongs to the endpoint and a
  machine with two profiles has two of them, which is why
  [docs/configuration.md](../configuration.md) tells you not to give this one a
  probe. Still true.
- **Guessing from the interface list.** A live `utun` proves *a* tunnel, not
  whose. Attribution is the thing the log gives and `ifconfig` does not.
- **Dropping the management interface path.** Older clients still have it, this
  script is published, and a live reading beats a written record where both
  exist.
- **Trusting the three-minute heartbeat alone.** It repeats `Profile connected`
  long after a transition, so a disconnection has to be able to outvote it. Every
  line that states a transition is read in order and the last one wins.
