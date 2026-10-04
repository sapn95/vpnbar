# 0037 — A dialog that looks like vpnbar

**Status:** accepted, 2026-10-04.

## The decision

The question about routes left behind is asked through AppleScript's `display
dialog` with vpnbar's own mark on it, rather than through `hs.dialog`.

## Why

`hs.dialog` has no way to set an icon, so every dialog it draws carries
Hammerspoon's hammer. On a question about a route table, from a menu bar item
with a shield in it, that is an icon from a different program asking for an
administrator password. `display dialog` takes `with icon POSIX file`, so the
mark the menu bar already uses can go on it.

The mark is drawn once, at 256 px, into `~/Library/Caches/vpnbar/mark.png`.
Filled in the system accent blue with the tick in white, rather than as the
template the menu bar draws: a template is black, and black on a dialog in the
dark appearance is nothing at all. `icon.tick` is exported alongside
`icon.shield` for it, so both shapes have one definition.

## What it costs

A dismissed dialog, Escape rather than a button, comes back as an error from
AppleScript rather than as a button name. That is a no, and it is treated as
one. Where the mark cannot be written, the old `hs.dialog` call is still there
and the hammer comes back, which is worse-looking and not broken.

## What was rejected

- **Changing Hammerspoon's own icon.** It belongs to every Spoon the person
  runs, and borrowing it for this one would relabel all of them.
- **One of AppleScript's built-in icons.** `note` and `caution` are better than
  a hammer and still not this program.
- **Shipping a `.png` in the repository.** The shape is already in the code, as
  the thing the menu bar draws. A second copy in a file is a second copy to keep
  in step.
