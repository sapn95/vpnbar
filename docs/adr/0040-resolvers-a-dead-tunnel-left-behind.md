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

By asking the resolvers a question. Nothing in the configuration says which
tunnel they belong to: `State:/Network/Service/gpd.pan/IPv4` records
`InterfaceName: en0` and an address on the local network, not the tunnel, so
there is no interface to check the way there is for a route. Whether they
answer is the question that matters anyway.

A real query, bounded to one second and one try, rather than an open port. A
port scan says only that something accepted a TCP connection: a resolver that
listens and answers nothing passes it, and a working resolver that takes
queries on UDP alone fails it. Authorising a removal on either of those is
authorising it on the wrong evidence. Where `dig` is missing, nothing is
reported.

## What is touched, and what never is

A service has to be named in `VPN_DNS_SERVICES` and not be a UUID. Two
conditions, because the second one alone is not an identification: macOS
numbers its own network services that way, so "not a UUID" says only that
something installed itself, which is true of a great many things that are not
this VPN. Removing some other program's resolvers because they happened not to
answer is a fault of its own, and removing a real service's would take the
machine off the network it is still on.

So the list is an enumeration of the services this tool drives, and a name that
is not on it is left alone however dead it looks.

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
- **Probing the port instead of the service.** It was the first version. A
  resolver that listens and answers nothing passes a port scan, and one that
  serves UDP alone fails it, so both of its answers can be wrong in the
  direction that deletes a working configuration.
