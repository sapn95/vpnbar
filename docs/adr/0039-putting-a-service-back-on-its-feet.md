# 0039 — Putting a service back on its feet

**Status:** accepted, 2026-10-04.

## The decision

A connection whose backend names a launchd service gets one more row:
**Restart the service behind `<app>`**. It is confirmed, it is offered on a
protected connection, and where the service is a daemon it asks macOS for an
administrator.

## The fault it repairs

The agent asks for a connection and its own service never hears. Measured on
this machine twice: `PanGPA` logs the click at 12:02:08 and `PanGPS` logs
nothing after 11:51, and the client sits there reporting that it is trying.
Quitting and restarting the agent changes nothing, because the agent was never
the broken half. Nothing in the menu reached the service, so the only repair
left was a reboot.

`launchctl kickstart -k <domain>/<label>` is the repair, and both clients have
one:

| Client | Service | Domain | Administrator |
| --- | --- | --- | --- |
| GlobalProtect | `com.paloaltonetworks.gp.pangps` | `gui/<uid>` | no |
| AWS VPN Client | `com.amazonaws.acvc.osx.core` | `system` | yes |

Both were run against the live clients before this was written. The
GlobalProtect one brought a wedged agent back without a reboot, and the AWS one
restarted its daemon, which the client noticed and recovered from in a second.

## Why the domain matters more than it looks

`PanGPS` runs as root, which reads like a daemon and is not: its plist is in
`/Library/LaunchAgents` and it is registered in the person's own `gui` domain,
so restarting it needs nothing. `system/com.paloaltonetworks.gp.pangps` answers
`Could not find service`, which is what sent the first attempt looking for a
daemon that does not exist. The AWS one is a real `LaunchDaemon` with
`KeepAlive` set, so it is in `system` and it does need an administrator. The
difference is invisible in `ps`, so the backend carries it.

## Why a protected connection may still do it

For the reason a restart may
([ADR 0034](0034-a-protected-connection-keeps-its-repair.md)): the line is
where the action leaves things. This one ends with the service running. It does
take the connection down on the way, which the confirmation says before
anything happens.

## What was rejected

- **Doing it automatically when a connect is held up.** It drops the tunnel,
  and a handshake that is merely slow is not a broken service. The planner
  already stops a stuck connect from blocking the stand-in
  ([ADR 0036](0036-a-connect-that-never-arrives.md)); this is for a person who
  has looked and knows.
- **Restarting the service instead of the agent, everywhere.** Closing the
  agent is cheaper and fixes the cases where the agent is the broken half.
  Both rows are there, in that order.
- **A `sudoers` entry so the AWS one needs no prompt.** Standing root for a
  repair asked for by hand, and the same escalation risk the route cleanup
  turned down ([ADR 0035](0035-a-dead-tunnels-routes-are-swept-up.md)).
