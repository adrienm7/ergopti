--- tests/unit/meta/test_mouse_control_adapter.lua
---
--- Integration tests for the mouse_control adapter.
--- (xdotool/xrandr stubs). Tests the full API surface without requiring
--- a running X11 server.
---
--- Real mouse control requires:
---   xdotool + xrandr (X11)

local helpers = require("tests.helpers")
local mc      = helpers.load_module("adapters.mouse_control")

helpers.describe("mouse_control adapter", function()

  -- ==========================================================================
  -- 1. Module structure
  -- ==========================================================================

  helpers.describe("module structure", function()
    helpers.it("exports setPos", function()
      helpers.assert_true(type(mc.setPos) == "function", "setPos is a function")
    end)
    helpers.it("exports getPos", function()
      helpers.assert_true(type(mc.getPos) == "function", "getPos is a function")
    end)
    helpers.it("exports getMonitorCount", function()
      helpers.assert_true(type(mc.getMonitorCount) == "function", "getMonitorCount is a function")
    end)
    helpers.it("exports getMonitorBounds", function()
      helpers.assert_true(type(mc.getMonitorBounds) == "function", "getMonitorBounds is a function")
    end)
  end)

  -- ==========================================================================
  -- 2. setPos() — move cursor
  -- ==========================================================================

  helpers.describe("setPos()", function()
    helpers.it("setPos valid coordinates does not crash", function()
      local ok = pcall(function() mc.setPos(100, 200) end)
      helpers.assert_true(ok, "setPos(100, 200) does not crash")
    end)

    helpers.it("setPos zero coordinates does not crash", function()
      local ok = pcall(function() mc.setPos(0, 0) end)
      helpers.assert_true(ok, "setPos(0, 0) does not crash")
    end)

    helpers.it("setPos negative coordinates does not crash", function()
      local ok = pcall(function() mc.setPos(-10, -20) end)
      helpers.assert_true(ok, "setPos(-10, -20) does not crash")
    end)

    helpers.it("setPos nil coordinates does not crash", function()
      local ok = pcall(function() mc.setPos(nil, nil) end)
      helpers.assert_true(ok, "setPos(nil, nil) does not crash")
    end)

    helpers.it("setPos string coordinates does not crash", function()
      local ok = pcall(function() mc.setPos("abc", "def") end)
      helpers.assert_true(ok, "setPos('abc', 'def') does not crash")
    end)
  end)

  -- ==========================================================================
  -- 3. getPos() — cursor position
  -- ==========================================================================

  helpers.describe("getPos()", function()
    helpers.it("returns a table, never nil", function()
      local pos = mc.getPos()
      helpers.assert_true(type(pos) == "table", "getPos returns a table")
    end)

    helpers.it("returns numeric x and y fields", function()
      local pos = mc.getPos()
      helpers.assert_true(type(pos.x) == "number", "pos.x is a number")
      helpers.assert_true(type(pos.y) == "number", "pos.y is a number")
    end)

    helpers.it("returns { x=0, y=0 } when xdotool absent", function()
      local pos = mc.getPos()
      helpers.assert_eq(pos.x, 0, "x defaults to 0")
      helpers.assert_eq(pos.y, 0, "y defaults to 0")
    end)
  end)

  -- ==========================================================================
  -- 4. getMonitorCount() — number of monitors
  -- ==========================================================================

  helpers.describe("getMonitorCount()", function()
    helpers.it("returns a number", function()
      local count = mc.getMonitorCount()
      helpers.assert_true(type(count) == "number", "getMonitorCount returns a number")
    end)

    helpers.it("returns 0 when xrandr absent", function()
      local count = mc.getMonitorCount()
      helpers.assert_eq(count, 0, "returns 0 without xrandr")
    end)
  end)

  -- ==========================================================================
  -- 5. getMonitorBounds() — monitor geometry
  -- ==========================================================================

  helpers.describe("getMonitorBounds()", function()
    helpers.it("returns a table, never nil", function()
      local bounds = mc.getMonitorBounds(1)
      helpers.assert_true(type(bounds) == "table", "getMonitorBounds returns a table")
    end)

    helpers.it("returns expected fields (left/top/right/bottom)", function()
      local bounds = mc.getMonitorBounds(1)
      helpers.assert_true(type(bounds.left) == "number", "has left")
      helpers.assert_true(type(bounds.top) == "number", "has top")
      helpers.assert_true(type(bounds.right) == "number", "has right")
      helpers.assert_true(type(bounds.bottom) == "number", "has bottom")
    end)

    helpers.it("returns all-zero bounds when xrandr absent", function()
      local bounds = mc.getMonitorBounds(1)
      helpers.assert_eq(bounds.left, 0, "left defaults to 0")
      helpers.assert_eq(bounds.top, 0, "top defaults to 0")
      helpers.assert_eq(bounds.right, 0, "right defaults to 0")
      helpers.assert_eq(bounds.bottom, 0, "bottom defaults to 0")
    end)

    helpers.it("getMonitorBounds with nil index does not crash", function()
      local ok = pcall(function() mc.getMonitorBounds(nil) end)
      helpers.assert_true(ok, "getMonitorBounds(nil) does not crash")
    end)

    helpers.it("getMonitorBounds with high index does not crash", function()
      local ok = pcall(function() mc.getMonitorBounds(99) end)
      helpers.assert_true(ok, "getMonitorBounds(99) does not crash")
    end)
  end)

end)
