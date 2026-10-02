# 0035 — A dead tunnel's routes are swept up

**Status:** accepted, 2026-10-02. Finishes what
[ADR 0033](0033-stopping-an-agent-that-launchd-restarts.md) started: that one
gave `vpnbar clean` to a person who already knew what had gone wrong.

## The decision

Every refresh, when `ifconfig` says a tunnel is down, vpnbar reads the route
table. Routes that point at a tunnel which is down, and have for a minute, are
offered up in one dialog that says what they are and what will happen. Accepting
runs `vpnbar clean --yes` through `with administrator privileges`, which is one
macOS password dialog and nothing left behind.

## Why it cannot be done without asking

Deleting a route needs root, and there are three ways to have it. A `sudoers`
entry pointing at a helper in the Homebrew prefix is a root hole, because that
prefix is writable by the person Homebrew installed for, and anything that can
write that file gets root. A helper in a root-owned directory plus a `sudoers`
entry is sound and leaves standing privilege behind, out of step with the rest
of a menu bar tool. A `LaunchDaemon` polling the route table is the same
standing privilege with a process attached.

`with administrator privileges` asks macOS to ask, once, for this one command.
No helper, no `sudoers` entry, no daemon, nothing to uninstall. The cost is that
it cannot heal while nobody is there, which is the right trade for a machine
whose network is already down.

## Why restarting the client is not the repair

It was the first design, and it was free: no root at all, using the `launchctl`
stop that [ADR 0033](0033-stopping-an-agent-that-launchd-restarts.md) had just
proved. A clean teardown does remove the routes — measured, all thirty-three of
them within a second.

Measured again in the state this is for, with the tunnel already dead and the
system extension not answering: thirty-three routes before the restart,
thirty-three after. The client cannot tear down what it has lost track of. So
the no-root repair is the one that does not work, and that is why the dialog
asks for a password.

## What is swept up, and what is not

A route qualifies when its interface matches `utun<n>` and that interface is
either absent or not UP. Both halves carry weight. An address outlives the
tunnel it belonged to ([ADR 0022](0022-a-probe-reads-the-interface-not-just-the-address.md)),
so the address proves nothing and the flag decides; and an interface that is not
a tunnel is never touched, because a route table is the one place where a wrong
delete is indistinguishable from the cable being pulled out. The default route
on a physical interface, which is the route still working while all this is
happening, is not a candidate under any reading.

## Why the route table is read every time

The first version asked `ifconfig` first and read the route table only when it
showed a tunnel that was down, which is free because the probes have read
`ifconfig` already. It also could not see the worst case: a tunnel that is not
in `ifconfig` at all, destroyed with its routes still installed. A guard that
asks about interfaces cannot find routes belonging to an interface that is
gone. Both families of the route table cost 30 ms, against a refresh that
already runs several commands, so the guard bought nothing worth that blind
spot.

## Why it waits a minute, and takes no for an answer

A tunnel coming up is briefly not up yet with its routes already installed.
Sweeping those away would break the connection this exists to repair, so the
condition has to hold for a minute before anything is said. **Not now** means a
quarter of an hour, and a condition that clears forgets both clocks, so the next
occurrence is a fresh question rather than the tail of an old one.

## What this does not fix

The reason the tunnel died. On the machine this was written for that is a
network extension stuck at `[activated waiting for user]`, which no command in
userland restarts; `vpnbar doctor` says so and names the one click in System
Settings that fixes it. Sweeping the routes gives the machine its network back
in the meantime, which is the difference between a working afternoon and a
reboot.

## What was rejected

- **A root helper and a `sudoers` entry.** Standing privilege for a menu bar
  tool, and the obvious install location is a writable prefix, which makes it a
  root escalation rather than a convenience.
- **A `LaunchDaemon` sweeping on a timer.** Same privilege, plus a process that
  deletes routes with nobody watching. The failure it guards against has
  happened twice.
- **Sweeping without asking, on the privileges already held.** There are none
  that can do it, so this is not an option, only a wish.
- **A notification rather than a dialog.** It is a question with a password in
  it. A banner that disappears is not where that is asked.
