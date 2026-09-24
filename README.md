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

The mark also says when it is busy. The first read after login, the minute after a
wake, and a click that has to open an app's window and press a row in it all turn
the shield into an outline with a dot that breathes, and it goes back to reporting
the state once the work is done. On a machine with an always-on tunnel that is the
difference between an icon that means something and one that reads `connected`
from login to shutdown
([ADR 0017](docs/adr/0017-the-mark-says-when-it-is-working.md)).

```text
●2                        ← two tunnels up: the mark, plus a count
├─ Switch to Gateway VPN  → be on the other one now, and stay there
├─ ────────────
├─ ●  Work VPN            → click to disconnect
├─ ○  Gateway VPN         → click to connect
├─ ◐  GlobalProtect       → working, click to disconnect anyway
├─ ────────────
├─ Disconnect everything  → all of them that are not protected
├─ Quit every VPN app     → closes the clients, one row per app
├─ ────────────
├─ Connections ▸
│    Add a connection ▸  scutil · GlobalProtect · AWS VPN · Shell
│    Import from scutil…
│    ────────────
│    Work VPN ▸  Rename… · Edit… · Move up · Move down
│                Hide · Protect from disconnecting · Remove…
│                Force disconnect, Quit <app>, Restart <app> — where they apply
│    ────────────
│    Settings ▸  Only one connection at a time · Use fallbacks
│    ────────────
│    Open the config file
│    Reload from disk
├─ Refresh now
├─ ────────────
└─ Quit vpnbar            → the icon goes, nothing is disconnected
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
| `awsvpn` | The AWS VPN Client | Clicks the row for the profile you name | A command you give |
| `shell` | Everything else | Two commands you give | A third command you give, if you give one |

The AWS client has no `scutil` service and no command line, so `awsvpn` clicks
the row you name and reads the state from a cheap command that opens no window
([ADR 0009](docs/adr/0009-the-aws-vpn-client-is-driven-through-openvpns-management-interface.md)).
Version 6 of the client dropped OpenVPN and with it the management interface the
helper used to ask, so the state now comes from the client's own log — which,
unlike the interface it replaces, says *which* profile is up
([ADR 0027](docs/adr/0027-the-aws-client-stopped-having-a-management-interface.md)).

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
a probe**, or reading its state means opening its panel. When the probe says
the tunnel is down, the agent's own event log is read once more to tell *down*
from *down because the session ended*: the second reads as `needs your login`,
and the next connect will open a SAML window rather than a tunnel
([ADR 0029](docs/adr/0029-an-attempt-that-needs-a-person-waits-for-one.md)).

## Tunnels that must stay up

Not every VPN in the menu is one you are allowed to drop. A profile with
`"protected": true` can never be disconnected from here, and can always be
connected — the protection points one way. Up, the row reports and is greyed
out; down, it offers a single click to bring it back.

That direction matters: a tunnel that must stay up is exactly the one worth
bringing back automatically, and exactly the one that should have a fallback
when it will not come. Enforced in the menu *and* in the backend, so no other
route reaches it either
([ADR 0008](docs/adr/0008-an-always-on-vpn-is-protected-from-being-disconnected.md)).

## Connecting on its own, and falling back

A connection set to **Connect automatically** is asked to come up whenever it
is down — at most one per refresh, never more than once a minute. After two
tries it moves to its **fallback**, if that one is not already up or on its way
up. It never stops. The gap between attempts doubles instead, from one minute up to
fifteen, and stays there for as long as it takes
([ADR 0024](docs/adr/0024-autoconnect-backs-off-it-does-not-give-up.md)). An
always-on VPN that is down while the thing meant to bring it up has decided not
to is the state this is here to remove. One thing does stop it asking, and that
is a client nobody has open: *Quitting and restarting the clients*, below.

A connection that **needs your login** is the one exception. Its session has
ended, so a retry opens a login window and nothing else, and a login window
needs a person: it is held while the screen is locked, and otherwise until a
minute has passed without a keystroke, except right after a wake or an unlock,
when one is let through at once. A connection that is merely down reconnects
silently and is never held, at any hour
([ADR 0029](docs/adr/0029-an-attempt-that-needs-a-person-waits-for-one.md)).

Anything that makes the old failures meaningless puts it back on the fast path:
the connection comes up, the Mac wakes, somebody unlocks it, or you toggle the
setting. An unlock counts because a machine that has been sitting locked has had
no reason to notice that the network in front of it changed, and because
somebody is now there to finish a login if one is needed
([ADR 0023](docs/adr/0023-an-unlock-is-a-fresh-start.md)).

And when the wanted one does come up, the stand-in is taken back down. Two
tunnels to the same place is not twice the connectivity, it is one routing
table with an argument in it. Only what autoconnect itself started, though —
a tunnel opened by hand is nobody's to close but yours.

The pairing this was built for: the always-on corporate VPN is `protected` and
set to connect automatically, with the AWS client as its `fallback`. AWS then
only ever comes up when the first one would not.

All of that is one pure function returning at most one action, so the policy is
a few dozen fast tests rather than an afternoon of waiting
([ADR 0013](docs/adr/0013-autoconnect-is-a-plan-not-a-timer.md)).

## Only one at a time

**Connections → Settings** has two switches. *Only one connection at a time*
stops autoconnect starting a second tunnel while one is up, and takes down any
extra it started. *Use fallbacks* turns the fallback step off, so the loop
keeps asking for the connection you actually chose.

*Only one connection at a time* means it. The connection ranked highest stays
up and every other tunnel is taken down, whoever opened it and whether or not it
is `protected`. Rank is the order in the menu, so **Move up** and **Move down**
decide which one survives, and both rows now say so
([ADR 0026](docs/adr/0026-one-at-a-time-outranks-protection.md)).

Protection is narrowed rather than removed. The closing is asked for under its
own verb that no menu item can produce, so **Disconnect**, **Force disconnect**
and **Disconnect everything** go on refusing a protected connection exactly as
before. Switched off, the older and narrower rule stands: only the stand-in
autoconnect started for this very connection
([ADR 0015](docs/adr/0015-one-at-a-time-is-a-setting-not-a-rule.md)).

## Switch to the other one

The first row of the menu is **Switch to** followed by the other connection's
name, or a submenu when there are several. It is for the afternoon the
connection you chose is crawling: it connects the other one now and makes it
the one that stays up, so *Only one connection at a time* takes the slow one
down once the new one is connected, instead of the new one. The order in the menu is not touched; the preference lasts until
vpnbar restarts, and the row then reads **Switch back to …**. A plain Connect
does not do this, because the planner would take the second tunnel straight
down again ([ADR 0030](docs/adr/0030-a-switch-is-a-preference-not-an-order.md)).
With *Only one connection at a time* off, the switch brings the other one up
and leaves the current one to you, and its tooltip says so.

## Force disconnect

Offered **only** where there is genuinely something stronger to run — a `shell`
profile whose config gives it a `commands.force`. Never for `scutil` or
GlobalProtect, where it would run the identical command under a stronger name
([ADR 0012](docs/adr/0012-force-is-only-offered-where-one-exists.md)).

The AWS helper's version is the shape to copy: ask through the management
interface, wait, and only then quit the client — the tunnel goes with it.

## Disconnect everything

One row, above **Connections**, once anything is up: it closes every connection
that is up or on its way up and is not protected, taking the harder path wherever
a config gives one. The confirmation names them.

Where everything up is protected it stays, greyed out, and says which connection
is holding it. That is deliberately the opposite of what **Force disconnect**
does when it does not apply, and
[ADR 0020](docs/adr/0020-disconnect-everything-leaves-the-protected-ones-alone.md)
says why: here there is a feature and a reason, and the reason is a setting two
submenus away.

## Quitting and restarting the clients

Any connection whose config names an `app` offers **Quit `<app>`** and **Restart
`<app>`** in its submenu, and one row above **Connections** closes all of them:
**Quit every VPN app**. One entry per application, so two connections through the
same client are one thing to quit
([ADR 0028](docs/adr/0028-quit-and-restart-are-per-application.md)).

It quits the app, insists if it does not go, and for a restart opens it again.

The same command is two different promises. Closing GlobalProtect closes a user
interface and its tunnel is held by a root service, so it survives — which is why
this is offered on a **protected** connection, the one whose only repair it is
([ADR 0021](docs/adr/0021-restarting-the-agent-is-not-a-disconnect.md)). Closing
the AWS client ends the session, because that client is the tunnel's own parent,
so on a protected connection those two rows are absent: a button that
disconnects a protected tunnel is the one thing this menu does not have.

Quitting is a decision, so autoconnect stops asking. Every connection through
that client is left alone from then on, and the client coming back does not
change that: GlobalProtect's launch agent reopens it within seconds, and a rule
that went by what was running would have reconnected the tunnel you had just
closed. The rows say so for as long as it lasts, and **Resume autoconnect for
`<app>`** hands them back. So does connecting one of them, switching to one,
restarting the client, or the connection coming up on its own. Restarting vpnbar
forgets it ([ADR 0031](docs/adr/0031-autoconnect-does-not-undo-a-quit.md)).

A client that is merely closed is held for a smaller reason: there is nothing to
click in, so the attempt fails and spends its backoff, and a client closed for a
quarter of an hour would be a connection that waits a quarter of an hour after it
comes back. Its fallback gets the turn instead, as long as that one's client is
open. This is also the only way a quit made outside this menu is noticed, which
for the AWS client is the only quit there is.

## The probe

A probe says "this VPN, and only this VPN, hands out an address in this range":

```json
"probe": { "cidr": "10.0.0.0/8", "interface": "utun" }
```

With one, the state comes from `ifconfig` — no panel, no shell per connection,
nothing on screen — which is why a probe wins over whatever the backend would
have said. The interface must be up and running, not just present: a VPN agent
that loses its tunnel can leave the address behind on a dead interface, and
matching the address alone turns that into a menu reporting a VPN that is not
there ([ADR 0022](docs/adr/0022-a-probe-reads-the-interface-not-just-the-address.md)). Without one, a `scutil` or `shell` connection still answers cheaply
enough, and a `globalprotect` connection reads `unknown` until you click
**Refresh now**. That asymmetry is deliberate, and
[ADR 0003](docs/adr/0003-a-probe-beats-asking-the-app.md) says why.

## Install

```bash
brew tap sapn95/vpnbar https://github.com/sapn95/vpnbar.git
brew install --HEAD sapn95/vpnbar/vpnbar
vpnbar link
```

The tap is the repository itself, so there is one place to change and no second
repository to keep in step. `vpnbar link` is a separate step because a formula
must not write into a home directory
([ADR 0014](docs/adr/0014-homebrew-installs-it-and-vpnbar-link-puts-it-in-place.md)).
From a checkout instead:

```bash
git clone git@github.com:sapn95/vpnbar.git ~/git/vpnbar
~/git/vpnbar/scripts/install.sh
```

Then in `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("VpnBar"):start()
```

Then there is something to start:

```bash
vpnbar start      # start it inside a running Hammerspoon
vpnbar stop       # the same as Quit in the menu
vpnbar restart    # after brew upgrade: loads the installed code, not the cached one
vpnbar app        # an icon in Launchpad and Spotlight that runs start
```

**Quit** in the menu stops the Spoon and leaves Hammerspoon running, which is
the point of it. Until these existed the only way back was reloading
Hammerspoon and every other config with it, so the menu had a documented way out
and no way in ([ADR 0025](docs/adr/0025-there-is-a-way-in-not-only-a-way-out.md)).

The installer symlinks rather than copies, so `git pull` is the whole update.
A **copy** where that link belongs is the quiet failure: everything keeps
working and nothing updates, so `brew upgrade` refreshes code that nothing is
loading. `vpnbar doctor` tells the two apart and `vpnbar link` replaces a copy
with a link.
Hammerspoon needs Accessibility permission for the `globalprotect` backend; it
already has it here for other reasons, and without it the other two backends
still work.

**If the icon does not appear, run `vpnbar doctor` before anything else.** It
checks Hammerspoon, the link and the line in `init.lua`, and then asks two
parties where the icon actually is: Hammerspoon, for the item's frame, and
Bartender, when it is running, for what it is doing with the item. Older
managers park a hidden item at a large negative x; Bartender 7 gives it no
window at all, which reads as a frame of height 0, so Bartender's own answer
is the one that counts.

Bartender 7 can keep an item in its hidden section while its settings list it
nowhere, and its scripting does not move it out. A hidden icon is fixed in
Bartender's settings, under Menu Bar Layout, by dragging the Hammerspoon item
into the shown section. The doctor names the item:

```text
plist:status:org.hammerspoon.Hammerspoon::vpnbar
```

A **name** rather than an ordinal, because the status item is created with an
autosave name — which is the whole reason a manager's decision about it
sticks instead of landing on whichever Hammerspoon item happened to be first
([ADR 0016](docs/adr/0016-the-menu-bar-item-has-a-name.md)).

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
  covered by a suite of its own against a stubbed socket.
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

## Employer-neutral on purpose

This tool describes how a machine reaches particular networks, so no real
hostnames, service names, address ranges or account names belong in it. They
live in `~/.config/vpnbar/profiles.json`, which is not in git and never will
be. The fixtures keep the shape of real output and invent every value in it:
write the rule, not the example.

Half of that is enforced. `scripts/leak-lint.sh` runs in CI and in `make lint`,
and fails on any IPv4 address in the tree that is not from a documentation or
private range. Files nobody has added yet are searched as well, so a new one is
caught before it is committed. A run that could not look fails instead of
reporting a clean tree: if git will not list the files, or grep cannot read one
of them, the lint stops there. An **allowlist**, so it contains nothing worth
hiding and fails closed — the reasoning is
[container-commander's ADR 0011](https://github.com/sapn95/container-commander/blob/main/docs/adr/0011-employer-neutral-public-repo.md).

The other half cannot easily be: a VPN profile named after an employer looks
like any other word. That one is checked by reading, and it was got wrong here
once. Real profile names and two addresses out of a live session's log sat in
the fixtures and the decision records for two days, while the repository was
private, until somebody asked the direct question. They were taken out and the
history was rewritten before this became public.
