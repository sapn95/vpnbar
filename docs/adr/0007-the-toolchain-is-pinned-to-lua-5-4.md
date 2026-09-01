# 0007 — The toolchain is pinned to Lua 5.4

**Status:** accepted, 2026-09-01.

## The decision

CI installs Lua **5.4** explicitly, and the local `make check` expects the same.
On a Mac that means `brew install lua@5.4` beside whatever `lua` currently is.

## Why

Two reasons, and the second is the one that bites.

Hammerspoon embeds Lua 5.4, so 5.4 is the version this code actually has to run
under. Testing on anything else tests a language the Spoon will never see.

And Homebrew's `lua` has moved to **5.5**, where `luacheck` 1.2.0 does not run
at all: it fails while loading its own standard-library definitions, because
5.5 made assignment to a `const` an error. A checkout on a current Mac, using
the obvious `brew install lua luarocks`, therefore has a lint step that cannot
start — which reads like a broken repository rather than a broken tool.

## What follows from it

`README.md` names `lua@5.4` in the development setup, and the CI workflow pins
`LUA_VERSION` in one place. When luacheck supports 5.5, this is one number in
two files.
