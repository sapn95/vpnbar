# 0014 — Homebrew installs it, and `vpnbar link` puts it in place

**Status:** accepted, 2026-09-01.

## The decision

`Formula/vpnbar.rb` lives **in this repository** rather than in a public tap,
and is used by tapping the repository itself:

```bash
brew tap sapn95/vpnbar git@github.com:sapn95/vpnbar.git
brew install --HEAD sapn95/vpnbar/vpnbar
vpnbar link
```

The formula installs the Spoon into `libexec` and two commands into `bin`. It
does **not** put the Spoon into `~/.hammerspoon/Spoons`: a formula must not
write to a home directory, so `vpnbar link` is a separate step the user asks
for, and `vpnbar unlink` takes it out again.

## Why a tap of the repository, and not a tap of its own

The repository is private. A formula in a public tap would have to fetch a
tarball from a private repository, which needs a token in the environment of
whoever runs `brew install`. Tapping the repository over SSH uses the keys the
user already has for it, and nothing has to be published anywhere.

`head`-only, for the same reason: a versioned release would mean a release
asset, and a private release asset has the same token problem.

One trap, paid for once: the `head` URL must be a real URI —
`ssh://git@github.com/sapn95/vpnbar.git`, not the scp-style
`git@github.com:sapn95/vpnbar.git`. Homebrew parses it with `URI` and refuses
the short form with `bad URI (is not URI?)`. `brew tap` accepts either, which
is what makes the failure look like it comes from somewhere else.

## Why there is a `doctor`

Because the first thing that went wrong was not vpnbar. The icon was drawing
correctly, in the menu bar, at x = −9224: Bartender was holding it off-screen,
which is indistinguishable from a program that failed to start. `vpnbar doctor`
checks Hammerspoon, the link, the line in `init.lua`, and then asks Hammerspoon
where the icon actually is — and a large negative x is reported as what it is,
with the two clicks that fix it.
