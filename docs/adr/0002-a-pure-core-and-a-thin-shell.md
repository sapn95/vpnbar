# 0002 — A pure core and a thin Hammerspoon shell

**Status:** accepted, 2026-09-01.

## The problem

Hammerspoon cannot be imported by a test runner. Anything written against
`hs.menubar`, `hs.execute` or `hs.axuielement` can only be tried by reloading
the config and clicking, which is where a menu-bar tool usually ends up: no
tests, and a regression found by a tunnel that would not come down.

## The decision

Everything that decides anything lives in `VpnBar.spoon/vpnbar/` and imports
nothing from Hammerspoon. `init.lua` is the only file that does, and it holds
no decisions worth testing — it maps action descriptors to closures, reads and
writes a file, and implements the four functions of the **runtime** the
backends are handed.

The coverage floor counts the core only. The adapter is not covered; it is kept
short enough to read instead.

## What follows from it

- `backends.lua` never calls a shell. It asks `runtime.exec`, so a test can
  assert the exact command string, including the quoting of a service name with
  a space in it.
- `menu.lua` returns data, not closures — [ADR
  0004](0004-actions-are-data-until-they-are-clicked.md).
- The floor is a real gate at 85%, and the core sits above 99%. A number that
  is reported but not enforced is a number that goes down.

## The cost

Two places to look when following one click through, and a runtime interface
that has to be kept honest by hand: nothing checks that the fake in
`backends_spec.lua` still behaves like `hs.execute`. Four functions is a small
enough surface to accept that.
