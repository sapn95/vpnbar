local icon = require("vpnbar.icon")

local STATES = { "connected", "connecting", "disconnected", "unknown" }

local function actions(elements)
  local out = {}
  for _, element in ipairs(elements) do
    out[#out + 1] = element.action
  end
  return out
end

--- Every point an element occupies, whichever way it describes itself: a
--- rectangle has a frame, an arc and a circle a centre and a radius, and the
--- rest a list of coordinates.
local function corners(element)
  local points = {}
  for _, point in ipairs(element.coordinates or {}) do
    points[#points + 1] = point
  end
  if element.frame then
    points[#points + 1] = { x = element.frame.x, y = element.frame.y }
    points[#points + 1] = { x = element.frame.x + element.frame.w, y = element.frame.y + element.frame.h }
  end
  if element.center and element.radius then
    points[#points + 1] = { x = element.center.x - element.radius, y = element.center.y - element.radius }
    points[#points + 1] = { x = element.center.x + element.radius, y = element.center.y + element.radius }
  end
  return points
end

describe("icon.body", function()
  it("scales to the size it is asked for", function()
    for _, size in ipairs({ 16, 18, 64 }) do
      local body = icon.body(size)
      assert.is_true(body.x >= 0)
      assert.is_true(body.y >= 0)
      assert.is_true(body.x + body.w <= size)
      assert.is_true(body.y + body.h <= size)
    end
  end)

  it("sits on the bottom and leaves the top to the shackle", function()
    local size = 100
    local body = icon.body(size)
    local shackle = icon.shackle(size, false)
    -- The feet of the arc land on the body's top edge, so the two shapes meet.
    assert.equals(body.y, shackle.y)
    assert.is_true(shackle.y - shackle.radius > 0)
  end)

  it("is centred left to right", function()
    local size = 64
    local body = icon.body(size)
    assert.is_true(math.abs((body.x + body.w / 2) - size / 2) < 0.001)
  end)
end)

describe("icon.shackle", function()
  it("scales with the size it is asked for", function()
    local small, large = icon.shackle(16, false), icon.shackle(32, false)
    assert.equals(small.x * 2, large.x)
    assert.equals(small.y * 2, large.y)
    assert.equals(small.radius * 2, large.radius)
  end)

  it("keeps its angles whatever the size", function()
    for _, size in ipairs({ 12, 16, 64 }) do
      assert.equals(icon.shackle(16, false).endAngle, icon.shackle(size, false).endAngle)
    end
  end)

  -- `hs.canvas` puts 0 at the top and counts clockwise, which was measured
  -- rather than assumed: 270 is the left foot, 0 the top, 90 the right foot.
  local function endsAt(shackle)
    local radians = math.rad(shackle.endAngle)
    return {
      x = shackle.x + shackle.radius * math.sin(radians),
      y = shackle.y - shackle.radius * math.cos(radians),
    }
  end

  it("starts at the left foot and comes back down to the right one when shut", function()
    local shut = icon.shackle(100, false)
    assert.equals(270, shut.startAngle)
    local foot = endsAt(shut)
    assert.is_true(math.abs(foot.y - shut.y) < 0.001, "the far foot is on the body")
    assert.is_true(foot.x > shut.x, "and it is the right one")
  end)

  it("stops short of the body when open, leaving the end in the air", function()
    -- The whole point of the shape: open is a broken outline, not less ink.
    local open = icon.shackle(100, true)
    local foot = endsAt(open)
    assert.is_true(foot.y < open.y, "the end is above the body")
    assert.is_true(foot.x > open.x, "on the side the shut one lands on")
  end)

  it("keeps both feet inside the body it stands on", function()
    local size = 100
    local body = icon.body(size)
    local shackle = icon.shackle(size, false)
    assert.is_true(shackle.x - shackle.radius > body.x)
    assert.is_true(shackle.x + shackle.radius < body.x + body.w)
  end)
end)

describe("icon.keyhole", function()
  it("scales with the size it is asked for", function()
    local small, large = icon.keyhole(16), icon.keyhole(32)
    assert.equals(small.socket.x * 2, large.socket.x)
    assert.equals(small.socket.radius * 2, large.socket.radius)
    assert.equals(#small.slot, #large.slot)
    for index, point in ipairs(small.slot) do
      assert.equals(point.x * 2, large.slot[index].x)
      assert.equals(point.y * 2, large.slot[index].y)
    end
  end)

  it("stays inside the body it is cut out of", function()
    local size = 100
    local body = icon.body(size)
    local keyhole = icon.keyhole(size)
    assert.is_true(keyhole.socket.y - keyhole.socket.radius > body.y)
    for _, point in ipairs(keyhole.slot) do
      assert.is_true(point.x > body.x and point.x < body.x + body.w, "x")
      assert.is_true(point.y > body.y and point.y < body.y + body.h, "y")
    end
  end)

  it("hangs its slot under the socket, on the centre line", function()
    local size = 64
    local keyhole = icon.keyhole(size)
    for _, point in ipairs(keyhole.slot) do
      assert.equals(size / 2, point.x)
      assert.is_true(point.y > keyhole.socket.y)
    end
  end)
end)

describe("icon.elements", function()
  it("draws something for every state", function()
    for _, state in ipairs(STATES) do
      assert.is_true(#icon.elements(state) > 0, state)
    end
  end)

  it("fills the body when connected and only outlines it when not", function()
    assert.equals("fill", icon.elements("connected")[1].action)
    assert.equals("stroke", icon.elements("connecting")[1].action)
    assert.equals("stroke", icon.elements("disconnected")[1].action)
    assert.equals("stroke", icon.elements("unknown")[1].action)
  end)

  it("shuts the shackle in every state but the one that is down", function()
    local shut = icon.shackle(icon.SIZE, false).endAngle
    local open = icon.shackle(icon.SIZE, true).endAngle
    assert.equals(shut, icon.elements("connected")[2].endAngle)
    assert.equals(shut, icon.elements("connecting")[2].endAngle)
    assert.equals(shut, icon.elements("unknown")[2].endAngle)
    assert.equals(open, icon.elements("disconnected")[2].endAngle)
    -- A login that has not happened is a tunnel that is down.
    assert.equals(open, icon.elements("login")[2].endAngle)
  end)

  it("says nothing about the shackle it cannot know", function()
    -- Not knowing is not the same as being down, and an open shackle is the
    -- loudest thing this mark can say.
    assert.not_equals(icon.elements("disconnected")[2].endAngle, icon.elements("unknown")[2].endAngle)
  end)

  it("cuts the keyhole out of the fill rather than drawing over it", function()
    -- Drawn on top, a second mark would be the same ink as the body and
    -- invisible. Cut out, it is the bar showing through, whichever way macOS
    -- tints the template.
    local socket = icon.elements("connected")[3]
    local slot = icon.elements("connected")[4]
    assert.equals("clear", socket.compositeRule)
    assert.equals("clear", slot.compositeRule)
    assert.equals("fill", socket.action)
    assert.equals("stroke", slot.action)
    assert.is_false(slot.closed)
  end)

  it("has nothing to cut out of an outline", function()
    for _, state in ipairs({ "connecting", "disconnected", "unknown" }) do
      for _, element in ipairs(icon.elements(state)) do
        assert.is_nil(element.compositeRule, state)
      end
    end
  end)

  it("shows the middle filling in while it works", function()
    local working = icon.elements("connecting")
    assert.same({ "stroke", "stroke", "fill" }, actions(working))
    local body = icon.body(icon.SIZE)
    local pulse = working[3]
    assert.is_true(pulse.center.y > body.y and pulse.center.y < body.y + body.h)
  end)

  it("breathes while it works, out and back", function()
    local radii = {}
    for phase = 1, icon.PHASES do
      radii[phase] = icon.elements("connecting", 100, phase)[3].radius
    end
    assert.is_true(radii[2] > radii[1])
    assert.is_true(radii[3] < radii[2])
    assert.is_true(radii[4] < radii[3])
    assert.equals(radii[1], icon.elements("connecting", 100, icon.PHASES + 1)[3].radius)
  end)

  it("rests where it always rested when nobody advances the phase", function()
    assert.equals(icon.elements("connecting", 100, 1)[3].radius, icon.elements("connecting", 100)[3].radius)
  end)

  it("takes any integer as a phase, so the adapter can just count up", function()
    for _, phase in ipairs({ -3, 0, 1, 5, 99 }) do
      assert.is_true(icon.frame(phase) >= 1)
      assert.is_true(icon.frame(phase) <= icon.PHASES)
    end
    assert.equals(icon.frame(1), icon.frame(1 + icon.PHASES))
  end)

  it("ignores the phase in every state that is not working", function()
    for _, state in ipairs({ "connected", "disconnected", "unknown" }) do
      assert.same(icon.elements(state, 16, 1), icon.elements(state, 16, 3), state)
    end
  end)

  it("draws an unreadable state faintly rather than as down", function()
    local unknown = icon.elements("unknown")[1]
    local down = icon.elements("disconnected")[1]
    assert.equals("stroke", unknown.action)
    assert.is_true(unknown.strokeColor.alpha < down.strokeColor.alpha)
    assert.is_true(icon.elements("unknown")[2].strokeColor.alpha < icon.elements("disconnected")[2].strokeColor.alpha)
  end)

  it("treats anything it does not recognise as unknown", function()
    assert.same(icon.elements("unknown"), icon.elements("sideways"))
    assert.same(icon.elements("unknown"), icon.elements(nil))
  end)

  it("carries no colour, only ink and alpha, because it is a template image", function()
    for _, state in ipairs(STATES) do
      for _, element in ipairs(icon.elements(state)) do
        for _, key in ipairs({ "fillColor", "strokeColor" }) do
          local colour = element[key]
          if colour then
            assert.equals(0, colour.white)
            assert.is_nil(colour.red)
          end
        end
      end
    end
  end)

  it("stays inside the box at any size, in every state", function()
    for _, size in ipairs({ 12, 16, 22 }) do
      for _, state in ipairs(STATES) do
        for phase = 1, icon.PHASES do
          for _, element in ipairs(icon.elements(state, size, phase)) do
            for _, point in ipairs(corners(element)) do
              assert.is_true(point.x >= 0 and point.x <= size, "x " .. state)
              assert.is_true(point.y >= 0 and point.y <= size, "y " .. state)
            end
          end
        end
      end
    end
  end)

  it("scales its stroke with the icon, so it is not a hairline at 64", function()
    assert.is_true(icon.elements("disconnected", 64)[1].strokeWidth > icon.elements("disconnected", 16)[1].strokeWidth)
    assert.is_true(icon.elements("disconnected", 64)[2].strokeWidth > icon.elements("disconnected", 16)[2].strokeWidth)
  end)
end)

describe("icon.keyholeElements", function()
  it("gives the dialog the same two shapes the menu bar cuts out", function()
    local socket, slot = icon.keyholeElements(32)
    local keyhole = icon.keyhole(32)
    assert.equals(keyhole.socket.radius, socket.radius)
    assert.same(keyhole.slot, slot.coordinates)
  end)
end)
