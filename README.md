# vpnbar

**One button in the menu bar for every VPN on this Mac: what is up, one click
to change it, and add, rename, reorder or remove without leaving the menu.**

macOS already has a menu-bar item per VPN client, and that is the problem. Each
one shows its own state in its own idiom, disconnecting is two clicks into a
vendor panel, and the one that matters most on this machine does not appear in
the system's own VPN list at all — so no amount of `scutil` tells you whether it
is up. vpnbar puts the answer in one glyph and the action one click under it.

It is a [Hammerspoon](https://www.hammerspoon.org) Spoon. Hammerspoon is already
running here for the lock and sleep policy; this adds a menu, not a daemon.

The mark itself is drawn, not typed: a shield, filled with a tick cut out of it
when a tunnel is up, an outline when none is, and faint when it could not be
read. It is a template image, so macOS tints it to the bar it is sitting on and
the state is carried by the fill rather than by a colour that would be wrong in
two of the three tints ([ADR 0011](docs/adr/0011-the-menu-bar-mark-is-a-template-image.md)).

```text
●2                        ← two tunnels up: the mark, plus a count
├─ ●  Work VPN            → click to disconnect
├─ ○  Gateway VPN         → click to connect
├─ ◐  GlobalProtect       → working, click to disconnect anyway
├─ ────────────
├─ Connections ▸
│    Add a connection ▸  scutil · GlobalProtect · Shell
│    Import from scutil…
│    ────────────
│    Work VPN ▸  Rename… · Edit… · Move up · Move down
│                Hide · Monitor only · Remove…
│    ────────────
│    Open the config file
│    Reload from disk
└─ Refresh now
```

## What CRUD means here

**The menu owns its own list of connections, not the system's.** Adding a
connection adds a row to `~/.config/vpnbar/profiles.json`; removing one removes
that row. Nothing is installed, nothing is uninstalled, and no macOS network
service is created or destroyed — see
[ADR 0005](docs/adr/0005-crud-is-over-the-menu-not-the-system.md) for why that
line is where it is. `Import from scutil…` reads what macOS already has and
offers to list it; it never writes back.

## The three ways in

| Backend | For | How it connects | How it reads the state |
| --- | --- | --- | --- |
| `scutil` | Anything in `scutil --nc list` | `scutil --nc start` / `stop` | `scutil --nc status` |
| `globalprotect` | The Palo Alto agent | Clicks its own menu-bar panel through the accessibility API | An interface probe, or the panel's own status line on demand |
| `shell` | Everything else | Two commands you give | A third command you give, if you give one |

The AWS VPN Client is in neither of the first two — no `scutil` service, and no
accessibility tree at all — so it is a `shell` profile pointed at
`scripts/aws-vpn-client.sh`, which talks to the management interface its
bundled OpenVPN listens on. That is the escape hatch working as intended: a
config entry, not a patch
([ADR 0009](docs/adr/0009-the-aws-vpn-client-is-driven-through-openvpns-management-interface.md)).

The `shell` backend is the reason this is not a list of three: a VPN vpnbar has
never heard of needs a config entry, not a patch.

### Why GlobalProtect is special

The GlobalProtect agent does not run its tunnel through the VPN service macOS
knows about. On this machine `scutil --nc status` reports that service as
`Disconnected` while the tunnel is up and carrying traffic, because the agent
uses its own system extension and drives it itself. There is no CLI, no
AppleScript dictionary and no URL scheme for connect or disconnect — the only
door in is the accessibility API, which is what
[ADR 0001](docs/adr/0001-globalprotect-is-not-a-scutil-vpn.md) records and what
this code uses. The consequence for the menu: **give a GlobalProtect connection
a probe**, or reading its state means opening its panel.

## Tunnels that must stay up

Not every VPN in the menu is one you are allowed to drop. A profile with
`"monitor": true` shows its glyph, its name and its state, is greyed out, and
carries no action at all — because a menu item that would breach an always-on
requirement is one mis-click, and the mis-click looks exactly like the thing
the menu is for. The rule is enforced in the menu *and* in the backend, so no
other route reaches it either. Renaming, reordering and removing still work:
those change this menu's list, not the tunnel
([ADR 0008](docs/adr/0008-an-always-on-vpn-is-monitored-not-controlled.md)).

## Connecting on its own, and falling back

A connection set to **Connect automatically** is asked to come up whenever it
is down — at most one per refresh, never more than once a minute. After two
tries it moves to its **fallback**, if that one is not already up, on its way
up, or monitored. After six it stops until something happens that makes the old
failures meaningless: the connection comes up, the Mac wakes, or you toggle it.

All of that is one pure function returning at most one action, so the policy is
nineteen fast tests rather than an afternoon of waiting
([ADR 0013](docs/adr/0013-autoconnect-is-a-plan-not-a-timer.md)).

## Force disconnect

Offered **only** where there is genuinely something stronger to run — a `shell`
profile whose config gives it a `commands.force`. Never for `scutil` or
GlobalProtect, where it would run the identical command under a stronger name
([ADR 0012](docs/adr/0012-force-is-only-offered-where-one-exists.md)).

The AWS helper's version is the shape to copy: ask through the management
interface, wait, and only then quit the client — the tunnel goes with it.

## The probe

A probe says "this VPN, and only this VPN, hands out an address in this range":

```json
"probe": { "cidr": "10.0.0.0/8", "interface": "utun" }
```

With one, the state comes from `ifconfig` — no panel, no shell per connection,
nothing on screen — which is why a probe wins over whatever the backend would
have said. Without one, a `scutil` or `shell` connection still answers cheaply
enough, and a `globalprotect` connection reads `unknown` until you click
**Refresh now**. That asymmetry is deliberate, and
[ADR 0003](docs/adr/0003-a-probe-beats-asking-the-app.md) says why.

## Install

```bash
brew tap sapn95/vpnbar git@github.com:sapn95/vpnbar.git
brew install --HEAD sapn95/vpnbar/vpnbar
vpnbar link
```

The tap is the repository itself, over SSH: it is private, and a formula in a
public tap would need a token in the environment of whoever runs `brew install`
([ADR 0014](docs/adr/0014-homebrew-installs-it-and-vpnbar-link-puts-it-in-place.md)).
`vpnbar link` is a separate step because a formula must not write into a home
directory. From a checkout instead:

```bash
git clone git@github.com:sapn95/vpnbar.git ~/git/vpnbar
~/git/vpnbar/scripts/install.sh
```

Then in `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("VpnBar"):start()
```

The installer symlinks rather than copies, so `git pull` is the whole update.
Hammerspoon needs Accessibility permission for the `globalprotect` backend; it
already has it here for other reasons, and without it the other two backends
still work.

**If the icon does not appear, run `vpnbar doctor` before anything else.** It
checks Hammerspoon, the link and the line in `init.lua`, and then asks
Hammerspoon where the icon actually is. The usual answer is that it is drawing
perfectly, in the menu bar, at x = −9224, because a menu bar manager is holding
it off-screen — in Bartender that is **Settings → Menu Bar Layout**, where the
item has to be dragged from *Hidden Items* into *Shown Items*.

Start with an empty menu and `Import from scutil…`, or write
`~/.config/vpnbar/profiles.json` by hand — the format is in
[docs/configuration.md](docs/configuration.md).

| | |
| --- | --- |
| [docs/configuration.md](docs/configuration.md) | Every field in the config file |
| [docs/architecture.md](docs/architecture.md) | The modules, one refresh, one click, and the accessibility path |
| [docs/adr/](docs/adr/) | Why it is like this, and what was rejected |

## Development

```bash
make check      # what CI runs: format, lint, tests, coverage floor
make format     # rewrites rather than checks; never run in CI
```

Lua 5.4, because that is what Hammerspoon embeds:

```bash
brew install lua@5.4 stylua luarocks
luarocks --lua-version=5.4 install --local busted
luarocks --lua-version=5.4 install --local luacheck
luarocks --lua-version=5.4 install --local luacov
```

The coverage floor is 85% and lives in `scripts/coverage-floor.lua`. It counts
`VpnBar.spoon/vpnbar/` only: everything that decides anything is there and is
tested with no Hammerspoon in the room, while `init.lua` is the adapter and is
kept thin instead of covered —
[ADR 0002](docs/adr/0002-a-pure-core-and-a-thin-shell.md).

## What has been proved, and what has not

Honest state of play, because a menu that lies about a tunnel is worse than no
menu:

- **Proved on this machine.** GlobalProtect's tunnel is not the `scutil`
  service; the agent's menu-bar panel is a native accessibility tree, not a web
  view; its panel exposes an options popup and a status line; `scutil --nc
  list` and `--nc status` parse as the tests assume; an interface probe
  identifies a live tunnel. The Spoon itself loads in Hammerspoon, reads a
  config, polls both backends, renders its glyph in the menu bar and stops
  again without leaving anything behind.
- **Proved for the AWS VPN Client.** No `scutil` entry, no accessibility tree,
  no command line; OpenVPN's management interface on `127.0.0.1:35001` with a
  session password file, taken from a real session's own logs. The helper is
  covered by ten tests against a stubbed socket.
- **Not yet exercised against a live tunnel.** Two write paths: the click that
  disconnects GlobalProtect, and `signal SIGTERM` to the AWS management
  interface. The GlobalProtect panel was read while it was *connecting*, and
  the control that appears once connected was not captured — so the code looks
  for a control whose text contains `disconnect` anywhere in the panel *and* in
  the options menu, rather than at a remembered position. Both read paths are
  proved; both write paths are still first-time code.
- **Deliberately not done.** Nothing here presses *Disable*: on a GlobalProtect
  panel that is a different action with a different meaning, and this menu
  cannot undo it.

## Private on purpose

This repository describes how a specific machine reaches specific networks. No
portal hostnames, service names, address ranges or account names belong in it —
they live in `~/.config/vpnbar/profiles.json`, which is not in git. The
fixtures keep the shape of real output and invent every value in it. Write the
rule, not the example.
