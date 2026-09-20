# 0030 — A switch is a preference, not an order

**Status:** accepted, 2026-09-20.

## The decision

The first row of the menu is **Switch to** followed by a connection's name,
one row for the other connection or a submenu when there are several. It makes
that connection *preferred* for this session and connects it. Preferred means
it ranks first for autoconnect: with *Only one connection at a time* on, the
planner takes the other tunnel down once this one is connected, not while it is
still on its way ([ADR 0026](0026-one-at-a-time-outranks-protection.md),
addendum), and keeps this one up from then on.

The preference lives in the adapter (`self.preferred`), travels to the planner
in its `context`, and is forgotten when vpnbar restarts. The config is not
touched. The row reads **Switch back to …** while a preference stands and the
target is the connection that ranks first by order.

## Why not Move up

Move up changes the config, and the config is the lasting answer to "which one
do I want". The case for the switch is the other kind of answer: the connection
you want is crawling *this afternoon*, and you want to be on the other one
until it is not. Changing the order for that, and changing it back later, is
two edits to a file for a problem that has nothing to do with the file.

## Why not a plain Connect

Clicking the other connection connects it, and then the planner, with
*Only one connection at a time* on, takes it straight down again: it is
outranked by the one you chose, which is up. So the second tunnel lasted one
refresh. The switch is the same click plus the one thing that was missing, a
reason for the planner to side with the new one.

## Why the connect is made by the click, not the planner

Setting the preference and waiting for the planner would work in most cases,
and not in the one that matters: a connection whose session has ended is held
back from connecting while somebody is at the keyboard
([ADR 0029](0029-an-attempt-that-needs-a-person-waits-for-one.md)), and the
person at the keyboard is the one who just clicked. So the click connects
directly, the way the connection's own row does. It is recorded as an attempt,
so the planner does not press Connect a second time while the first is still
on its way, and the planner is asked for a pass six seconds later so the other
tunnel comes down without waiting for the timer.

A preferred connection is wanted whether or not it is marked to autoconnect.
The switch is that mark, for the session; requiring the flag as well would make
the row do nothing for exactly the stand-in most people have not flagged.

## What happens when the preferred one fails

Nothing new. It ranks first, so it is asked for on its own backoff, and while it
waits the connection it displaced gets its turn as a wanted connection of its
own; the two alternate exactly as a wanted connection and its fallback do
([ADR 0026](0026-one-at-a-time-outranks-protection.md)). Its failures are
forgotten when the switch is made, so a backoff earned while it was the stand-in
does not make the switch wait.

## What was rejected

- **Persisting the preference.** Then there would be two orders, one in the
  file and one somewhere else, and Move up would stop meaning what it says.
- **Offering hidden connections.** Hidden keeps a connection out of the top
  level; the first row of the top level is the top level.
- **Taking the current one down from the click.** That is the planner's rule
  under its own verb, and it depends on the setting. With *Only one connection
  at a time* off the switch brings the other one up and says in its tooltip
  that the current one stays.
