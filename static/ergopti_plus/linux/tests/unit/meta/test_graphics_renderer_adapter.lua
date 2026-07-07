--- tests/unit/meta/test_graphics_renderer_adapter.lua
---
--- Phase 2B — B13: Integration tests for the graphics_renderer adapter
--- (no-op stub). Tests all methods (createWindow/destroyWindow/drawBitmap/
--- show/hide) — all are safe no-ops that never crash.
---
--- Native overlay rendering requires GTK4 + layer-shell protocol.
--- The current stub is intentional for the MVP.

local helpers = require("tests.helpers")
local gr      = helpers.load_module("adapters.graphics_renderer")

helpers.describe("graphics_renderer adapter", function()

  -- ==========================================================================
  -- 1. Module structure
  -- ==========================================================================

  helpers.describe("module structure", function()
    helpers.it("exports createWindow", function()
      helpers.assert_true(type(gr.createWindow) == "function", "createWindow is a function")
    end)
    helpers.it("exports destroyWindow", function()
      helpers.assert_true(type(gr.destroyWindow) == "function", "destroyWindow is a function")
    end)
    helpers.it("exports drawBitmap", function()
      helpers.assert_true(type(gr.drawBitmap) == "function", "drawBitmap is a function")
    end)
    helpers.it("exports show", function()
      helpers.assert_true(type(gr.show) == "function", "show is a function")
    end)
    helpers.it("exports hide", function()
      helpers.assert_true(type(gr.hide) == "function", "hide is a function")
    end)
  end)

  -- ==========================================================================
  -- 2. createWindow() — canvas allocation
  -- ==========================================================================

  helpers.describe("createWindow()", function()
    helpers.it("returns 0 (INVALID_HANDLE) on no-op stub", function()
      local handle = gr.createWindow({ x = 0, y = 0, w = 200, h = 60 })
      helpers.assert_eq(handle, 0, "returns 0 (INVALID_HANDLE)")
    end)

    helpers.it("returns 0 with empty opts", function()
      local handle = gr.createWindow({})
      helpers.assert_eq(handle, 0, "returns 0 with no options")
    end)

    helpers.it("returns 0 with nil opts", function()
      local handle = gr.createWindow(nil)
      helpers.assert_eq(handle, 0, "returns 0 with nil opts")
    end)

    helpers.it("returns a number (not nil)", function()
      local handle = gr.createWindow()
      helpers.assert_true(type(handle) == "number", "returns a number")
    end)
  end)

  -- ==========================================================================
  -- 3. destroyWindow() — safe no-op
  -- ==========================================================================

  helpers.describe("destroyWindow()", function()
    helpers.it("destroyWindow with INVALID_HANDLE does not crash", function()
      local ok = pcall(function() gr.destroyWindow(0) end)
      helpers.assert_true(ok, "destroyWindow(0) does not crash")
    end)

    helpers.it("destroyWindow with nil does not crash", function()
      local ok = pcall(function() gr.destroyWindow(nil) end)
      helpers.assert_true(ok, "destroyWindow(nil) does not crash")
    end)

    helpers.it("destroyWindow with garbage handle does not crash", function()
      local ok = pcall(function() gr.destroyWindow(42) end)
      helpers.assert_true(ok, "destroyWindow(42) does not crash")
    end)
  end)

  -- ==========================================================================
  -- 4. drawBitmap() — safe no-op
  -- ==========================================================================

  helpers.describe("drawBitmap()", function()
    helpers.it("drawBitmap with valid draw_fn does not crash", function()
      local ok = pcall(function()
        gr.drawBitmap(0, function(canvas) end)
      end)
      helpers.assert_true(ok, "drawBitmap(0, fn) does not crash")
    end)

    helpers.it("drawBitmap with nil draw_fn does not crash", function()
      local ok = pcall(function()
        gr.drawBitmap(0, nil)
      end)
      helpers.assert_true(ok, "drawBitmap(0, nil) does not crash")
    end)
  end)

  -- ==========================================================================
  -- 5. show() / hide() — safe no-ops
  -- ==========================================================================

  helpers.describe("show/hide", function()
    helpers.it("show with INVALID_HANDLE does not crash", function()
      local ok = pcall(function() gr.show(0) end)
      helpers.assert_true(ok, "show(0) does not crash")
    end)

    helpers.it("hide with INVALID_HANDLE does not crash", function()
      local ok = pcall(function() gr.hide(0) end)
      helpers.assert_true(ok, "hide(0) does not crash")
    end)

    helpers.it("show-hide cycle does not crash", function()
      local ok = pcall(function()
        gr.show(0)
        gr.hide(0)
        gr.show(0)
      end)
      helpers.assert_true(ok, "show-hide-show cycle does not crash")
    end)
  end)

  -- ==========================================================================
  -- 6. Full lifecycle simulation
  -- ==========================================================================

  helpers.describe("full lifecycle", function()
    helpers.it("create → draw → show → hide → destroy does not crash", function()
      local ok = pcall(function()
        local h = gr.createWindow({ x = 10, y = 20, w = 300, h = 80 })
        gr.drawBitmap(h, function() end)
        gr.show(h)
        gr.hide(h)
        gr.destroyWindow(h)
      end)
      helpers.assert_true(ok, "full stub lifecycle does not crash")
    end)
  end)

end)
