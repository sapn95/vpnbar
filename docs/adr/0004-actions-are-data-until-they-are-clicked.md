# 0004 — Menu actions are data until they are clicked

**Status:** accepted, 2026-09-01.

## The decision

`menu.build(config, states)` returns a list of plain tables. A clickable row
carries a descriptor:

```lua
{ title = "●  Work VPN", action = { kind = "disconnect", id = "work" } }
```

No closures, no `hs` anywhere. `init.lua` walks the list, turns each descriptor
into a click handler, and `obj:dispatch` maps `kind` to a function.

## Why

A menu built out of closures can only be tested by clicking it. A menu built
out of descriptors can be asserted directly: that a connected profile offers
*disconnect* and not *connect*, that a hidden one is absent from the top level
but present under **Connections**, that **Move up** is disabled on the first
entry. Those are the parts that break, and they now break in a test.

It also keeps one rule enforceable: the menu decides *what* is offered, the
adapter decides *how* it is run. A handler cannot quietly acquire an opinion
about which rows exist.

## The cost

One indirection between a row and what it does, and a `dispatch` table that has
to gain a case whenever `menu.lua` invents a kind. A kind with no case is
silently inert rather than an error — a deliberate trade for a menu that never
throws while it is open, and the reason every kind `menu.build` can emit is
asserted in `menu_spec.lua`.
