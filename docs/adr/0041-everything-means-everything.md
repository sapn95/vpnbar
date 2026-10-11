# 0041 — Everything means everything

**Status:** accepted, 2026-10-11. Supersedes
[ADR 0020](0020-disconnect-everything-leaves-the-protected-ones-alone.md).

## The decision

**Disconnect everything** takes down every connection that is up, protected
ones included, and then autoconnect stands down until somebody chooses **VPNs
are off. Turn them back on**, which is the first row of the menu for as long as
that is true.

## Why ADR 0020 was wrong for this machine

It left protected connections alone and greyed the row out when nothing else
was up, on the reasoning that the reason was a setting two submenus away. On a
machine where both VPNs are protected, which is the machine this is used on,
that meant the row was greyed out every single time it was wanted. And it is
wanted for something ordinary: reaching the local network, a printer, a NAS,
the router's own page, none of which answer through a tunnel. The way round it
was to unprotect each connection by hand, disconnect it, and remember to
protect it again, which is three clicks per VPN and a protection nobody can
trust to be on.

Protection is against a stray click on a connection's own row, and every one
of those still refuses a protected connection. This row is different in kind:
it is a confirmed request, and the confirmation names every connection it will
close and says which of them are protected.

## Why autoconnect has to stand down

Both connections here are protected *and* set to connect automatically, so the
pass after they went down would bring them back, and the request would last
about ten seconds. While paused the planner does nothing at all: it starts
nothing, and it takes nothing down either, so a connection somebody brings up
by hand meanwhile stays up.

The pause ends with **Turn them back on**, which also clears the quit holds and
the failure records, so the planner starts from nothing and brings the
connections up in the order of the menu; or with a **Switch to**, because "this
one, now" outranks "everything off"; or with a restart of vpnbar, like every
other decision made for this session.

## How a protected connection is let through

A verb of its own, `standdown`, which only this row produces, the same way
`supersede` is a disconnect only the one-at-a-time rule produces
([ADR 0026](0026-one-at-a-time-outranks-protection.md)). Every other way to a
protected connection's disconnect stays refused, so protection still means what
the connection's own row says. It takes the harder path where the config has
one, which on the AWS client is the helper's `force`.

## What is not proven

The GlobalProtect half of it, against a live tunnel. Its panel offers a
**Disconnect** button (read from the panel on 2026-10-11 without pressing it),
and that is what is pressed. Whether the agent then reconnects by itself is a
matter of its own configuration, which this menu cannot see.

## What was rejected

- **A second row, "Disconnect everything, protected included".** Two rows that
  differ by a clause are one row that has to be read twice.
- **Quitting both clients instead.** It works, and it ends both sessions, so the
  way back is two logins rather than a click.
- **Keeping the pause across a restart.** A pause that outlived the session
  would be VPNs that never came back after a reboot, for a decision about a
  printer.
