# 0005 — CRUD is over the menu's list, not over the system's

**Status:** accepted, 2026-09-01.

## The question

"Add a connection" could mean two things: add a row to this menu, or create a
VPN configuration in macOS.

## The decision

It means the first. `~/.config/vpnbar/profiles.json` is the only thing created,
updated and deleted. **Remove** deletes a row and nothing else — no service is
torn down, no agent is uninstalled, no system setting is touched. The menu says
so in the confirmation.

## Why

- The connections that matter here are not the system's to begin with. The
  managed VPN services are pushed by device management and would come back;
  the GlobalProtect tunnel is not a system service at all
  ([ADR 0001](0001-globalprotect-is-not-a-scutil-vpn.md)).
- Creating or deleting a network service needs root and rewrites state shared
  with everything else on the machine. A menu-bar convenience that can do that
  by accident is a menu-bar convenience nobody should install.
- It makes **Remove** safe, and safe enough to not need an undo: the worst case
  is retyping a profile, or clicking **Import from scutil…** to get it back.

## What follows from it

- `Import from scutil…` reads `scutil --nc list` and adds what is missing. It
  never renames, never overwrites and never writes back to macOS.
- A profile is a *view* of a connection, so two profiles may point at the same
  service with different names, and hiding one hides the row rather than the
  connection.
- Uninstalling vpnbar leaves nothing behind but a JSON file.
