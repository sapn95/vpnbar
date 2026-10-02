# 0034 — A protected connection keeps its repair

**Status:** accepted, 2026-10-02. Narrows
[ADR 0033](0033-stopping-an-agent-that-launchd-restarts.md) the day it was
written.

## The decision

A `protected` connection refuses **Quit `<app>`** and allows **Restart
`<app>`**, for every backend, whether or not closing the client ends the
session.

The line is where the action leaves things. A quit ends with the connection
down and nothing on the machine planning to bring it back. A restart ends with
the client running, which is the only repair this menu has for a client that
has stopped answering. Protection is protection from being left disconnected,
not from a second of downtime on the way to being fixed.

## Why this is not a retreat from ADR 0033

That decision measured what stopping the GlobalProtect agent costs: the agent
logs out of the gateway, and the tunnel is down two seconds later. It was right
about the cost and went one step too far with it, taking Restart away along with
Quit. Applied to the machine it was written on, where both connections are
protected, the result was a menu with no repair in it at all, on the same day
its owner had been trying to restart one of those clients by hand.

A cost that is worth stating in a dialog is not the same as a cost that is worth
refusing. The dialog states it: this client is its own tunnel, the connection
goes down with it, and it comes back when the client has started again, which
may ask you to log in.

## What is still refused

Everything that leaves a protected connection down: **Disconnect**, **Force
disconnect**, **Disconnect everything**, **Quit `<app>`**, and **Quit every VPN
app**, which also skips the clients a protected connection is using. The
`supersede` verb that the one-at-a-time rule uses stays the single exception it
was ([ADR 0026](0026-one-at-a-time-outranks-protection.md)), and no menu item
produces it.

## What was rejected

- **Leaving the repair out and documenting `launchctl`.** The person who needs
  it is the person whose client has stopped answering, and a command line in an
  ADR is not a repair.
- **Asking twice for a protected restart.** The confirmation already names the
  client, says the connection goes down with it, and says a login may follow.
  A second dialog is not more information.
