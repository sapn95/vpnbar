# 0050 — A network at home stays at home

**Status:** accepted, 2026-11-19. Adds to
[ADR 0049](0049-a-tunnel-you-named-keeps-its-routes.md), which keeps a named
tunnel's aggregates, a way to keep chosen networks out of them.

## What happened

GlobalProtect was up and carried its `reach`, so its three aggregates stayed in
the table as ADR 0049 intends:

```text
192.168.0/16       10.0.0.1      UGSc    utun4
```

The machine's own `/24` kept working, because macOS keeps the interface's route
and a `/24` beats a `/16`. A second network at home, a VLAN behind the same
router with the Pis on it, did not. Every address in it left by the tunnel and
answered nothing. `vpnbar doctor` said `no live tunnel has claimed the private
address space`, which was true only in the sense that ADR 0049 had decided not
to count this claim.

A route for that one network through the home router, added by hand, fixed it.
It was more specific than the aggregate, so the tunnel kept everything else.

## The decision

**Networks somebody names are put back through the router of the network the
machine is on, whenever a tunnel holds them.**

```bash
vpnbar local add 192.168.0.0/24      # tie it to the router here
vpnbar local                         # what each one does right now
vpnbar local remove 192.168.0.0/24
```

`add` records the network with the router it belongs to: the current default
router and the MAC address that router answers with. Without a MAC it refuses:
on a strange network whose router has the same address, the route would send
traffic meant for the tunnel to that router.

The MAC is read as root. macOS shows a process that lacks the Local Network
permission `2:0:0:0:0:0` in place of every MAC, and a terminal usually lacks it.
The first `add` on 20.11.2026 recorded that placeholder; the helper, running as
root, saw the real MAC, decided the machine was not at home and took the route
away at once. Read as root, the MAC is the real one, the placeholder is refused
wherever it turns up, and `vpnbar local` and the doctor ask for the status
through the same sudoers line, as root. The MAC is what makes "on
this network" mean this network. Half the home routers there are sit at
`192.168.1.1`, and on somebody else's network the same prefix belongs to
somebody else.

A route needs root. One root-owned helper, `/usr/local/libexec/vpnbar-localroute`,
does the work, and one line in `/etc/sudoers.d/vpnbar` lets the user run exactly
`vpnbar-localroute apply` and `vpnbar-localroute status` without a password.
`status` changes nothing; it is how the doctor asks whether the line is in place
(`sudo -n -k … status`), because `sudo -l` says yes to an administrator who may
run anything with a password, and to anybody who typed one a minute ago. `vpnbar local add` installs both,
which is the one time a password is asked for. After that the Spoon runs
`sudo -n vpnbar-localroute apply` whenever the IPv4 route table changes, and
every five minutes besides, because the helper's answer also depends on which
router is answering on the link.

What the helper does, for each listed network:

- The machine is on that network when the router is on the link (reached with
  no gateway of its own, and not through a tunnel) and answers with the
  recorded MAC. A router whose ARP entry has lapsed is pinged once first.
- On that network, and the network's address leaves by a tunnel: add the route
  through the router.
- On that network, and a route for exactly that prefix goes elsewhere through
  a gateway (one a tunnel pushed, or one left from an earlier router): change
  it to the router. An interface route, the one macOS keeps for the network
  the machine is on, has no gateway and is left alone.
- Not on that network, and the route through that router is still in the table:
  take it away, so the prefix goes wherever this network sends it.
- Anything else is left alone. A network no tunnel claims needs nothing.

Every change is checked in the table afterwards rather than taken from the exit
code of `route`. One run at a time: a run takes a lock folder next to the list,
and `vpnbar local remove` and `uninstall` take the same one, so a run that read
the list before a network was removed cannot put its route back afterwards.
`remove` deletes the route before the line, and keeps the line if the route will
not go.

The helper does not trust whoever runs it. The list is a root-owned file,
`/usr/local/etc/vpnbar/local-networks`, which the helper refuses to act on if
anybody other than root could have written it or its folder. Every field is
checked before `route` sees it, and only networks inside RFC 1918 are
accepted, with no host bits set and no wider than the private block they sit
in. As root it sets its own `PATH` and reads nothing from the environment; the
first command it runs, `/usr/bin/id`, is named by its full path, because sudo
on macOS keeps the caller's `PATH`. Whoever can run it can only put back routes
root already agreed to.

Installing goes the same careful way. Nothing root installs passes through a
file the user owns: the list, the sudoers line and the helper are piped into a
root-owned file next to their target, checked there (`visudo` runs on the
staged sudoers line as root), and moved into place. Every folder above the
three paths has to be root's and not writable by anybody else, or nothing is
installed. A helper that is already installed and differs is only replaced
after the two SHA-256 sums have been shown and somebody has said yes.

The `VPNBAR_LOCAL_*` variables move the three paths for the tests. They are
not a way in: whoever can set the environment `vpnbar` runs in can as well put
a `sudo` of their own first on `PATH` and have the password typed into it.

The doctor reports a listed network that goes into a tunnel, a route left
behind on another network, and a helper or sudoers line that is missing or older
than the installed vpnbar. When a named tunnel holds the aggregates, it now
says so rather than that nothing claimed them, and names `vpnbar local add`.

## What it costs

A line in `/etc/sudoers.d` and a root-owned file in `/usr/local/libexec`. Both
are outside Homebrew, so `brew uninstall` leaves them; `vpnbar local uninstall`
takes them away along with the routes. A `brew upgrade` that changes the helper
leaves the installed copy behind until `vpnbar local apply` replaces it, which
the doctor asks for.

Between a tunnel coming up and the next refresh, a listed network goes into the
tunnel. Two runs are at least fifteen seconds apart, so that is up to half a
minute when the tunnel arrives right after a run.

An internal network of the employer's with the same prefix as one at home is
unreachable while the machine is at home. That is the choice the list makes.

## What was rejected

- **Deleting the aggregate.** It is the route the `reach` leaves by, and
  GlobalProtect does not install it again until it reconnects (ADR 0049).
- **Asking for the password each time.** Every reconnect and every change of
  Wi-Fi would end in a password dialog.
- **The list in `profiles.json`.** That file is the user's to write. A helper
  that took its networks from it would let anything running as the user add
  routes as root without a password.
- **Only telling.** The doctor already printed the command. The point was not
  to have to run it.
