--- The menu-bar mark, as geometry.
---
--- A shield, because that is what a tunnel looks like to the person glancing
--- at it, and because a filled shape against an outline of the same shape is
--- the one contrast that survives at eighteen points on a moving background.
--- The state is in the *fill*, never in the colour: a menu-bar icon is a
--- template image, so macOS tints it — white on a dark bar, black on a light
--- one, and inverted again while the menu is open. Anything that relied on
--- colour would be legible in one of those three and wrong in the other two.
---
--- Nothing here draws. It returns `hs.canvas` element descriptors and the
--- adapter renders them, which is why the shape can be asserted in a test.

local icon = {}

icon.SIZE = 16

local INK = { white = 0, alpha = 1 }
local FAINT = { white = 0, alpha = 0.45 }

-- A shield: square shoulders, flanks that curve in, and a rounded point. The
-- curves are the whole difference between a shield and a baseball home plate,
-- which is what the straight-flanked version read as at the size it is
-- actually drawn. `c1`/`c2` are the Bézier controls for the curve *into* that
-- point, in the same unit square as the rest.
local SHIELD = {
  { x = 0.19, y = 0.13 },
  { x = 0.81, y = 0.13 },
  { x = 0.81, y = 0.44 },
  { x = 0.50, y = 0.89, c1x = 0.81, c1y = 0.67, c2x = 0.66, c2y = 0.79 },
  { x = 0.19, y = 0.44, c1x = 0.34, c1y = 0.79, c2x = 0.19, c2y = 0.67 },
}

-- The tick is cut *out* of the filled shield rather than drawn on top of it.
-- On a template image the cut is transparent, so it takes the colour of the
-- menu bar behind it and stays legible whichever way macOS tints the mark --
-- which a second colour on top would not.
local TICK = {
  { x = 0.34, y = 0.44 },
  { x = 0.45, y = 0.56 },
  { x = 0.68, y = 0.30 },
}

--- The shield outline, scaled to `size`.
--- @param size number
--- @return table list of { x, y }
function icon.shield(size)
  local points = {}
  for index, point in ipairs(SHIELD) do
    local scaled = { x = point.x * size, y = point.y * size }
    if point.c1x then
      scaled.c1x, scaled.c1y = point.c1x * size, point.c1y * size
      scaled.c2x, scaled.c2y = point.c2x * size, point.c2y * size
    end
    points[index] = scaled
  end
  return points
end

local function shieldElement(size, action, colour)
  return {
    type = "segments",
    closed = true,
    coordinates = icon.shield(size),
    action = action,
    fillColor = colour,
    strokeColor = colour,
    strokeWidth = size / 11,
    strokeJoinStyle = "round",
  }
end

local function tickElement(size)
  local points = {}
  for index, point in ipairs(TICK) do
    points[index] = { x = point.x * size, y = point.y * size }
  end
  return {
    type = "segments",
    closed = false,
    coordinates = points,
    action = "stroke",
    strokeColor = INK,
    strokeWidth = size / 8,
    strokeCapStyle = "round",
    strokeJoinStyle = "round",
    compositeRule = "clear",
  }
end

-- While something is running the dot breathes: out and back over four frames,
-- which reads as work in progress. Two frames alternating reads as a fault
-- light, and a mark that does not move at all is what this answers — a
-- permanently connected tunnel meant the icon looked identical whether the
-- Spoon was mid-read, mid-click or idle. The first frame is the resting radius,
-- so a caller that never advances the phase gets the mark unchanged.
local PULSE = { 0.13, 0.19, 0.13, 0.07 }

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
    center = { x = size * 0.5, y = size * 0.44 },
    radius = size * fraction,
    action = "fill",
    fillColor = colour,
  }
end

--- Everything to draw for one state.
---
--- - connected: the shield is filled, with a tick cut out of it. Filled alone
---   is a blob at this size; the cut-out gives it something to be.
--- - connecting: the outline, with the middle filling in. Halfway, visibly, and
---   the dot breathes as `phase` advances.
--- - disconnected: the outline alone.
--- - unknown: the outline, faint. Not knowing is not the same as being down,
---   and the icon should not claim otherwise.
---
--- @param state string|nil one of the four states, anything else is unknown
--- @param size number|nil defaults to icon.SIZE
--- @param phase number|nil which frame of the busy pulse, ignored by the rest
--- @return table list of hs.canvas element descriptors
function icon.elements(state, size, phase)
  size = size or icon.SIZE
  if state == "connected" then
    return { shieldElement(size, "fill", INK), tickElement(size) }
  elseif state == "connecting" then
    return { shieldElement(size, "stroke", INK), dot(size, INK, PULSE[icon.frame(phase)]) }
  elseif state == "disconnected" then
    return { shieldElement(size, "stroke", INK) }
  end
  return { shieldElement(size, "stroke", FAINT) }
end

return icon
