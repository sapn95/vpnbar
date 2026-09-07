# 0016 — The menu-bar item has a name, and why that is only half the story

**Status:** accepted, 2026-09-03.

## The decision

```lua
hs.menubar.new(true, "vpnbar")
```

The second argument is an autosave name. Hammerspoon's own documentation says
what it is for: *so that macOS can restore the menubar position between
restarts.* Without one, the status item gets a fresh identity every time the
Spoon starts, and macOS has nothing to restore a position from.

## What it does not fix, and what actually went wrong

The icon kept disappearing behind a menu bar manager, and this was blamed on
the manager several times before anybody looked. Bartender's own preferences
say otherwise:

```text
org.hammerspoon.Hammerspoon-Item-0   ->  Hide
org.hammerspoon.Hammerspoon-Item-1   ->  Show
```

It addresses status items as `<bundle-id>-Item-<n>` — **by ordinal, not by
identity**. Hammerspoon owns two of them here: its own icon and this one. Which
of the pair is `Item-0` depends on which was created first, and that is a race
between a Spoon starting and the application it starts in. One reload the
manager's rule lands on this icon, the next it lands on the other.

Nothing a Spoon can set changes that, autosave name included.

Nor is the ordinal the whole answer. With **both** ordinals moved into `Show`
and `Hide` left empty, the icon is still parked off-screen — so those lists are
not the control either. What is measurable is this:

| Bartender | icon |
| --- | --- |
| quit | `x=1477`, in the menu bar |
| running | `x=-9151`, off-screen |

Its live layout lives somewhere its preferences file does not expose, and it
rewrites that state itself. The only reliable lever is its own layout editor,
by hand. This is recorded here so the next person spends five seconds on it
rather than an evening.

## Why keep the name then

Because it is right on its own terms — the position survives a reload, which it
did not before — and because it costs one argument. It is simply not the thing
that was breaking.

## What was rejected

**Guessing again.** The first three explanations offered for this were versions
of "a menu bar manager is hiding it", which is true and useless: it does not say
why it comes back, or why it changes between reloads. The preferences file
answers both in two lines, and reading it took less time than any of the
guesses.
