# 0008 — An always-on VPN is monitored, not controlled

**Status:** accepted, 2026-09-01.

## The problem

The connection this project started from turns out to be one that must not be
disconnected: it is a hard requirement on the machine, not a preference. A menu
item that offers to break that is worse than no menu item — it is one
mis-click, and the mis-click looks exactly like the thing the menu is for.

At the same time the state of that tunnel is the single most useful thing in
the menu. Dropping the connection from the list would throw away the half that
was wanted to protect against the half that was not.

## The decision

A profile may set `"monitor": true`. Such a row shows its glyph, its name and
its state, is disabled, and carries no action. Its tooltip says
`monitored only` so the greyed-out row reads as deliberate rather than broken.

The rule is enforced twice: `menu.build` emits no action for it, and
`backends.act` refuses one for it. The menu decides what is offered; the
backend decides what happens, and a dispatch that reaches it by any other
route — a stale menu, a hand-written call in the console — still gets nothing.

Everything else stays: a monitored connection can be renamed, edited, reordered,
hidden and removed like any other, because those change this menu's list and
not the tunnel ([ADR 0005](0005-crud-is-over-the-menu-not-the-system.md)).

## What was rejected

- **Leaving it out of the config.** Then there is no state either, and the one
  question the menu bar exists to answer goes unanswered.
- **Asking for confirmation instead.** A dialog that is always answered the
  same way stops being read within a week, and this one would be answered
  "no" every single time. A control that must never be used is not a control.
- **A global setting.** Whether a tunnel is policy or preference is a property
  of that tunnel, and a machine can have one of each.
