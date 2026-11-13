# 0049 — A tunnel you named keeps its routes

**Status:** accepted, 2026-11-13. Amends
[ADR 0043](0043-the-private-space-belongs-to-the-network-you-are-on.md): a
tunnel that carries a connection's `reach` is not counted as claiming the
private space.

## What happened

With GlobalProtect healthy, `vpnbar doctor` failed:

    FAIL  3 route(s) send the private address space into a live tunnel — run: vpnbar clean

The three routes were GlobalProtect's own `10`, `172.16/12` and `192.168.0/16`
on its tunnel. The `reach` address of its probe, a work server, was behind the
`10` and nothing narrower. Following the advice would have deleted the route
that address leaves by.

GlobalProtect installs its routes once, when the tunnel is created
([ADR 0047](0047-a-tunnel-that-carries-nothing.md)). After the delete it would
have stayed connected and carried nothing until a reconnect, which is the
fault ADR 0047 renews a tunnel for. ADR 0043 was written about an AWS session
that took the whole private space as a side effect. Here the same three routes
are what the tunnel is for.

## The decision

A tunnel that carries an address named as a connection's `reach` keeps its
aggregates. `vpnbar clean` leaves them, and `vpnbar doctor` does not report
them. Which tunnel that is comes from the kernel: `route -n get <reach>` names
the interface the address leaves by right now.

Everything else in ADR 0043 stands. A tunnel nobody named a `reach` for is
still counted, and so is a second tunnel that holds aggregates while the named
one carries the address.

The config is read with `grep` for the `reach` key, which only ever sits
inside a probe. The CLI runs where no JSON parser can be assumed.

## What was rejected

- **Leaving out only the aggregate that covers the `reach`.** It keeps `10`
  and still offers to delete `172.16/12` and `192.168.0/16`, which the same
  client pushed in the same configuration. The doctor would go on failing on a
  healthy machine.
- **Leaving out every protected connection's tunnel.** Protection says a
  connection may not be taken down from the menu. It says nothing about which
  routes belong to it, and the AWS connection is protected too.
