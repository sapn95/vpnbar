# Configuration

Everything vpnbar knows lives in one file:

```text
~/.config/vpnbar/profiles.json
```

**Connections → Add a connection ▸** picks a backend and then asks for one
field at a time; **Edit…** asks the same questions with the current answers
filled in. **Monitor only** and **Hide** are toggles in the same submenu. Only
the things below that no prompt covers need the file opening by hand.

It is written by the menu and it is safe to edit by hand — the menu re-reads it
every time it opens, and a file it cannot parse is refused with a notification
rather than replaced. Writes are atomic (a temporary file and a rename), so an
interrupted save cannot leave a half-written config behind.

## Shape

```json
{
  "version": 1,
  "profiles": [
    {
      "id": "work",
      "name": "Work VPN",
      "backend": "scutil",
      "service": "Work VPN",
      "order": 10,
      "hidden": false,
      "probe": { "cidr": "10.0.0.0/8", "interface": "utun" }
    }
  ]
}
```

## Every field

| Field | Required | Meaning |
| --- | --- | --- |
| `id` | yes | Lower-case letters, digits, `-` and `_`. Unique. What the config, the menu and the log agree on. |
| `name` | yes | Shown in the menu. Anything, including spaces and umlauts. |
| `backend` | yes | `scutil`, `globalprotect` or `shell`. |
| `order` | no | Sort key; the menu renumbers to 10, 20, 30 … whenever you move something. Defaults to position × 10. |
| `hidden` | no | Keeps it out of the top level but still manageable under **Connections**. Defaults to `false`. |
| `protected` | no | Never disconnected from here, always connectable. For a tunnel that must stay up. Defaults to `false`. |
| `autoconnect` | no | Bring it up on its own when it is down. Defaults to `false`. Works with `protected`, which is where it matters most. |
| `fallback` | no | The id of another connection to try when this one will not come up. Only used together with `autoconnect`. |
| `probe` | no | `{ "cidr": …, "interface": … }`. See below. |

### `backend: "scutil"`

| Field | Required | Meaning |
| --- | --- | --- |
| `service` | yes | Exactly the name `scutil --nc list` prints between the quotes. |

Connect and disconnect are `scutil --nc start` and `stop`; the state is the
first line of `scutil --nc status`. Use **Import from scutil…** rather than
typing these: it reads the list and adds everything not configured yet.

### `backend: "globalprotect"`

| Field | Required | Meaning |
| --- | --- | --- |
| `app` | yes | The agent's name in the menu bar. Defaults to `GlobalProtect`. |

Driven through the accessibility API, because the agent offers nothing else —
see [ADR 0001](adr/0001-globalprotect-is-not-a-scutil-vpn.md). Give it a
`probe`: without one its state is only read when you ask for it, since reading
it means opening the agent's panel on screen.

### `backend: "shell"`

| Field | Required | Meaning |
| --- | --- | --- |
| `commands.connect` | yes | Run by the shell when you click to connect. |
| `commands.disconnect` | yes | Run by the shell when you click to disconnect. |
| `commands.status` | no | Should print `connected`, `connecting` or `disconnected`. Without it the state is `unknown`, which is still clickable. |
| `commands.force` | no | The harder way down. **Force disconnect** appears in the menu only for a profile that has one. |

```json
{
  "id": "home",
  "name": "Home WireGuard",
  "backend": "shell",
  "commands": {
    "connect": "/opt/homebrew/bin/wg-quick up home",
    "disconnect": "/opt/homebrew/bin/wg-quick down home",
    "status": "/opt/homebrew/bin/wg show home"
  }
}
```

These strings are executed as written, by you, as you — the same trust as a
line in `~/.zshrc`. Use absolute paths: the shell Hammerspoon spawns does not
have a login shell's `PATH`.

#### The AWS VPN Client

`scripts/aws-vpn-client.sh` is a ready-made helper for it, and the reason the
`shell` backend exists: the client is in neither `scutil` nor the accessibility
API, but it runs OpenVPN with a management interface on `127.0.0.1:35001`, and
that answers both questions — see
[ADR 0009](adr/0009-the-aws-vpn-client-is-driven-through-openvpns-management-interface.md).

```json
{
  "id": "aws",
  "name": "AWS VPN",
  "backend": "shell",
  "commands": {
    "status": "$HOME/git/vpnbar/scripts/aws-vpn-client.sh status",
    "connect": "$HOME/git/vpnbar/scripts/aws-vpn-client.sh connect",
    "disconnect": "$HOME/git/vpnbar/scripts/aws-vpn-client.sh disconnect"
  }
}
```

Give it no `probe`: the client CIDR is a property of the endpoint, and a
machine with two profiles has two of them, while the management interface
answers for whichever session is actually running. **Connect opens the app and
stops** — these endpoints authenticate in a browser, and the login is finished
by hand. `AWS_VPN_MGMT_PORT` overrides the port if a future client moves it.

### `protected`

```json
{ "id": "corp", "name": "Corporate VPN", "backend": "globalprotect", "app": "GlobalProtect", "protected": true }
```

The protection points **one way**: this connection can never be disconnected or
force-disconnected from the menu, and can always be connected. Up or on its way
up, the row reports and is greyed out (`protected from disconnecting`); down,
it offers a single click to bring it back (`protected once it is up`).

Use it where staying connected is a requirement rather than a choice — the
state is still the most useful thing in the menu, and the button that would
break it should not exist
([ADR 0008](adr/0008-an-always-on-vpn-is-protected-from-being-disconnected.md)). It is enforced in the menu *and* in the
backend, so nothing brings such a connection down by another route. Renaming,
reordering, hiding and removing still work: those change this menu's list, not
the tunnel. Toggle it from **Connections → the connection → Protect from
disconnecting**.

### `autoconnect` and `fallback`

```json
{
  "id": "aws",
  "name": "AWS VPN",
  "backend": "shell",
  "autoconnect": true,
  "fallback": "aws-split",
  "commands": { "connect": "…", "disconnect": "…", "status": "…" }
}
```

Both are toggled and typed from the menu: **Connections → the connection → Connect
automatically**, and the fallback is the last question **Edit…** asks.

What then happens, on the refresh that already runs every ten seconds: a
connection that is `disconnected` is asked to connect, at most one per refresh,
never more often than once a minute. After two tries it moves to its
`fallback` — if that one is not itself up or on its way up. After six it stops,
until the connection comes up, the Mac wakes, or you toggle it.

When the wanted connection comes up, a fallback that autoconnect started is
disconnected again: two tunnels to the same place is one routing table with an
argument in it. Only what autoconnect itself started, and never a `protected`
one.
`connecting` is left alone because it is already on its way, and `unknown` is
left alone because asking an unreadable connection to connect is how a probe
nobody configured turns into a login prompt every ten seconds. All of it is in
[ADR 0013](adr/0013-autoconnect-is-a-plan-not-a-timer.md).

A `fallback` must name a connection that exists in the same file — vpnbar
refuses the config otherwise, because a dead end at the moment it is needed is
worse than having no fallback at all. A connection cannot fall back to itself,
and a `protected` connection may autoconnect — bringing one up is the direction
its protection allows, and a tunnel that must stay up is exactly the one worth
starting on its own.

### `probe`

| Field | Required | Meaning |
| --- | --- | --- |
| `cidr` | yes | An IPv4 block only this VPN hands out. A bare address means `/32`; `0.0.0.0/0` means any address on a matching interface. |
| `interface` | no | An interface-name prefix, normally `utun`. Without it every interface is considered. |

A probe reads `ifconfig` once per refresh and matches an address against the
block. It costs nothing, touches nothing on screen, and therefore wins over
whatever the backend would have answered —
[ADR 0003](adr/0003-a-probe-beats-asking-the-app.md).

Find the range by connecting once and looking:

```bash
ifconfig | grep -B4 'inet 10\.'
```

Pick a block that is unique to that VPN. A probe matching a range your office
LAN also uses will report a tunnel that is not there.

## Settings that are not in the file

Set these in `~/.hammerspoon/init.lua` before `:start()`:

```lua
local vpnbar = hs.loadSpoon("VpnBar")
vpnbar.interval = 10                                    -- seconds between state polls
vpnbar.configPath = os.getenv("HOME") .. "/.config/vpnbar/profiles.json"
vpnbar.panelReads = true                                -- allow on-demand panel reads
vpnbar:start()
```

`panelReads = false` switches off panel reading entirely: a `globalprotect`
connection then shows `unknown` unless it has a probe, and clicking still
works.
