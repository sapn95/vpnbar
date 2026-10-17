# 0045 — The mark is a padlock

**Status:** accepted, 2026-10-17. Replaces the shape chosen in
[ADR 0011](0011-the-menu-bar-mark-is-a-template-image.md), whose reasoning about
template images and colour it leaves standing.

## Why the shield had to go

Not taste. A shield can only say what it is doing with its **fill**, and the
fill is one bit of information: solid or hollow. Everything the menu has to
report had to be squeezed into that one bit plus a dot, so connected and
connecting differed by a dot in the middle, and disconnected and unknown
differed by an alpha value. At sixteen points, on a bar that is moving under a
window being dragged, two of those four are a guess.

A padlock has a second place to put the state, and it is a better one: the
shackle. Open against shut is a different *shape*, not a different amount of
ink, and the outline of the mark itself breaks. That is the one state somebody
needs to catch out of the corner of an eye, so that is the one that gets it.

## The mark

| State | Mark |
| --- | --- |
| connected | shackle shut, body filled, keyhole cut out of it |
| connecting | shackle shut, body an outline with the middle filling in |
| disconnected | shackle **open** |
| unknown | the whole lock faint, and shut |

Unknown keeps the shackle shut on purpose. Not knowing is not the same as being
down, and an open shackle is the loudest thing this mark can say.

## The geometry

A rounded rectangle sitting on the bottom of the box, with the top two fifths
left to an arc. The arc's centre is on the body's top edge, so its feet land on
the body and the two shapes meet rather than overlap. Shut is the half circle
from 270° to 90°; open stops at 45° instead, which leaves the far end in the
air above the body.

Those numbers were measured, not reasoned about, and the obvious reading was
the wrong one. `hs.canvas` puts 0° at the top and counts clockwise, so 270 is
the left foot, 0 is the top of the arc and 90 is the right foot. Written as 180
to 360, which is what a y-grows-downwards reading gives, the arc came out as a
hook curling down into the body in all four states. A sheet of six angle pairs
rendered to a file settled it in one step, and that is the cheaper move than a
second guess whenever a drawing API's convention is in question.

The keyhole is cut out of the filled body rather than drawn on it, for the
reason ADR 0011 gives: on a template image the cut is transparent and takes the
colour of the bar behind it, and a second mark drawn on top would be the same
ink as the body and therefore invisible.

## What was rejected

- **A tunnel with something going through it.** More literal, and the thing
  going through is a detail inside a bore that is already only nine points
  wide. The state would have been back in the fill.
- **Keeping the shield and putting a keyhole in it.** The smallest change and
  it fixes nothing: the state is still only the fill.
- **Colour for the state.** Still out, for the reason it was always out: macOS
  tints a template image three ways and a colour is right in one of them.
- **A second glyph for login against disconnected.** Down is down. Which of the
  two it is belongs in the menu row, not in a shape nobody can read at sixteen
  pixels.
