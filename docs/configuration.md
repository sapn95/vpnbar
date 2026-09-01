# Configuration

Everything vpnbar knows lives in one file:

```text
~/.config/vpnbar/profiles.json
```

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
