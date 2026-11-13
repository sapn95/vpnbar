# 0048 — An agent that stays loaded

**Status:** accepted, 2026-11-13. Corrects the commands of
[ADR 0033](0033-stopping-an-agent-that-launchd-restarts.md), whose decision
stands. Adds `load` beside the restart of
[ADR 0034](0034-a-protected-connection-keeps-its-repair.md) as something
protection allows.

## What happened

**Restart GlobalProtect** reported success and left the machine without the
agent. From `log show` and the GlobalProtect logs of 2026-11-13:

| time | what |
| --- | --- |
| 13:46 | boot. From here on GlobalProtect runs and has no menu-bar item |
| 22:20:26.5 | `launchctl bootout`, logged as `initiated by: launchctl<-bash<-Hammerspoon` |
| 22:20:27.6 | `launchctl bootstrap`, one second later |
| 22:20:28.6 | the old agent exits on its SIGTERM, and launchd logs `removing service: com.paloaltonetworks.gp.pangpa` |
| 22:20:48 | `/usr/bin/open -a GlobalProtect` starts a copy beside launchd |
| 22:26:59 | the tunnel is up, after Bartender was quit and opened again |

Three faults, and the first two are in one command.

**The bootstrap did not wait.** `bootout` returns at once. The agent unloads
its network extension configuration before it exits, which took two seconds,
and launchd removes the service only then. The command slept one second, so
`bootstrap` hit a service that was still being taken down and loaded nothing.

**The check asked the wrong party.** The command ended with `pgrep -x
GlobalProtect`. It matched the old agent on its way out and said the restart
had worked. `launchctl print gui/<uid>/com.paloaltonetworks.gp.pangpa` answered
`Could not find service`.

**GlobalProtect had no menu-bar item all day.** Its connect method is
on-demand, so it connects when Connect is pressed, and vpnbar presses Connect
through the item ([ADR 0001](0001-globalprotect-is-not-a-scutil-vpn.md)).
`AXExtrasMenuBar` was nil from the boot on, so every press answered
`GlobalProtect has no menu-bar item` and nothing connected. macOS allowed the
item (`isAllowed: true` in Control Center's tracked applications). Bartender 7
had it in its Hide list and no longer listed it. `launchctl kickstart -k` on
the agent did not bring it back. Quitting Bartender and opening it again did,
within 8 seconds, and vpnbar connected on its own after that. The same
happened on 2026-11-10, for eight minutes.

## The decision

**An unload is over when launchd says so.** After `bootout` the command asks
`launchctl print` every half second, for at most twenty-five seconds, until it
fails. That failure is launchd having removed the service. The bound is past
launchd's own: the GlobalProtect plist sets no `ExitTimeOut`, so launchd waits
its default twenty seconds before it kills an agent that will not exit. A
shorter wait would give up, skip the load, and leave launchd to remove the
service after the command had finished. Quit ends by
checking both: launchd has no such service, and no process of that name is
left.

**A restart loads only after that, and believes only launchd.** `bootstrap`
runs once the unload has been seen to finish. It is tried up to five times, a
second apart, because launchd answers error 5 or 37 while a removal is still
in flight. The restart has worked when `launchctl print` shows `state =
running` or a pid. `pgrep` is no longer asked. A load launchd refused is not
waited on: the wait for the service to run only runs while launchd has it.

**vpnbar never runs `open -a` on a launchd agent.** `backends.launchCommand`
is the one place that builds the command to start an application. For a
backend that names an `AGENT` it loads the service. `open -a` stays for a
plain application such as the AWS client.

**A copy beside launchd is stopped before the agent is loaded.** Where launchd
has no such service and a process of that name runs, that process was started
with `open`. It gets a TERM, five seconds, and then a KILL, but only once
launchd can load the agent: the plist has to be there, and `launchctl
print-disabled` must not name the service as disabled. Otherwise that copy is
the only client there is. A Quit stops the copy either way, because a quit is
about the copy and not about what comes after it. Every signal sits
behind `launchctl print` failing, so the agent itself is never signalled.
ADR 0033 rejected `pkill` because launchd restarts what it owns. Nothing
restarts this copy, so the signal sticks.

**The planner loads an agent that launchd has lost.** Each refresh asks
`launchctl print` once per agent. If launchd has none, the planner returns
`load`, logged as `autoconnect: load <id> (agent not loaded)` or `(running
beside launchd)`. It does so only:

- for a connection it would bring up: marked to autoconnect, or switched to.
- with no quit hold on the client. For GlobalProtect the quit is the unload,
  so without this line the planner would undo every Quit ten seconds later
  ([ADR 0031](0031-autoconnect-does-not-undo-a-quit.md)).
- for an agent seen loaded since Hammerspoon started, or with a copy of the
  client running beside launchd. The quit hold lives only as long as
  Hammerspoon does, so an agent quit before a reload has not been seen since
  and stays down. The agent lost on 2026-11-13 had been loaded all afternoon.
- while autoconnect is not paused
  ([ADR 0041](0041-everything-means-everything.md)).
- when a copy beside launchd carries nothing. Stopping it is a disconnect and
  costs a login, so it is replaced once every connection through that client
  reads down. A state nobody could read counts as up.
- on a backoff of its own: one minute, two, four, eight, then every fifteen
  ([ADR 0024](0024-autoconnect-backs-off-it-does-not-give-up.md)). It is kept
  under the agent's own key, so a load that keeps failing does not slow the
  connect, and it is cleared once launchd has the agent back.

**A load is not held while nobody is there.**
[ADR 0042](0042-nothing-happens-while-nobody-is-there.md) holds two things on
an unattended machine: a press into a window, and anything that takes a tunnel
down. A load is a command, it runs the same on a locked screen, and the rule
above keeps it from taking a tunnel down. So the agent is back before somebody
sits down, and the first press after the unlock has something to press.

**A swallowed item is fixed by restarting the menu-bar manager, once.** When
an agent has run for 60 seconds without its item and a known manager is
running, vpnbar asks the manager to quit by bundle id, waits up to thirty
seconds for its process to go, and opens it again with `open -b`. The restart
runs as a task beside Hammerspoon, so that wait holds nothing up. The process
is followed by its pid: the name Hammerspoon reports is the localised
application name, which need not be the name of the executable. One restart
per occurrence, and at most one in ten minutes per manager: an item a restart
did not bring back is missing for another reason, and restarting the manager
again would not change that. The list of managers is data in
`vpnbar/statusitem.lua` and has one row, Bartender
(`com.surteesstudios.Bartender`).

If no known manager is running, or the restart did not bring the item back
after another 60 seconds, a notification says so once. When the item returns,
the backoff of that client's connections is cleared, because the presses made
meanwhile had nothing to press.

None of this runs while nobody is there, and the time away is not counted.
No press is made on a locked screen, so the item can wait, and it cannot be
read there either. The grace starts again from the first look after the
return.

## What it costs

A restart now takes as long as the agent needs to go, which was two seconds
that evening, where it used to take a fixed two. In the worst case, with an
agent that never exits, Quit blocks Hammerspoon for the twenty-five seconds of
the bound before it reports the failure, and a restart can block about half a
minute. These commands still run inside one blocking call.

Restarting the manager redraws the whole menu bar in front of whoever is
looking at it. The quit is an Apple event sent by Hammerspoon, so macOS may ask
once whether Hammerspoon may control Bartender. That has not been measured: by
hand the quit was sent from a terminal.

Somebody who runs `launchctl bootout` on the agent in a terminal gets it
loaded back within ten seconds, if the connection is marked to autoconnect.
**Quit GlobalProtect** in the menu is the way to stop it and have it stay
stopped.

## What was not found

Nothing in vpnbar runs `open -a GlobalProtect`. `windowOf()` in `init.lua` is
the only place that opens a client, and only the `awsvpn` backend reaches it.
So the copy of 22:20:48 was started by something else. Once it was running it
was the only GlobalProtect on the machine, with no `KeepAlive`, and the Quit
and Restart of this menu did not reach it. The rules above deal with that
state whoever causes it.

## What was rejected

- **A longer fixed sleep.** Three seconds would have been enough that evening.
  The agent's exit depends on what it has to unload, and a fixed wait is too
  short on the day it takes longer and wasted on every other day.
- **`launchctl kickstart -k` on the agent to get the item back.** It did not
  bring it back, and stopping the agent logs the session out
  ([ADR 0033](0033-stopping-an-agent-that-launchd-restarts.md)).
- **Loading the agent of every configured connection.** A connection nobody
  marked to autoconnect is one the planner starts nothing for, and a client it
  does not start is not its to keep running.
- **Measuring how long the agent has run.** The decision says "has run for 60
  seconds without its item". What is measured is how long the item has been
  seen missing while launchd says the agent runs, which is never longer.
  `launchctl print` gives no start time, and a second command per refresh to
  get one would buy nothing.
- **Telling Bartender to show the item.** Its `show` returns without an error
  and moves nothing
  ([ADR 0016](0016-the-menu-bar-item-has-a-name.md), addendum).
- **Killing the manager's process.** Asking it to quit by bundle id is what
  was done by hand when it worked. A signal is a second method that nobody
  has tried.
