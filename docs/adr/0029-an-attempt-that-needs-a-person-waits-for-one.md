# 0029 — An attempt that needs a person waits for one

**Status:** accepted, 2026-09-19.

## The decision

There is a fifth state, **`login`**: down, and only a person can bring it back,
because the gateway has ended the session and the next connect opens a SAML
window rather than a tunnel. It comes from each client's own log — the AWS
helper's `SAML authentication required for profile:` line, GlobalProtect's
`User was logged out` / `Auth Failed during login` in its event log — and the
menu row says it: *needs your login*.

An automatic connect of a connection in that state is held while the screen is
**locked**, and otherwise until a **minute** has passed without a keystroke or a
click; the window after a **wake or an unlock** lets one such connect through
at once. Every other down state is never held. `autoconnect.wouldInterrupt` is
the whole rule and it is pure; the adapter supplies `locked`, `fresh` and `idle`.

The three runtime entry points that reach a client's interface hand the focused
window back afterwards, and the Escape that closes a stuck options menu is
addressed to the agent.

## What went wrong

The complaint was that the menu had become aggressive: it kept taking the
focus, and with both connections down it took it twice as often. That is
[ADR 0024](0024-autoconnect-backs-off-it-does-not-give-up.md) and
[ADR 0026](0026-one-at-a-time-outranks-protection.md) doing what they say. A
connection that does not come up is retried on a schedule, alternately with its
stand-in, and each retry on a dead session is a login window.

## What was measured, and what the first version got wrong

The obvious explanation was wrong. Opening and closing the GlobalProtect panel
to read its state, and `open -a` on the running AWS client, both left the
focused window exactly where it was — measured here, with the panel confirmed
open by the state it returned. `open -g -a` made it worse: the client's window
became the focused one. What takes the focus is what the agent does *after* the
click, and only when the session has ended: `saml-auth-method: REDIRECT` in
GlobalProtect's log, `SAML authentication required` in the AWS client's.

The first version of this record gated every automatic connect through a
backend that "drives a user interface" on idle time. A second review simulated
it and showed the discriminator was wrong in both directions. A GlobalProtect
tunnel dropped by a network blip with a valid session reconnects silently, and
that version held it for as long as the person kept typing — never reconnecting
during a working hour, which is the opposite of what
[ADR 0024](0024-autoconnect-backs-off-it-does-not-give-up.md) exists for. And on
a locked screen idle only grows, so the full backoff schedule ran into an empty
chair: ten login windows in half an hour, and two more within fifteen seconds
of the unlock.

Whether a click opens a window is not the question. Whether the attempt needs a
person is, and the clients say so in their logs.

## Why the state, and not a flag beside it

"Needs a login" is a fact about the connection, in the same way "connected" is,
and the menu should say it where it says the rest: on the row, in words, since a
glyph at sixteen pixels cannot. Making it a state means `menu`, `icon`,
`autoconnect` and the probe path all see the same word, and a fifth word in
`parse.STATES` is a smaller change than a second channel carried beside the
first. It is ranked with `disconnected`, drawn like it, and treated as down by
every rule that asks; only autoconnect tells the two apart.

For GlobalProtect the state is read from the probe first, as
[ADR 0003](0003-a-probe-beats-asking-the-app.md) says, and the event log is only
asked once the probe has said the tunnel is down. It turns "down" into "down,
and only you can fix it", and costs one `tail` on a read that already knows the
answer is not "up".

## Why locked holds, and why unlock lets one through

Idle time on a locked screen is not quiet, it is absence. Silent reconnects go
on as before — that is the case from
[ADR 0022](0022-a-probe-reads-the-interface-not-just-the-address.md), a tunnel
dropped overnight with a session still good, and it is exactly what must keep
working while nobody is there. The one thing held is a window nobody can answer.

On the read that follows a wake or an unlock the person has just sat down and
wants the connection now; a login window then is what they came for. The
exemption is a window of twenty seconds rather than one read, because the one
read that could act may not be able to, and it is spent by the first
login-needing connect made in it, so the stand-in does not get a second window
ten seconds after the first.

A deferral is not an attempt. It records nothing and does not feed the backoff.

## What is not measured

`hs.host.idleTime` counts HID events as IOKit reports them. A review checked
that neither `caffeinate -u` nor a Hammerspoon-posted mouse move or keystroke
resets it, so a software jiggler does not; whether physical input on a lock
screen or Touch ID does is stated by the documentation, not measured here. The
Escape addressed to the agent was not exercised, because there was no stuck
menu to exercise it on; with no target found it posts globally, as before.

## What was rejected

- **Gating on the backend rather than on the state.** The first version, and
  wrong in both directions, as above.
- **Detecting the login window itself.** Precise, and fragile: a signature per
  client, and a wrong guess is a connection that is never retried. The logs say
  it in words.
- **Gating disconnects too.** Taking an extra tunnel down is a click in a
  window as well, but it happens once, when the preferred connection has just
  arrived, and it opens nothing afterwards.
- **Treating a locked screen as quiet.** It is the half-hour of wasted windows.
- **Focus restoration as the whole answer.** Kept because it is free and right
  in principle, and not the fix, for the reason measured above.
