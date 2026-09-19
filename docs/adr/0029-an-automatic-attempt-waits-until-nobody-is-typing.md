# 0029 — An automatic attempt waits until nobody is typing

**Status:** accepted, 2026-09-19.

## The decision

An automatic connect that would put a client's user interface on the screen is
made only after `autoconnect.IDLE_BEFORE_INTERRUPTING` seconds without a
keystroke or a click — a minute — or on the read that follows a wake or an
unlock. `backends.drivesUI` says which backends those are: `globalprotect` and
`awsvpn`. Everything else, and every disconnect, is unaffected.

Separately, the three runtime entry points that reach a client's interface —
`panel`, `press`, `pressRow` — hand the focused window back afterwards, and the
Escape that closes a stuck options menu is addressed to the agent instead of to
whatever has the keyboard.

## What went wrong

The complaint was that the menu had become aggressive: it kept taking the focus,
and with both connections down it took it twice as often. That is a straight
consequence of [ADR 0024](0024-autoconnect-backs-off-it-does-not-give-up.md) and
[ADR 0026](0026-one-at-a-time-outranks-protection.md) doing what they say. A
connection that does not come up is retried on a schedule, alternately with its
stand-in, and each retry is a click in a client's window.

## What was measured before deciding

The obvious explanation was wrong. Opening and closing the GlobalProtect panel
to read its state, and `open -a` on the running AWS client, both left the
focused window exactly where it was — measured on this machine, with the panel
confirmed open by the state it returned. So focus restoration around those,
though kept, is not the fix.

`open -g -a`, which was the first idea for the AWS window, made it worse: the
client's window became the focused one. Reverted.

What actually takes the focus is what the agent does *after* the click. A
connect on GlobalProtect whose session has ended goes to `saml-auth-method:
REDIRECT` and puts a login window on screen. The AWS client does the same
(`SAML authentication required` in its log). Those windows arrive after the
click returns, so nothing done at the moment of the click can give the focus
back — and a login that needs a person will be asked for again on the next
retry.

## Why idle time rather than a smarter rule

The two things being balanced are both things the owner of this machine asked
for: never give up on the connection, and never take the keyboard. A minute of
quiet is a pause, not a gap between two words, and a login window that appears
during a pause is a login window at a good moment. It also lands on the case
this is really about, a locked screen, where idle time only grows.

The fresh-start exception is the other half. On the read after a wake or an
unlock the person has just sat down and wants the connection now; a login
window then is what they came for, and holding it for a minute of idle they are
not going to provide would be the menu being clever at their expense.

A deferral is not an attempt. It records nothing, so it does not feed the
backoff, and the connection is asked for as soon as the quiet arrives.

## What was rejected

- **Detecting the login window and stopping until a person acts.** It is the
  precise rule and the fragile one: it needs a signature for every client's
  login window, and a wrong guess is a connection that is never retried. The
  AWS log states it in words; the GlobalProtect one does not.
- **Gating disconnects too.** Taking an extra tunnel down is a click in a window
  as well, but it happens once, when the preferred connection has just arrived,
  and it opens nothing afterwards.
- **A shorter threshold.** Ten seconds is a pause for thought, and a login
  window in the middle of one is the thing being complained about.
- **Focus restoration as the whole answer.** It was the first version of this
  branch, and the measurement above is why it is not.
