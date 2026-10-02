# 0033 — Stopping an agent that launchd restarts

**Status:** accepted, 2026-10-02. Reverses the central claim of
[ADR 0021](0021-restarting-the-agent-is-not-a-disconnect.md) and narrows
[ADR 0028](0028-quit-and-restart-are-per-application.md).

## What happened

A GlobalProtect that would not reconnect, could not be stopped, and left a
route table pointing at a tunnel that was not carrying anything. Every address
the VPN had claimed went to a dead interface, so the machine looked connected
and reached none of it. A reboot was the only thing that cleared it.

Three separate faults, measured afterwards on the machine it happened on.

## Why it could not be stopped

`/Library/LaunchAgents/com.paloaltonetworks.gp.pangpa.plist` has `KeepAlive`
set to true. Every kill is a race against launchd, and launchd wins within
seconds. What vpnbar sent was `pkill`, twice, and then asked whether the
process was gone; by then it was back, so the Quit reported a failure after
doing exactly what it said.

`launchctl bootout gui/<uid>/<label>` unloads the service instead, so there is
nothing left to start it again, and in the person's own GUI domain it needs no
root. Measured: the agent stays stopped, and `launchctl bootstrap gui/<uid>
<plist>` brings it back under launchd rather than beside it, which is what
`open -a` would have done.

## Why stopping it is a disconnect

This repository has said since its first week that closing GlobalProtect closes
a user interface, because the tunnel belongs to the root service behind it.
Measured, finally, by stopping the agent on a live connection:

    09:32:35  the agent is booted out
    09:32:37  Tunnel is down due to disconnection
    09:32:39  User was logged out of Gateway

The agent logs out of the gateway on its way out. The service keeps running and
holds nothing, and the next connect wants a login rather than a handshake. So
every Quit and every Restart of this client has been ending the session, while
the dialog promised it would not, and `appOwnsTunnel` is now true for this
backend as it already was for the AWS one.

The cost of being honest about it: a `protected` connection no longer offers
Quit or Restart on GlobalProtect, because a protected connection refuses
anything that takes its tunnel down and this takes its tunnel down. ADR 0021
argued the opposite from the belief that the repair could not reach the tunnel.
The belief was wrong, so the conclusion goes with it. The repair is still there
for a connection that is not protected, and `launchctl` is still there for
somebody who means it.

## Why the route table has to be cleaned separately

When the client dies badly its routes outlive the interface they point at.
A normal disconnect tears them down, and on the day this was written GlobalProtect
removed all 33 of them cleanly within a second. The failure case does not: the
log showed `failed to send ipc data: system ext not connected`, after which
`SendKeepAlive() failed` and `send(120) failed: 65(No route to host)`, with the
routes still installed.

`vpnbar clean` removes exactly those: a route whose interface is a `utun` that
is not UP. Both halves of that are load-bearing. An address outlives the tunnel
it belonged to ([ADR 0022](0022-a-probe-reads-the-interface-not-just-the-address.md)),
so the address proves nothing and the UP flag does; and an interface that is
not a tunnel is never touched, because a route table is the one place where a
wrong delete is indistinguishable from the cable being pulled out. It prints
what it will do, asks before doing it, and `--dry-run` prints the `route`
commands without running any.

## Why a reboot was the only repair

    GlobalProtectExtension  [activated waiting for user]

The network extension is activated and **not enabled**: it is running, and it
has never been approved in System Settings. Nothing in userland restarts an
extension in that state, so once its IPC to the service drops, the tunnel
cannot be rebuilt and the routes it installed stay where they are. That is the
whole of "only a reboot helped".

`vpnbar doctor` now says so, because it is a one-click fix that nobody finds by
guessing: System Settings → General → Login Items & Extensions → Network
Extensions.

## What was rejected

- **Keeping `pkill` with `bootout` as a fallback.** The kill is the thing that
  does not stick. Two mechanisms where the first is known to lose is one
  mechanism and a decoration.
- **`SIGKILL` to keep the session.** A kill that gives the agent no chance to
  log out might well leave the session alive, which would make Restart cheap
  again. It is a guess until it is measured, and the measurement costs a login
  every time it is wrong.
- **Restarting the root service from the menu.** `launchctl kickstart -k
  system/com.paloaltonetworks.gp.pangpsd` needs root, and with the extension
  unapproved it is a reliable way to reach the state that only a reboot clears.
  The doctor says to approve the extension first.
- **`route -n flush`.** It takes the default route with it, which is the one
  route that was still working.
