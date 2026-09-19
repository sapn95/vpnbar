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

## Addendum, 2026-09-19: Bartender 7 on macOS 26

Three things changed under this decision. None of them changes it.

- **The id is spelled differently.** Bartender 7 calls the same item
  `plist:status:org.hammerspoon.Hammerspoon::vpnbar`. Its `list menu bar item
  details` command returns JSON with an `id`, a `name` and a `state` per item,
  and that `state`, `visible` or `hidden`, is the first reading of the icon
  from outside Hammerspoon this project has had. The doctor prints it.
- **`show` does not move it.** Measured: `tell application id
  "com.surteesstudios.Bartender" to show "<id>"` returned without an error and
  the state stayed `hidden`. The item was in Bartender's catalog and in neither
  hidden list of its profile, and it was hidden anyway; what decides that is
  not in any setting this file could read. So the doctor no longer prints a
  command that fixes it. It names the item and the place in Bartender's
  settings where it is dragged, which the fourth attempt above was wrong to
  say then, for Bartender 6, and is right now, for Bartender 7.
- **Hidden means no window, not a window off-screen.** `hs.menubar:frame()`
  returned `x=0 y=1117 w=22 h=0` for the icon while Bartender called it
  hidden, and the same for a fresh test item, which Bartender's setting for
  new items sends to the hidden section too. After `show` and two toggles of
  the hidden section it was `x=1297 y=0 w=22 h=33`, with the state still
  `hidden`. So the frame reports whether the item has a window right now, and
  Bartender reports what it has decided; the doctor prints both and treats a
  zero-height frame as "no frame", where before it read it as "on screen at
  x=0".

Bartender was addressed as `application "Bartender 6"`. It is now addressed by
bundle id, `com.surteesstudios.Bartender`, which the version does not change.
