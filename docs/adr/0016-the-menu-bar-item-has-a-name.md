# 0016 — The menu-bar item has a name, and that is what a menu bar manager can hold on to

**Status:** accepted, 2026-09-03. Corrected the same day, twice — see below.

## The decision

```lua
hs.menubar.new(true, "vpnbar")
```

The second argument is an autosave name. Hammerspoon documents it as what lets
macOS restore the item's position between restarts. It does more than that, and
the more is the point.

## What was actually wrong

The icon kept disappearing behind Bartender. Bartender addresses status items
by an id, and **the id depends on whether the item has an autosave name**:

| | Bartender's id for it |
| --- | --- |
| without a name | `org.hammerspoon.Hammerspoon-Item-0` |
| with `"vpnbar"` | `org.hammerspoon.Hammerspoon-vpnbar` |

The first is an **ordinal**. Hammerspoon owns two status items here — its own
and this one — so which of them is `Item-0` depends on which was created
first, which is a race between a Spoon starting and the application it starts
in. Bartender's rule for `Item-0` therefore landed on this icon one reload and
on the other one the next, and no amount of moving `Item-0` between its Show
and Hide lists could fix something whose identity changed underneath it.

The second is a **name**. It is the same string every time, so the manager has
something durable to attach a decision to. Adding
`org.hammerspoon.Hammerspoon-vpnbar` to Bartender's shown items makes the icon
stay, across Bartender restarts and across Hammerspoon reloads. Measured:
`x=1441` before and after two of each.

Bartender is scriptable, which is how the id was found rather than guessed:

```applescript
tell application "Bartender 6" to list menu bar items
tell application "Bartender 6" to show "org.hammerspoon.Hammerspoon-vpnbar"
```

## Two corrections, both worth keeping

The first three explanations offered for this were versions of *a menu bar
manager is hiding it*: true, and useless, because it does not say why it comes
back or why it changes between reloads.

The fourth was worse, because it sounded like evidence. Having moved both
ordinals into the shown list and seen the icon stay hidden, this file concluded
that the autosave name "is not what was breaking" and that only the manager's
own layout editor could fix it. Both halves were wrong, and for the same
reason: the ordinals were no longer this item's id at all. The name was — and
nobody had asked the manager what it thought the id was, which is one
AppleScript command it has always answered.

## What follows from it

`vpnbar doctor` now prints the Bartender id and the command that fixes it,
rather than telling anybody to go and drag something.
