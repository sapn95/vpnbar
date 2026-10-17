# 0037 — A dialog that looks like vpnbar

**Status:** accepted, 2026-10-04.

## The decision

The question about routes left behind is asked through AppleScript's `display
dialog` with vpnbar's own mark on it, rather than through `hs.dialog`.

## Why

`hs.dialog` has no way to set an icon, so every dialog it draws carries
Hammerspoon's hammer. On a question about a route table, from a menu bar item
with a padlock in it, that is an icon from a different program asking for an
administrator password. `display dialog` takes `with icon POSIX file`, so the
mark the menu bar already uses can go on it.

The mark is drawn once, at 256 px, into `~/Library/Caches/vpnbar/mark.png`.
Filled in the system accent blue with the keyhole in white, rather than as the
template the menu bar draws: a template is black, and black on a dialog in the
dark appearance is nothing at all. The keyhole is drawn rather than cut out,
because there is no menu bar behind a dialog to show through. `icon.coloured`
is the one definition of that version, so the shape has no second copy.

## The launcher's icon, added 2026-10-17

`vpnbar app` writes a bundle with no `CFBundleIconFile` and no `Resources`, so
Launchpad and Spotlight showed it with the generic application icon. It gets the
same mark now, for the same reason the dialog does: a template is black and
black is nothing on half the Dock backgrounds there are.

It is rendered rather than shipped. `vpnbar app` asks Hammerspoon for
`icon.coloured` at the ten sizes `iconutil` wants, writes them into an iconset
and turns that into `Contents/Resources/vpnbar.icns`. A committed `.icns` would
be a second definition of the shape, free to drift from `icon.lua` the first
time the mark changes.

Failing to draw one is not a failure of the command. `vpnbar app` has to work on
a machine where Hammerspoon is not up yet, so the bundle is written without an
icon, the plist names none, a stale icon from an earlier run is removed, and the
command says to run it again once Hammerspoon is there. A plist naming an icon
that is not in the bundle is worse than one naming nothing.

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
