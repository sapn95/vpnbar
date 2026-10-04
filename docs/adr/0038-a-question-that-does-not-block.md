# 0038 — A question that does not block

**Status:** accepted, 2026-10-04. Follows
[ADR 0035](0035-a-dead-tunnels-routes-are-swept-up.md), which put the question
on the screen, and [ADR 0037](0037-a-dialog-that-looks-like-vpnbar.md), which
gave it an icon.

## The decision

The question about routes left behind, and the administrator prompt that
follows it, run as `osascript` tasks with callbacks. Neither holds the run loop.

## Why

`hs.dialog.blockAlert` and `hs.osascript.applescript` return when the dialog is
answered. Hammerspoon is single-threaded, so for as long as that dialog is on
the screen nothing else in it runs: no state is read, the menu does not open,
the icon does not change. A question that appears on its own is a question
nobody may be at the machine to answer, and the one it asks about is a machine
whose network is already broken. The repair was holding the thing that watches
for it.

Measured on this machine, everything else in a refresh is cheap: the status
command 0.06 s, both route tables 0.03 s, a connect attempt against a running
client 0.06 s. The only unbounded wait in the Spoon was a dialog, and now
there is none.

## What it costs

A flag instead of a stack. The call returns at once, so the refresh that found
the routes runs again while the dialog is still up, and `asking` is what keeps
it from asking twice. Whichever callback answers clears it, a throw clears it
in the caller, and `routes.ASK_DEADLINE` clears it after an hour, because a
callback that never arrives would otherwise be a question that can never be
asked again.

## What was rejected

- **Leaving it blocking and keeping the dialog short.** The length of the
  dialog is not what holds the run loop; the person not being there is.
- **A notification instead of a dialog.** It needs an answer and then a
  password. A banner that disappears is not where that is asked
  ([ADR 0035](0035-a-dead-tunnels-routes-are-swept-up.md)).
- **Making every dialog asynchronous.** The others follow a click, so the
  person is at the machine by construction, and a confirmation that blocks for
  as long as they take to read it costs nothing they were using.
