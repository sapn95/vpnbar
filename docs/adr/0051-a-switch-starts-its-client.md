# 0051 — A switch starts its client

**Status:** accepted, 2026-11-22. Amends
[ADR 0030](0030-a-switch-is-a-preference-not-an-order.md) and
[ADR 0031](0031-autoconnect-does-not-undo-a-quit.md): a switch, and a Connect
from the menu, start the client the connection goes through when it is not
running.

## What happened

On 22.11.2026 he switched from GlobalProtect to the AWS connection while the AWS
VPN Client was not running. The console shows the whole of it:

```text
10:18:15  switch: aws is preferred until restart
10:18:15  AWS VPN (sbb): AWS VPN Client is not running
```

Then nothing. The switch pressed Connect once, and that press had no window to
press in. For the next ten minutes the switch went on asking for the AWS
connection, but the planner only presses a client that is running (ADR 0031),
so it asked for nothing, and GlobalProtect stayed up as if the click had not
happened. The same holds the other way round for a GlobalProtect agent that is
not running.

## The decision

**Somebody who asks for a connection by name asks for its client to run.** A
switch, and a Connect from the menu, check first whether the client is running.
When it is not, vpnbar starts it and waits for it, for up to thirty seconds,
and only then goes on: the menu's Connect presses Connect, and the switch hands
over to the planner, which presses for it the way it presses for any switch
and takes the other connection down once this one is up.

The client is started with the command vpnbar already uses wherever it opens
one: `open -a` for a plain application, and loading the launchd agent for one
that is an agent, never `open`, which would start a copy beside launchd
([ADR 0048](0048-an-agent-that-stays-loaded.md)). It runs as a task, so the
menu bar does not wait for launchd. A client that cannot be started, or does
not come up in thirty seconds, is said once. **Disconnect everything** while a client
is still coming up ends the request, so nothing is connected after it. The
check whether the client runs comes before the switch looks at the state it
last read, which can still say connected for a client that has quit since.

Autoconnect is unchanged. A client that is not running is still one it leaves
alone (ADR 0031); only a click on a connection's own row or its Switch starts
one.

## What it costs

Starting the AWS VPN Client brings its window up, and a fresh GlobalProtect
agent may ask for a login. Both are what the click asked for.
