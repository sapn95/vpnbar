# 0025 — There is a way in, not only a way out

**Status:** accepted, 2026-09-15.

## The decision

`vpnbar start`, `vpnbar stop` and `vpnbar restart` talk to Hammerspoon over its
command line. `vpnbar app` writes a small application bundle into
`~/Applications` whose only job is to run `vpnbar start`.

`obj:start()` now stops a running Spoon before starting one.

## What went wrong

[ADR 0019](0019-quit-stops-the-spoon-and-nothing-else.md) gave the menu a Quit
that stops the Spoon and leaves Hammerspoon running, which is right: Hammerspoon
runs other things on this machine and quitting it would take them with it. The
tooltip said the way back was a Hammerspoon reload.

That was the whole recovery path, and it is a bad one. Reloading Hammerspoon
reloads every other config it holds, to restart one menu. Worse, nothing on the
machine looked like vpnbar: no icon in Launchpad, no name in Spotlight, no verb
in the command line. `vpnbar doctor` would say **"vpnbar is not running inside
Hammerspoon — 1 thing to fix"** and then offer no way to fix it.

A tool with a documented way out and no way in is not finished.

## Why an application bundle and not only a command

A Spoon has no application of its own, and that is usually invisible because the
menu bar item is the application as far as anybody is concerned. When the item
is gone, so is every trace. Somebody looking for the thing they were using looks
in Launchpad and in Spotlight, and until now found nothing in either.

The bundle is a launcher: it runs `vpnbar start` and exits. It carries
`LSUIElement`, so the Dock does not show a bouncing icon for a program that has
already finished.

## Why it looks for `hs` inside the Hammerspoon bundle

This is what made the first version of the bundle useless. A double-clicked
application gets `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, and `hs` lives in
`/opt/homebrew/bin` only because something put a symlink there. Looked up on
`PATH` alone, the launcher worked from a terminal and did nothing at all when
clicked, with the error going nowhere anybody would see it.

`hs` is really inside `Hammerspoon.app/Contents/Frameworks/hs/hs`, which does
not depend on a shell profile, so that is asked first. `VPNBAR_HS` overrides the
search, which the tests set: a search that reaches an absolute path finds the
real Hammerspoon on a developer's machine, and a test then starts the menu
somebody is actually using. That happened once here before the override existed.

## Why starting goes through stopping

`start` assigned `self.timer` and `self.wake` without stopping what was already
in those fields. Hammerspoon kept firing the old ones. Two timers meant two
reads and two autoconnect attempts per interval, each unaware of the other.
`stop` is the one place that knows the full list of things to take down, so
`start` calls it rather than keeping a second copy of that list in its head.

## What was rejected

- **A launch agent.** It would start vpnbar without Hammerspoon's knowledge,
  and there is nothing for it to start: the Spoon only exists inside a running
  Hammerspoon, which is already a login item.
- **Removing Quit.** The reason for it has not changed
  ([ADR 0019](0019-quit-stops-the-spoon-and-nothing-else.md)). What was missing
  was the other direction.
- **Making the bundle the real application.** It would mean shipping a copy of
  Hammerspoon's job, and the Spoon is deliberately a Spoon
  ([ADR 0002](0002-a-pure-core-and-a-thin-shell.md)).
- **Having `vpnbar link` write the bundle.** Linking is about Hammerspoon
  finding the code; an icon in Launchpad is a separate thing to want, and a
  command that quietly creates an application is a surprise.
