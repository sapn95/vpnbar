# 0043 — The private space belongs to the network you are on

**Status:** accepted, 2026-10-16. Adds a second route rule beside
[ADR 0035](0035-a-dead-tunnels-routes-are-swept-up.md), which sweeps up after a
tunnel that died. This one is about a tunnel that is alive.

## What was measured

An AWS VPN session came up and put this in the table:

    Destination        Gateway       Flags   Netif
    10                 198.51.100.1  UGSc    utun6
    172.16/12          198.51.100.1  UGSc    utun6
    192.168.0/16       198.51.100.1  UGSc    utun6

Three routes covering the whole of RFC 1918. Nothing in the table looks broken,
and the usual checks all pass: the default route is still the LAN's, DNS
answers, `curl https://www.google.com` returns 200. The machine's own subnet
survives as well, because macOS keeps the interface's `/24` and a `/24` beats a
`/8`.

Everything else private is gone:

    route -n get 192.168.1.50
       route to: 192.168.1.50
    destination: 192.168.0.0
        gateway: 198.51.100.1
      interface: utun6

A printer, a Pi at home, a host one subnet over. They answer nothing for as
long as the VPN is up, and there is no error anywhere saying so.

## The decision

`vpnbar clean` gained a second route rule, and `vpnbar doctor` reports it. A
route is a claim on the private space when both of these hold:

- its destination is one of the three aggregates, and
- its interface is a tunnel that is **up**.

The aggregates are enumerated rather than matched by pattern:

    10  10/8  10.0.0.0/8
    172.16/12  172.16.0.0/12
    192.168/16  192.168.0/16  192.168.0.0/16

Both spellings of each, because `netstat` compresses them and a person writing
one out does not. A rule like "starts with `10.`" would match a prefix the
tunnel is entitled to, in a list that ends in a `route delete`.

Nothing goes without being asked. The list is printed first, `--dry-run` shows
the exact commands, and the deletes are counted again afterwards so a route the
`route` command refused is reported as kept rather than claimed as gone.

## Why `10.0.0.0/8` is in it

Because the alternative is a rule that fixes two thirds of the fault. It has a
cost and the cost is real: an internal prefix inside `10/8` that the tunnel does
not also cover with a narrower route goes with the aggregate, and so does a
resolver living at such an address. The tunnel keeps every route of its own that
is more specific.

That trade was taken deliberately. A tunnel that wants to carry a prefix can say
which prefix; one that asks for all of private space is asking for the network
the machine is standing on.

## Why it is separate from the stale-route rule

They look alike in the output and they are not the same question. A route to an
interface that is down helps nobody, so removing it needs no judgement. A route
into a live tunnel is a client doing exactly what it was configured to do, and
removing it decides which of two networks matters more right now. One rule, one
question each, and an aggregate on a tunnel that is down belongs to the first
one so the same delete is never offered twice.

## IPv4 only

The equivalent in IPv6 is the unique local range. No tunnel on this machine has
been measured claiming it, so nothing here pretends to know what that looks
like in a route table.

## Keeping the resolvers, added 2026-10-17

The first version of this deleted the aggregates and nothing else, and the cost
named above arrived within a second of the first real run. The aggregate came
off, and so did the path to every resolver inside it:

    dig www.google.com
    ;; connection timed out; no servers could be reached

`curl` still returned 200, because the system resolver had the answer cached.
Nothing in the output said anything was wrong. Four host routes added by hand
brought the resolvers back.

So `clean` does that itself now. Before it deletes anything, it asks the kernel
where each configured resolver is going, and any resolver reaching its tunnel
through one of the aggregates about to be removed gets a host route to that
tunnel's gateway first. A host route is more specific than the aggregate and the
two coexist, so there is no moment in which no name resolves.

Three things are asked of the kernel rather than worked out from the table,
because the kernel's answer already accounts for every more specific route:

- a resolver on the LAN reports a physical interface, and is left alone,
- a resolver the tunnel covers with a narrow prefix of its own reports that
  prefix rather than an aggregate, and is left alone,
- a resolver behind a second tunnel reports that tunnel, and is pinned to *its*
  gateway rather than to the first one in the list.

A network address on its own does not identify a route, so the mask is part of
the comparison. A tunnel carrying both `10/8` and a `10.0.0.0/24` answers
`destination: 10.0.0.0` for either, and the narrower one is the route that would
have kept the resolver; their masks differ, and `route -n get` prints it.

The gateway is deliberately not part of it. Measured on this machine, the
command prints a `gateway:` line for a route that has one and leaves it out for
an interface route, and a tunnel client that installs its aggregate in that
second form is common. A comparison that needed a gateway returned nothing for
those addresses and skipped the resolver in silence, which is this rule's own
fault reached from the other side. The host route for such a resolver is added
with `-interface` rather than a gateway, the same distinction
`route_delete_args` already makes and for the same reason.

A pin that fails stops the whole thing. If the `route` command refuses a host
route, nothing is deleted at all: that resolver's only route is the aggregate,
and fixing the local network is not worth taking DNS down to do it. The local
network stays broken, which is the lesser of the two faults, and the report
names how many resolvers stopped it.

Afterwards each pinned resolver is asked a real question with `dig`, one at a
time. A host route that exists and a resolver that answers are two different
claims, and the second is the one somebody notices. One at a time because the
reachability helper is satisfied by any one server answering, which is the
right question for "is this service still there" and the wrong one here: a
resolver that went silent would be hidden by a neighbour that did not. Every
one that fails is named, and `clean` fails with the command to put it back.

The spellings in `CLAIMED_AGGREGATES` and the networks in `aggregate_network`
are two lists, so a spelling added to one and not the other would quietly stop
pinning resolvers. A test asserts every spelling has a network.

## What was rejected

- **Deleting only `172.16/12` and `192.168.0/16`.** The safe two. It leaves
  every local subnet in `10/8` pointing down the tunnel, which on this machine
  is where the local network actually is.
- **Writing a more specific route back onto the physical interface instead.**
  macOS already does that for the subnet the interface is on, which is why the
  fault is invisible, and it cannot be done for a subnet the machine has no
  address in.
- **Doing it on its own, as part of a refresh.** The route table is the one
  place on a machine where a wrong delete and pulling the cable out look the
  same. `vpnbar clean` is a command somebody runs.
- **Keeping `10.0.0.0/8` after all, once the cost was measured.** The host
  routes are the narrower fix: they keep the resolvers and leave the rest of
  private space local, which is what the aggregate was in the way of.
- **Pinning every configured resolver.** Most of them are not behind the
  aggregate. A host route for a resolver already reachable is noise in the
  table, and one for a resolver on the LAN would send it into a tunnel.
