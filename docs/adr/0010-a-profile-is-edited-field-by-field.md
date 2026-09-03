# 0010 — A profile is edited field by field, never as JSON

**Status:** accepted, 2026-09-01.

## The problem

The first Edit put the whole profile into `hs.dialog.textPrompt` as JSON. That
control is a **one-line** text field: the object was three lines longer than the
box, so most of what was being edited was off-screen, and a stray character in
the part you could not see came back as a parse error with no way to find it.

The Add flow had a quieter version of the same fault. It chose the backend with

```lua
hs.dialog.blockAlert(message, informative, "scutil", "GlobalProtect", "Shell")
```

`blockAlert` takes **two** buttons and reads the next argument as a *style*. The
third option was never a button; it was silently a style string, and the shell
backend could not be chosen at all.

## The decision

`vpnbar/form.lua` holds the fields as data — one ordered list per backend, each
entry saying what to ask, where the answer goes, and whether it may be empty.
The adapter walks that list and asks one question at a time, prefilled with the
current value when editing and with the field's own default when adding. Add
and Edit run the same walk, so they cannot drift.

The backend is chosen from a **submenu**, one entry per backend, each carrying
its one-line explanation as a tooltip. A submenu has no button limit and puts
the explanation next to the thing it explains.

`form.build` reassembles the answers, keeps what the form does not ask about
(`id`, `order`, `hidden`, `protected`), drops the fields belonging to a backend
that is no longer selected, and validates before anything is written.

## What was rejected

- **A multi-line dialog.** Hammerspoon has no multi-line text prompt, and a
  WebView holding a form is a lot of surface for editing five strings.
- **Opening the file in an editor.** That still exists, one item below, and is
  the right answer for a bulk edit. It is a poor answer for changing one
  hostname.
- **Leaving Edit to re-run Add.** It loses `order`, `hidden` and `protected`, and
  every one of those is a setting somebody chose.
