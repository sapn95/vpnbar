# 0026 — One at a time outranks protection

**Status:** accepted, 2026-09-16. Replaces
[ADR 0015](0015-one-at-a-time-is-a-setting-not-a-rule.md) and narrows
[ADR 0008](0008-an-always-on-vpn-is-protected-from-being-disconnected.md).

## The decision

With **Only one connection at a time** switched on, the connection ranked
highest stays up and every other tunnel is taken down. Every other one: whoever
opened it, and whether or not it is `protected`.

Rank is the order in the menu, which **Move up** and **Move down** change.

The closing is asked for under its own verb, `supersede`. `protected` goes on
refusing `disconnect` and `force`, so every button in the menu is refused
exactly as before.

`ATTEMPTS_BEFORE_FALLBACK` drops from 2 to 1.

## Why protection is not the last word here

[ADR 0008](0008-an-always-on-vpn-is-protected-from-being-disconnected.md) is
about a person, or a menu acting for one, breaking a policy by clicking
something. That reasoning does not reach this case. Here the machine is already
on a tunnel that ranks higher, and what `protected` would preserve is a **second**
tunnel nobody asked to keep. Two tunnels is not twice the connectivity; it is one
routing table with an argument in it.

The owner of this machine asked for it directly, having been shown that it
reverses the rule: *even with protected, only one at a time*.

## Why a separate verb rather than relaxing the check

If `protected` simply stopped refusing `disconnect`, then every route that ever
reaches `backends.act` with `disconnect` would be allowed — **Disconnect
everything**, **Force disconnect**, the row itself. The protection would have
been removed rather than narrowed.

`supersede` is a disconnect that only the one-at-a-time rule can ask for. No menu
item produces it, and a test walks the whole built menu to prove that. So the
sentence "this connection can never be disconnected from the menu" is still true
word for word, and the new behaviour is the one exception, named, in one place.

## Why the fallback comes after one failure

A second identical attempt a minute later tells you nothing the first did not,
and the point of having a fallback is to be on *something* while the preferred
connection is unavailable. After that the two alternate, each on its own backoff
([ADR 0024](0024-autoconnect-backs-off-it-does-not-give-up.md)), for as long as
both keep failing — which is what "keep testing back and forth until one works
again" means.

## Why the order had to become visible

It already decided this and said nothing. `store.list` sorts by `order`, and
`autoconnect.plan` acts on the first candidate it finds, so Move up and Move down
have always chosen which connection is asked for first. From the menu it looked
like nothing but a sort. **Move up** now reads `Move up (1 of 2)` and both rows
say what the order decides. A setting that reads as decoration is a setting
nobody will use on purpose.

## Why only a higher rank may block a start

The first version of this blocked a connection from starting while **any** other
tunnel was up. That turned the fallback into a one-way door: once the stand-in
was up, the connection somebody actually chose could never be tried again, and
the machine stayed on its second choice for as long as that kept working. Found
in the wild the next day, with the preferred VPN down and nothing trying it.

A lower-ranked tunnel that is up is not a reason to stay off the higher-ranked
one. It is exactly what the supersede rule takes down once the higher one
arrives. So a start is blocked only by something ranked above it, and the cycle
closes:

```text
preferred down, stand-in up   ->  connect the preferred one
both up                       ->  supersede the stand-in
preferred up, stand-in down   ->  nothing left to do
```

## Why the wanted connection is never abandoned

The same door, one hinge further in. Past the fallback threshold the wanted
connection stopped being asked for at all and only the stand-in was considered,
so once the stand-in was up there was nothing left to plan and the preferred one
was gone for good. It is asked for whenever its own backoff allows, however many
times it has failed and whatever the stand-in is doing.

The stand-in gets its turn in the gaps, which is where alternating actually
comes from: with both failing, the sequence is the wanted one, the stand-in, the
wanted one, the stand-in, for as long as neither answers.

The test that was supposed to cover this asked only whether each name appeared
somewhere. Both did — the wanted one on the first pass and the stand-in ever
after. It now counts them.

## What was rejected

- **Leaving `protected` absolute and asking for a config change instead.** It
  would work — unprotect the stand-in and the old rule does the job. It also
  means the setting called "only one connection at a time" quietly does not mean
  that, which is the kind of thing that costs an evening to rediscover.
- **Letting the menu offer a supersede.** Then it is a button that closes an
  always-on VPN, which is what ADR 0008 exists to prevent and what nobody asked
  for.
- **Ranking by anything other than the menu order.** A separate priority field
  is a second thing to keep in step with a list that already has an order and
  already has controls for changing it.
- **Taking every extra down in one pass.** `plan` returns one action per refresh
  by design ([ADR 0013](0013-autoconnect-is-a-plan-not-a-timer.md)); the next
  refresh takes the next one. Ten seconds apart is not worth a second code path.
