--- The menu-bar mark, as geometry.
---
--- A padlock. It replaced a shield on 2026-10-17, and the reason is the state
--- rather than the taste: a shield can only say what it is doing with its
--- *fill*, and filled against outlined is one bit of information drawn at
--- sixteen points on a moving background. A padlock says it with its shackle,
--- which is a different shape rather than a different amount of ink, and shape
--- is what survives that size
--- ([ADR 0045](../../docs/adr/0045-the-mark-is-a-padlock.md)).
---
--- The state is never in the colour. A menu-bar icon is a template image, so
--- macOS tints it: white on a dark bar, black on a light one, and inverted
--- again while the menu is open. Anything that relied on colour would be
--- legible in one of those three and wrong in the other two.
---
--- Nothing here draws. It returns `hs.canvas` element descriptors and the
--- adapter renders them, which is why the shape can be asserted in a test.

local icon = {}

icon.SIZE = 16

local INK = { white = 0, alpha = 1 }
local FAINT = { white = 0, alpha = 0.45 }

-- The body, as a fraction of the box: a rounded rectangle sitting on the
-- bottom, with the top two fifths left to the shackle.
local BODY = { x = 0.19, y = 0.42, w = 0.62, h = 0.42, radius = 0.09 }

-- The shackle, as an arc over the body. Its centre is the body's top edge, so
-- its feet land on the body and the two shapes meet rather than overlap.
--
-- Degrees, and `hs.canvas` puts 0 at the top and counts clockwise. Measured,
-- because the obvious reading is the wrong one: 270 is the left foot, 0 is the
-- top of the arc, and 90 is the right foot. Stopping at 45 instead leaves the
-- far end in the air above the body, which is what open looks like.
local SHACKLE = { x = 0.5, y = 0.42, radius = 0.20, from = 270, closed = 90, open = 45 }

-- The keyhole, cut out of the filled body: a round socket and the slot under
-- it. Cut rather than drawn, because on a template image the cut is
-- transparent and takes the colour of the bar behind it, which stays legible
-- whichever way macOS tints the mark.
local KEYHOLE = {
  socket = { x = 0.5, y = 0.57, radius = 0.075 },
  slot = { { x = 0.5, y = 0.61 }, { x = 0.5, y = 0.72 } },
}

--- The body, scaled to `size`.
--- @param size number
--- @return table { x, y, w, h, radius }
function icon.body(size)
  return {
    x = BODY.x * size,
    y = BODY.y * size,
    w = BODY.w * size,
    h = BODY.h * size,
    radius = BODY.radius * size,
  }
end

--- The shackle, scaled to `size`, closed unless `open`.
--- @param size number
--- @param open boolean|nil
--- @return table { x, y, radius, startAngle, endAngle }
function icon.shackle(size, open)
  return {
    x = SHACKLE.x * size,
    y = SHACKLE.y * size,
    radius = SHACKLE.radius * size,
    startAngle = SHACKLE.from,
    endAngle = open and SHACKLE.open or SHACKLE.closed,
  }
end

--- The keyhole, scaled to `size`.
---
--- Exported for the same reason the rest is: the menu bar draws it as a hole
--- cut out of a template, and a dialog wants the same shape in a colour
--- ([ADR 0037](../../docs/adr/0037-a-dialog-that-looks-like-vpnbar.md)).
--- @param size number
--- @return table { socket = { x, y, radius }, slot = { { x, y }, { x, y } } }
function icon.keyhole(size)
  local slot = {}
  for index, point in ipairs(KEYHOLE.slot) do
    slot[index] = { x = point.x * size, y = point.y * size }
  end
  return {
    socket = {
      x = KEYHOLE.socket.x * size,
      y = KEYHOLE.socket.y * size,
      radius = KEYHOLE.socket.radius * size,
    },
    slot = slot,
  }
end

local function bodyElement(size, action, colour)
  local body = icon.body(size)
  return {
    type = "rectangle",
    frame = { x = body.x, y = body.y, w = body.w, h = body.h },
    roundedRectRadii = { xRadius = body.radius, yRadius = body.radius },
    action = action,
    fillColor = colour,
    strokeColor = colour,
    strokeWidth = size / 11,
  }
end

local function shackleElement(size, colour, open)
  local shackle = icon.shackle(size, open)
  return {
    type = "arc",
    center = { x = shackle.x, y = shackle.y },
    radius = shackle.radius,
    startAngle = shackle.startAngle,
    endAngle = shackle.endAngle,
    arcRadii = false,
    action = "stroke",
    strokeColor = colour,
    strokeWidth = size / 9,
    strokeCapStyle = "round",
  }
end

--- The keyhole's two elements, cut out of whatever is under them.
--- @param size number
--- @return table, table socket, slot
function icon.keyholeElements(size)
  local keyhole = icon.keyhole(size)
  local socket = {
    type = "circle",
    center = { x = keyhole.socket.x, y = keyhole.socket.y },
    radius = keyhole.socket.radius,
    action = "fill",
    fillColor = INK,
    compositeRule = "clear",
  }
  local slot = {
    type = "segments",
    closed = false,
    coordinates = keyhole.slot,
    action = "stroke",
    strokeColor = INK,
    strokeWidth = size / 11,
    strokeCapStyle = "round",
    compositeRule = "clear",
  }
  return socket, slot
end

-- While something is running the dot breathes: out and back over four frames,
-- which reads as work in progress. Two frames alternating reads as a fault
-- light, and a mark that does not move at all is what this answers -- a
-- permanently connected tunnel meant the icon looked identical whether the
-- Spoon was mid-read, mid-click or idle. The first frame is the resting radius,
-- so a caller that never advances the phase gets the mark unchanged.
local PULSE = { 0.055, 0.085, 0.055, 0.03 }

--- How many frames the busy mark has.
icon.PHASES = #PULSE

--- Which frame of the pulse a phase number means. Any integer works, so the
--- adapter can keep counting up and never has to wrap.
--- @param phase number|nil
--- @return number 1..icon.PHASES
function icon.frame(phase)
  local index = math.floor(tonumber(phase) or 1)
  return ((index - 1) % icon.PHASES) + 1
end

local function dot(size, colour, fraction)
  return {
    type = "circle",
    center = { x = size * 0.5, y = size * 0.63 },
    radius = size * fraction,
    action = "fill",
    fillColor = colour,
  }
end

--- Everything to draw for one state.
---
--- - connected: the shackle is shut and the body is filled, with the keyhole
---   cut out of it. Filled alone is a blob at this size; the cut gives it
---   something to be.
--- - connecting: the shackle is shut and the body is an outline with the middle
---   filling in. Halfway, visibly, and the dot breathes as `phase` advances.
--- - disconnected: the shackle is open. The one state somebody reads across the
---   room, and the only one where the outline of the lock is broken.
--- - unknown: the whole lock faint, and shut. Not knowing is not the same as
---   being down, and an open shackle would claim it was.
---
--- @param state string|nil one of the five states, anything else is unknown
--- @param size number|nil defaults to icon.SIZE
--- @param phase number|nil which frame of the busy pulse, ignored by the rest
--- @return table list of hs.canvas element descriptors
function icon.elements(state, size, phase)
  size = size or icon.SIZE
  if state == "connected" then
    local socket, slot = icon.keyholeElements(size)
    return { bodyElement(size, "fill", INK), shackleElement(size, INK, false), socket, slot }
  elseif state == "connecting" then
    return {
      bodyElement(size, "stroke", INK),
      shackleElement(size, INK, false),
      dot(size, INK, PULSE[icon.frame(phase)]),
    }
  elseif state == "disconnected" or state == "login" then
    -- Down is down; which of the two it is belongs in the menu row, not in a
    -- glyph nobody can read at sixteen pixels.
    return { bodyElement(size, "stroke", INK), shackleElement(size, INK, true) }
  end
  return { bodyElement(size, "stroke", FAINT), shackleElement(size, FAINT, false) }
end

return icon
