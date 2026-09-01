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

-- A shield as five points: flat shoulders, straight flanks, a blunt point.
-- Curves were tried and are mud at eighteen points; so were rounded shoulders.
local SHIELD = {
  { x = 0.14, y = 0.11 },
  { x = 0.86, y = 0.11 },
  { x = 0.86, y = 0.50 },
  { x = 0.50, y = 0.91 },
  { x = 0.14, y = 0.50 },
}

-- The tick is cut *out* of the filled shield rather than drawn on top of it.
-- On a template image the cut is transparent, so it takes the colour of the
-- menu bar behind it and stays legible whichever way macOS tints the mark —
-- which a second colour on top would not.
local TICK = {
  { x = 0.32, y = 0.42 },
  { x = 0.45, y = 0.56 },
  { x = 0.70, y = 0.28 },
}

--- The shield outline, scaled to `size`.
--- @param size number
--- @return table list of { x, y }
function icon.shield(size)
  local points = {}
  for index, point in ipairs(SHIELD) do
    points[index] = { x = point.x * size, y = point.y * size }
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
    strokeWidth = size / 9,
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
    strokeWidth = size / 7,
    strokeCapStyle = "round",
    strokeJoinStyle = "round",
    compositeRule = "clear",
  }
end

local function dot(size, colour)
  return {
    type = "circle",
    center = { x = size * 0.5, y = size * 0.42 },
    radius = size * 0.15,
    action = "fill",
    fillColor = colour,
  }
end

--- Everything to draw for one state.
---
--- - connected: the shield is filled, with a tick cut out of it. Filled alone
---   is a blob at this size; the cut-out gives it something to be.
--- - connecting: the outline, with the middle filling in. Halfway, visibly.
--- - disconnected: the outline alone.
--- - unknown: the outline, faint. Not knowing is not the same as being down,
---   and the icon should not claim otherwise.
---
--- @param state string|nil one of the four states, anything else is unknown
--- @param size number|nil defaults to icon.SIZE
--- @return table list of hs.canvas element descriptors
function icon.elements(state, size)
  size = size or icon.SIZE
  if state == "connected" then
    return { shieldElement(size, "fill", INK), tickElement(size) }
  elseif state == "connecting" then
    return { shieldElement(size, "stroke", INK), dot(size, INK) }
  elseif state == "disconnected" then
    return { shieldElement(size, "stroke", INK) }
  end
  return { shieldElement(size, "stroke", FAINT) }
end

return icon
