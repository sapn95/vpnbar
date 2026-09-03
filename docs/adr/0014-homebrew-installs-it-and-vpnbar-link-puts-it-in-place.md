# 0014 — Homebrew installs it, and `vpnbar link` puts it in place

**Status:** accepted, 2026-09-01.

## The decision

`Formula/vpnbar.rb` lives **in this repository** rather than in a separate tap,
and is used by tapping the repository itself:

```bash
brew tap sapn95/vpnbar https://github.com/sapn95/vpnbar.git
brew install --HEAD sapn95/vpnbar/vpnbar
vpnbar link
```

The formula installs the Spoon into `libexec` and two commands into `bin`. It
does **not** put the Spoon into `~/.hammerspoon/Spoons`: a formula must not
write to a home directory, so `vpnbar link` is a separate step the user asks
for, and `vpnbar unlink` takes it out again.

## Why a tap of the repository, and not a tap of its own

One place to change, and no second repository to keep in step —
`sapn95/git-tidy` carries its formula the same way.

While this repository was **private** there was a second reason, and it is
worth keeping written down because it shaped the file: a formula in a public
tap would have had to fetch a tarball from a private repository, which needs a
token in the environment of whoever runs `brew install`. Tapping the repository
itself over SSH used the keys the user already had. Now that it is public the
URL is plain HTTPS and anybody can install it.

`head`-only, which the private phase also forced (a versioned release means a
release asset, and a private release asset has the same token problem) and
which still suits a tool that has no releases.

One trap, paid for once: the `head` URL must be a real URI. `brew tap` accepts
the scp-style `git@github.com:owner/repo.git`, and the formula does not —
Homebrew parses it with `URI` and refuses that form with `bad URI (is not
URI?)`, which is what made the failure look like it came from somewhere else.

## Why there is a `doctor`

Because the first thing that went wrong was not vpnbar. The icon was drawing
correctly, in the menu bar, at x = −9224: Bartender was holding it off-screen,
which is indistinguishable from a program that failed to start. `vpnbar doctor`
checks Hammerspoon, the link, the line in `init.lua`, and then asks Hammerspoon
where the icon actually is — and a large negative x is reported as what it is,
with the two clicks that fix it.
