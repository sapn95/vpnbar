# 0006 — The config file is executable by proxy, and stays out of the repo

**Status:** accepted, 2026-09-01.

## The decision

The `shell` backend runs the `connect`, `disconnect` and `status` commands
exactly as the config file gives them. That file therefore has the same weight
as a shell script: whoever can write it can run code as the user, the moment
the menu is opened.

Three things follow, and they are the whole of the security posture here:

1. The config lives at `~/.config/vpnbar/profiles.json`, under the user's own
   account. vpnbar never fetches it from anywhere, never merges a remote one,
   and has no import path that takes a URL.
2. Nothing else is interpolated into a shell. Service names — which arrive from
   `scutil --nc list` and from the file — go through `backends.shellQuote`, so
   a name containing a quote is a name, not a command.
3. The repository holds no real configuration. Examples are `10.0.0.0/8` and
   "Work VPN"; the machine's actual ranges and service names live only in the
   file above.

## What was rejected

**Restricting `shell` to a vetted list of commands.** It is the escape hatch
that lets a VPN this project has never heard of work without new code, and a
list of permitted commands would have to be edited from the same file it is
supposed to protect. The honest version is to say plainly what the file can do,
which is this document.
