local icon = require("vpnbar.icon")

local STATES = { "connected", "connecting", "disconnected", "unknown" }

local function actions(elements)
  local out = {}
  for _, element in ipairs(elements) do
    out[#out + 1] = element.action
  end
  return out
end

describe("icon.shield", function()
  it("scales to the size it is asked for", function()
    for _, size in ipairs({ 16, 18, 64 }) do
      for _, point in ipairs(icon.shield(size)) do
        assert.is_true(point.x >= 0 and point.x <= size)
        assert.is_true(point.y >= 0 and point.y <= size)
      end
    end
  end)

  it("is a closed shape with enough points to read as a shield", function()
    -- Five: two shoulders, two flanks, one point. Fewer is a triangle, more
    -- was tried and turns to mud at the size this is actually drawn at.
    assert.equals(5, #icon.shield(16))
  end)

  it("is symmetrical about its centre line", function()
    local size = 16
    local points = icon.shield(size)
    for _, point in ipairs(points) do
      local mirrored = false
      for _, other in ipairs(points) do
        if math.abs((size - other.x) - point.x) < 0.001 and math.abs(other.y - point.y) < 0.001 then
          mirrored = true
        end
      end
      assert.is_true(mirrored)
    end
  end)

  it("comes to a point at the bottom, on the centre line", function()
    local points = icon.shield(16)
    local lowest = points[1]
    for _, point in ipairs(points) do
      if point.y > lowest.y then
        lowest = point
      end
    end
    assert.equals(8, lowest.x)
  end)
end)

describe("icon.elements", function()
  it("draws something for every state", function()
    for _, state in ipairs(STATES) do
      assert.is_true(#icon.elements(state) >= 1)
    end
  end)

  it("fills the shield when connected and only outlines it when not", function()
    assert.equals("fill", icon.elements("connected")[1].action)
    assert.same({ "stroke" }, actions(icon.elements("disconnected")))
  end)

  it("cuts the tick out of the fill rather than drawing over it", function()
    -- Drawn on top, a second mark would be the same ink as the shield and
    -- invisible; cut out, it takes the colour of the menu bar behind it, which
    -- is right whichever way macOS tints the template.
    local tick = icon.elements("connected")[2]
    assert.equals("clear", tick.compositeRule)
    assert.equals("stroke", tick.action)
    assert.is_false(tick.closed)
  end)

  it("has nothing to cut out of an outline", function()
    for _, state in ipairs({ "connecting", "disconnected", "unknown" }) do
      for _, element in ipairs(icon.elements(state)) do
        assert.not_equals("clear", element.compositeRule)
      end
    end
  end)

  it("shows the middle filling in while it works", function()
    local elements = icon.elements("connecting")
    assert.equals(2, #elements)
    assert.equals("stroke", elements[1].action)
    assert.equals("circle", elements[2].type)
  end)

  it("draws an unreadable state faintly rather than as down", function()
    local unknown = icon.elements("unknown")[1]
    local down = icon.elements("disconnected")[1]
    assert.equals("stroke", unknown.action)
    assert.is_true(unknown.strokeColor.alpha < down.strokeColor.alpha)
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
    local elements = {}
    for _, size in ipairs({ 12, 16, 22 }) do
      for _, state in ipairs(STATES) do
        for _, element in ipairs(icon.elements(state, size)) do
          elements[#elements + 1] = { size = size, element = element }
        end
      end
    end
    for _, entry in ipairs(elements) do
      local size, element = entry.size, entry.element
      for _, point in ipairs(element.coordinates or {}) do
        assert.is_true(point.x >= 0 and point.x <= size)
        assert.is_true(point.y >= 0 and point.y <= size)
      end
      if element.center then
        assert.is_true(element.center.x + element.radius <= size)
        assert.is_true(element.center.y + element.radius <= size)
      end
    end
  end)

  it("scales its stroke with the icon, so it is not a hairline at 64", function()
    assert.is_true(icon.elements("disconnected", 64)[1].strokeWidth > icon.elements("disconnected", 16)[1].strokeWidth)
  end)
end)
