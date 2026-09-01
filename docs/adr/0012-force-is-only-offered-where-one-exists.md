# 0012 — Force disconnect is only offered where one exists

**Status:** accepted, 2026-09-01.

## The decision

**Force disconnect** appears in a connection's submenu only when
`backends.canForce` says there is genuinely something stronger to run — which
today means a `shell` profile whose config gives it a `commands.force`. It is
never shown for `scutil`, never for `globalprotect`, and never for a monitored
connection.

## Why not offer it everywhere

Because for two of the three backends it would run the identical command.
`scutil --nc stop` has no harder form. The GlobalProtect panel has one
Disconnect and nothing behind it. A second menu item that runs the same thing
under a stronger name is a promise the menu cannot keep, and the person who
clicks it is by definition already having a bad time.

Nor is it greyed out where it does not apply: a disabled entry says "this
exists but not now", and that is also untrue.

## What force actually does

Whatever the config says, which is the point of the `shell` backend. The AWS
helper's version is the shape to copy: ask the tunnel to stop through OpenVPN's
management interface, wait a few seconds, and if the session is still there,
quit the client application — the tunnel goes with it. Ask first, close second.
`disconnect` never closes the app; `force` is the last resort and says so.
