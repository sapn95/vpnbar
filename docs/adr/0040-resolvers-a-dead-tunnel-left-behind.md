# 0040 — Resolvers a dead tunnel left behind

**Status:** accepted, 2026-10-05. The other half of
[ADR 0035](0035-a-dead-tunnels-routes-are-swept-up.md), which swept up the
routes and left the resolvers where they were.

## The fault

A VPN installs its own resolvers while it is up. Measured on this machine:

    State:/Network/Service/gpd.pan/DNS
      ServerAddresses : 198.51.100.29, 198.51.100.30
      SearchDomains   : example.com, example.net

Those servers answer through the tunnel and nowhere else. When the tunnel dies
without the client tidying up, the entry stays: every internal name stops
resolving, and every lookup that reaches them waits for a timeout. Public names
still work, so the machine looks online and finds nothing it is actually for.

## How a dead one is told from a live one

By asking the resolvers. Nothing in the configuration says which tunnel they
belong to: `State:/Network/Service/gpd.pan/IPv4` records `InterfaceName: en0`
and an address on the local network, not the tunnel, so there is no interface
to check the way there is for a route. Whether they answer is the question that
matters anyway, and `nc -z` with a one second timeout asks it directly.

## What is touched, and what never is

Only a service whose name is not a UUID. macOS numbers its own network services
that way; a name in that position was put there by something that installed
itself. Removing a real service's resolvers would take the machine off the
network it is still on, and that is not a mistake worth risking for a
convenience.

Both keys go, `State:` and `Setup:`, because the client wrote both and leaving
one puts them back.

## Why it is in the command line rather than in the Spoon

Same reason as the route table: it needs root, so it asks, and the one place
that already asks is `vpnbar clean`. The doctor reports it with the routes, and
the two faults have the same cause and the same moment.

## What was rejected

- **Flushing the whole resolver configuration.** `dscacheutil -flushcache` and
  a `mDNSResponder` restart clear a cache, not a configuration. The entry would
  still be there afterwards.
- **Removing the entry whenever the tunnel interface is down.** There is no
  link from the entry to an interface, so this would have been a guess dressed
  as a rule.
- **Probing with a real DNS query.** A resolver that is gone does not answer
  either way, and a query needs a name, a type and a timeout of its own. The
  port either accepts a connection or it does not.
