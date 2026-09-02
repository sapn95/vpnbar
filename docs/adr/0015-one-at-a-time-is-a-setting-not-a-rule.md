# 0015 — One connection at a time is a setting, and it never closes yours

**Status:** accepted, 2026-09-03.

## The decision

Two settings live beside the profiles rather than inside them, because both are
about the menu as a whole:

| Setting | Default | What it does |
| --- | --- | --- |
| `exclusive` | `false` | Autoconnect never starts a second tunnel while one is up or on its way up, and takes down any extra **it started** |
| `fallback` | `true` | Whether autoconnect may try a connection's `fallback` at all |

Both are toggled from **Connections → Settings**, with a tick showing where
they stand, and both clear autoconnect's memory when changed: its record of
failures under the old rules is not evidence about the new ones.

## Why `exclusive` does not close a tunnel you opened

Because that would be the menu overruling a person, and this project has drawn
that line once already ([ADR 0005](0005-crud-is-over-the-menu-not-the-system.md)):
what autoconnect started, autoconnect may take back; everything else it
reports. A setting that silently killed a tunnel somebody opened thirty seconds
earlier would be a bug report, not a feature — and there would be no way to
tell it from one.

So `exclusive` is a rule about **what autoconnect does**, stated in those words
in its own tooltip. If two tunnels are up because a person opened both, the
menu shows two and says nothing.

## Why a setting rather than always on

Because the answer is a property of the machine, not of the software. Two VPNs
to the same place is a routing table with an argument in it; two VPNs to
different places is an ordinary Tuesday. Only the person at the keyboard knows
which of those they have.

## Why `fallback` can be switched off

A fallback that is reachable when the wanted connection is not is exactly the
thing you want at four in the afternoon and exactly the thing you do not want
while you are trying to work out why the wanted one keeps failing. Off, the
loop keeps asking for the one that was actually chosen, which is what makes the
failure legible.
