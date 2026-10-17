# 0011 — The menu-bar mark is a template image, and its state is the fill

**Status:** accepted, 2026-09-01.

## The decision

The menu bar shows a drawn mark rather than a text glyph. It is rendered from
`vpnbar/icon.lua` through `hs.canvas` and set with `image:template(true)`. The
shape is a padlock since 2026-10-17, and was a shield before that
([ADR 0045](0045-the-mark-is-a-padlock.md)):

| State | Mark |
| --- | --- |
| connected | shackle shut, body filled, keyhole **cut out** of it |
| connecting | shackle shut, body an outline with the middle filling in |
| disconnected | shackle **open** |
| unknown | the whole lock faint, and shut |

The four images are drawn once and cached. The count sits beside the icon as
text only when more than one tunnel is up, because one is the normal case and
the icon already says so.

## Why a template image, and why the state is never a colour

macOS tints a template image itself: dark on a light menu bar, light on a dark
one, and inverted again while the menu is open. A mark that carried its own
colour would be right in one of those three and wrong in the other two, and
the third is the one you are looking at while you click.

So the state is in the **shape and the fill**, which survive every tint. Solid
against outline is one contrast that reads at eighteen points on a moving
background; an open shackle against a shut one is a second, and it is the
stronger of the two, which is why the state somebody most needs to notice is
the one that breaks the outline of the lock. For the same reason the keyhole is
cut out of the body rather than drawn on top of it: drawn on top it would be
the same ink as the body and therefore invisible.

## Why the geometry is a module of its own

`icon.lua` returns element descriptors and draws nothing, so the shape is
under test: that every part stays inside its box at any size, that the body is
centred and the shackle's feet land on it, that the open shackle really does
leave its end in the air, that the stroke scales with the icon rather than
staying a hairline, that no element carries a colour, and that only the
connected state cuts anything out. `hs.canvas` then renders exactly what was
asserted.

## What was rejected

- **A text glyph** (`●`, `◐`, `○`). It works, it is what the first version did,
  and it still exists as the fallback when a canvas cannot be created. But its
  weight is the font's, not ours, and it sits differently in the bar from every
  other icon there.
- **An emoji.** Not tintable, not template-able, and a different picture on
  every macOS release.
