# ADR-0002 — A pure core and a thin Hammerspoon shell

**Status:** accepted

## Decision

Everything that decides something — validation, the CRUD operations, the menu
model, which state wins, which command to run — lives in `VpnBar.spoon/vpnbar/`
and imports nothing from Hammerspoon. `init.lua` is the only file that may
touch `hs.*`, and it is not counted in coverage.

The backends are handed a **runtime** table (`exec`, `ifconfig`, `panel`,
`press`) rather than calling out themselves, so a test substitutes four
functions and gets the whole decision path under assertion without a menu bar,
a VPN or a Mac.

The menu is built as **data**: `menu.build` returns items carrying an `action`
descriptor such as `{ kind = "disconnect", id = "work" }`, and `init.lua` turns
each descriptor into a click handler. A test reads the same descriptors and
never opens a menu.

## Why

Hammerspoon can only be exercised inside Hammerspoon, on a Mac, with a real
menu bar. A design that mixes decisions into that layer is a design whose
decisions are checked by clicking, and the coverage floor is then a number
about nothing.

## Consequence

`init.lua` is excluded from coverage on purpose, so it has to stay boring: an
adapter, a dialog, a timer. Anything in it worth a test is in the wrong file.
The rule that keeps that honest is the coverage floor in
`scripts/coverage-floor.lua` — 85%, over the core only, which the core clears
by a wide margin.
