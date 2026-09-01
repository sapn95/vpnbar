# 0008 — An always-on VPN is protected from being disconnected

**Status:** accepted, 2026-09-01. Narrowed 2026-09-01, see below.

## The problem

The connection this project started from must not be disconnected: it is a hard
requirement on the machine, not a preference. A menu item that offers to break
that is worse than no menu item — it is one mis-click, and the mis-click looks
exactly like the thing the menu is for.

At the same time the state of that tunnel is the most useful thing in the menu,
so dropping it from the list would throw away the half that was wanted in order
to protect against the half that was not.

## The decision

A profile may set `"protected": true`. The protection points in **one
direction**: the connection can never be disconnected or force-disconnected
from here, and it can always be connected.

- Up, or on its way up: the row reports and is disabled, tooltip
  `protected from disconnecting`.
- Down: the row offers **connect**, tooltip `protected once it is up`.

Enforced twice. `menu.build` emits no disconnect for it, and `backends.act`
refuses `disconnect` and `force` for it while letting `connect` through — so a
dispatch arriving by any other route gets the same answer.

Everything else stays: it can be renamed, edited, reordered, hidden and removed
like any other, because those change this menu's list and not the tunnel
([ADR 0005](0005-crud-is-over-the-menu-not-the-system.md)).

## The narrowing, and why the first version was wrong

This started as `"monitor": true`, meaning **never acted on at all** — no
connect either — and `store` refused to combine it with `autoconnect`.

That was a misreading of the requirement. The rule is "do not close it", not
"do not touch it", and the two are not the same: a tunnel that must stay up is
precisely the one worth bringing back automatically, and precisely the one that
should have a fallback when it will not come. Under the first version, the
connection with the strongest claim to autoconnect was the only one forbidden
from it.

`monitor` is therefore gone rather than kept as an alias. It named a
restriction that does not exist.

## What was rejected

- **Leaving it out of the config.** Then there is no state either, and the one
  question the menu bar exists to answer goes unanswered.
- **Asking for confirmation instead.** A dialog that is always answered the
  same way stops being read within a week, and this one would be answered "no"
  every single time. A control that must never be used is not a control.
- **A global setting.** Whether a tunnel is policy or preference is a property
  of that tunnel, and a machine can have one of each.
