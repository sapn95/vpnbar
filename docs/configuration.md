# Configuration

Everything vpnbar knows lives in one file:

```text
~/.config/vpnbar/profiles.json
```

**Connections → Add a connection ▸** picks a backend and then asks for one
field at a time; **Edit…** asks the same questions with the current answers
filled in. **Protect from disconnecting**, **Hide** and **Connect
automatically** are toggles in the same submenu. Only
the things below that no prompt covers need the file opening by hand.

It is written by the menu and it is safe to edit by hand — the menu re-reads it
every time it opens, and a file it cannot parse is refused with a notification
rather than replaced. Writes are atomic (a temporary file and a rename), so an
interrupted save cannot leave a half-written config behind.

## Settings

Two settings sit beside the profiles, because both are about the menu as a
whole. Toggle them from **Connections → Settings**.

```json
{
  "version": 1,
  "settings": { "exclusive": true, "fallback": true },
  "profiles": []
}
```

| Setting | Default | What it does |
| --- | --- | --- |
| `exclusive` | `false` | Only one tunnel at a time. The one ranked highest in the menu stays up; every other one is taken down, whoever opened it and whether or not it is `protected`. A connection still starts while something ranked *below* it is up — otherwise a fallback would be a one-way door. |
| `fallback` | `true` | Whether autoconnect may try a connection's `fallback` at all. Off, it keeps asking for the one you chose. |

`exclusive` outranks `protected`, which nothing else does
([ADR 0026](adr/0026-one-at-a-time-outranks-protection.md)). It is asked for
under a verb no menu item can produce, so every button still refuses a protected
connection. Switched off, the older narrower rule applies: only the stand-in
autoconnect started for this very connection, and never a protected one
([ADR 0015](adr/0015-one-at-a-time-is-a-setting-not-a-rule.md)). Changing
either setting clears autoconnect's memory of what has failed, because those
failures happened under the old rules.

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
| `eventLog` | no | The agent's event log, read to tell a lost tunnel from an ended session. Defaults to the path the agent writes to. |

Driven through the accessibility API, because the agent offers nothing else —
see [ADR 0001](adr/0001-globalprotect-is-not-a-scutil-vpn.md). Give it a
`probe`: without one its state is only read when you ask for it, since reading
it means opening the agent's panel on screen.

When the probe says the tunnel is down, the agent's event log
(`/Library/Logs/PaloAltoNetworks/GlobalProtect/pan_gp_event.log`, or the file
named in `eventLog`) is read to tell *down* from *down because the gateway ended
the session*. The second shows as `needs your login`, and autoconnect waits for
a person before opening the SAML window that connect would bring up
([ADR 0029](adr/0029-an-attempt-that-needs-a-person-waits-for-one.md)).

Because every read and every click goes through that panel, an agent that stops
answering leaves the connection with nothing to click. **Connections → the
connection → Quit `<app>`** and **Restart `<app>`** close it, and reopen it for
the restart: `SIGTERM`, a couple of seconds, `SIGKILL` if it is still there, then
`open -a`. Both are offered on a `protected` connection here, since the tunnel is
held by GlobalProtect's own root service rather than by the app being closed
([ADR 0021](adr/0021-restarting-the-agent-is-not-a-disconnect.md)).

For `awsvpn` the same two rows exist and mean something else, because that client
*is* the tunnel's parent: closing it ends the session. So there they are
withheld from a `protected` connection, exactly as **Force disconnect** is
([ADR 0028](adr/0028-quit-and-restart-are-per-application.md)).

**Quit every VPN app**, above **Connections**, closes all of them in one go —
one entry per application, so two connections through the same client are one
thing to quit.

### `backend: "awsvpn"`

| Field | Required | Meaning |
| --- | --- | --- |
| `app` | yes | The client's name. Defaults to `AWS VPN Client`. |
| `row` | yes | The profile, exactly as the client's window lists it — `work`, `work-full`. That row's own button is the one clicked. |
| `commands.status` | no | Something cheap that prints the state, so the menu never opens a window to read one. Give it the profile name as an argument to get an answer about *that* profile: `aws-vpn-client status work`. |
| `commands.force` | no | The harder way down. |

```json
{
  "id": "aws",
  "name": "AWS VPN (work)",
  "backend": "awsvpn",
  "app": "AWS VPN Client",
  "row": "work",
  "commands": {
    "status": "/opt/homebrew/bin/aws-vpn-client status work",
    "force": "/opt/homebrew/bin/aws-vpn-client force"
  }
}
```

The client lists several profiles. Connecting and disconnecting click the named
row, because there is no way to ask for a profile by name
([ADR 0009](adr/0009-the-aws-vpn-client-is-driven-through-openvpns-management-interface.md)).

The **state** used to have the same limitation and no longer does. Version 6 of
the client ships no OpenVPN and nothing listens on the management port, so the
helper reads the client's own log, which names the connected profile. Pass the
profile to `status` and the answer is about that one
([ADR 0027](adr/0027-the-aws-client-stopped-having-a-management-interface.md)).
Where nothing can be read at all the answer is `unknown`, not `disconnected`,
because those are different things and guessing the second one reported a live
tunnel as down. And a profile that is down and has *ever* needed a SAML login
reads as `login`: the client asks for one on every connect, so the next one
will open a browser tab, and autoconnect waits for a person before doing that
([ADR 0029](adr/0029-an-attempt-that-needs-a-person-waits-for-one.md)).

Connecting brings the client's window up if it is not showing: with no window
the client exposes no accessibility tree at all, and there is nothing to click.
The federated login is still finished by hand in the browser.

### `backend: "shell"`

| Field | Required | Meaning |
| --- | --- | --- |
| `commands.connect` | yes | Run by the shell when you click to connect. |
| `commands.disconnect` | yes | Run by the shell when you click to disconnect. |
| `commands.status` | no | Should print `connected`, `connecting`, `disconnected` or `login` — the last meaning the session has ended and a person has to sign in, which autoconnect then waits for. Without it the state is `unknown`, which is still clickable. |
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

**Disconnect everything** obeys it too: that row closes what is up and not
protected, and where everything up is protected it stays in the menu, greyed out,
naming the connection that is holding it
([ADR 0020](adr/0020-disconnect-everything-leaves-the-protected-ones-alone.md)).

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
never more often than once a minute. After a single failure it moves to its
`fallback` — if that one is not itself up or on its way up. One failed attempt
is enough, because a second identical one a minute later says nothing the first
did not ([ADR 0026](adr/0026-one-at-a-time-outranks-protection.md)).

It does not stop. The gap doubles with each failure, from one minute to a
ceiling of fifteen, and stays there
([ADR 0024](adr/0024-autoconnect-backs-off-it-does-not-give-up.md)). A session
the gateway has *ended* still needs a person and a browser, and no amount of
retrying substitutes for that; what comes back on its own is the commoner case,
a tunnel that dropped while the session is still good.

When the wanted connection comes up, a fallback that autoconnect started is
disconnected again: two tunnels to the same place is one routing table with an
argument in it. Only what autoconnect itself started, and never a `protected`
one.
`connecting` is left alone because it is already on its way, and `unknown` is
left alone because asking an unreadable connection to connect is how a probe
nobody configured turns into a login prompt every ten seconds. All of it is in
[ADR 0013](adr/0013-autoconnect-is-a-plan-not-a-timer.md).

A wake **or an unlock** is a fresh start: the record of what has failed is
dropped, because a portal that was unreachable behind a closed lid says nothing
about the network in front of an open one, and a screen that has been sitting
locked says the same. Waking a locked Mac fires both events, so the second one
inside twenty seconds is ignored rather than clearing the record twice
([ADR 0023](adr/0023-an-unlock-is-a-fresh-start.md)). The state is then read at two, six and fifteen seconds, and
only the last of the three may connect anything. Wi-Fi has not associated when
the wake event fires, and an attempt spent then buys a minute of cooldown for a
tunnel the machine could not possibly have built
([ADR 0018](adr/0018-nothing-waits-for-a-read.md)).

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

The interface has to be **up and running**, not merely present. An address
outlives the tunnel that was given it: GlobalProtect answers a keep-alive
timeout by pulling its routes, bringing the interface down and leaving the
address on it for the retry, so for as long as the agent keeps trying there is a
dead interface wearing the number of a live one. Matching on the address alone
read that as `connected` for four hours, and a connection that reads
`connected` is one autoconnect leaves alone
([ADR 0022](adr/0022-a-probe-reads-the-interface-not-just-the-address.md)).

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
