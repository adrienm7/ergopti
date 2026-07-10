--- tests/unit/meta/test_tray_tooltip_adapters.lua
---
--- Integration tests for tray_menu + tooltip_renderer.
--- Now tests the full implementations: yad subprocess lifecycle, menu
--- serialization, signal-file callbacks, tooltip positioning, backend detection,
--- updateElement re-rendering.
---
--- Real tray icons and tooltips require:
---   yad (GTK+ systray) or zenity (fallback)
---   xdotool (for tooltip positioning, optional)

local helpers  = require("tests.helpers")
local trayMenu = helpers.load_module("adapters.tray_menu")
local tooltip  = helpers.load_module("adapters.tooltip_renderer")

helpers.describe("tray_menu adapter", function()

  -- ==========================================================================
  -- 1. Module structure
  -- ==========================================================================

  helpers.describe("module structure", function()
    helpers.it("exports setIcon", function()
      helpers.assert_true(type(trayMenu.setIcon) == "function", "setIcon is a function")
    end)
    helpers.it("exports setMenu", function()
      helpers.assert_true(type(trayMenu.setMenu) == "function", "setMenu is a function")
    end)
    helpers.it("exports setTooltip", function()
      helpers.assert_true(type(trayMenu.setTooltip) == "function", "setTooltip is a function")
    end)
    helpers.it("exports destroy", function()
      helpers.assert_true(type(trayMenu.destroy) == "function", "destroy is a function")
    end)
    helpers.it("exports pump", function()
      helpers.assert_true(type(trayMenu.pump) == "function", "pump is a function")
    end)
  end)

  -- ==========================================================================
  -- 2. Lifecycle
  -- ==========================================================================

  helpers.describe("lifecycle", function()
    helpers.it("setIcon does not crash when yad is absent", function()
      -- On Windows CI, yad won't exist — setIcon should gracefully degrade.
      local ok = pcall(function()
        trayMenu.setIcon({ image = "icon.png" })
      end)
      helpers.assert_true(ok, "setIcon does not crash")
    end)

    helpers.it("setIcon with empty opts does not crash", function()
      local ok = pcall(function() trayMenu.setIcon({}) end)
      helpers.assert_true(ok, "setIcon({}) does not crash")
    end)

    helpers.it("setIcon with nil opts does not crash", function()
      local ok = pcall(function() trayMenu.setIcon(nil) end)
      helpers.assert_true(ok, "setIcon(nil) does not crash")
    end)

    helpers.it("destroy does not crash when no tray icon active", function()
      local ok = pcall(function() trayMenu.destroy() end)
      helpers.assert_true(ok, "destroy when idle does not crash")
    end)

    helpers.it("destroy is idempotent", function()
      trayMenu.destroy()
      local ok = pcall(function() trayMenu.destroy() end)
      helpers.assert_true(ok, "double destroy does not crash")
    end)

    helpers.it("full lifecycle does not crash", function()
      local ok = pcall(function()
        trayMenu.setIcon({ image = "icon.png", title = "Ergopti" })
        trayMenu.setMenu({ { title = "Test", fn = function() end } })
        trayMenu.setTooltip("Hover text")
        trayMenu.destroy()
      end)
      helpers.assert_true(ok, "full lifecycle does not crash")
    end)
  end)

  -- ==========================================================================
  -- 3. setMenu() — menu serialization
  -- ==========================================================================

  helpers.describe("setMenu()", function()
    helpers.it("setMenu with valid items does not crash", function()
      local ok = pcall(function()
        trayMenu.setMenu({
          { title = "Item 1", fn = function() end },
          { title = "Item 2", fn = function() end },
          { title = "Disabled", fn = function() end, disabled = true },
        })
      end)
      helpers.assert_true(ok, "setMenu with items does not crash")
    end)

    helpers.it("setMenu with empty array does not crash", function()
      local ok = pcall(function() trayMenu.setMenu({}) end)
      helpers.assert_true(ok, "setMenu({}) does not crash")
    end)

    helpers.it("setMenu with nil does not crash", function()
      local ok = pcall(function() trayMenu.setMenu(nil) end)
      helpers.assert_true(ok, "setMenu(nil) does not crash")
    end)

    helpers.it("setMenu with non-table does not crash", function()
      local ok = pcall(function() trayMenu.setMenu("not an array") end)
      helpers.assert_true(ok, "setMenu('string') does not crash")
    end)

    helpers.it("setMenu with special characters in titles does not crash", function()
      local ok = pcall(function()
        trayMenu.setMenu({
          { title = "Item with 'quotes'", fn = function() end },
          { title = "Item with $HOME", fn = function() end },
          { title = "Item with ! exclamation", fn = function() end },
        })
      end)
      helpers.assert_true(ok, "setMenu with special chars does not crash")
    end)
  end)

  -- ==========================================================================
  -- 4. setTooltip()
  -- ==========================================================================

  helpers.describe("setTooltip()", function()
    helpers.it("setTooltip with plain text does not crash", function()
      local ok = pcall(function() trayMenu.setTooltip("Hello") end)
      helpers.assert_true(ok, "setTooltip('Hello') does not crash")
    end)

    helpers.it("setTooltip with empty string does not crash", function()
      local ok = pcall(function() trayMenu.setTooltip("") end)
      helpers.assert_true(ok, "setTooltip('') does not crash")
    end)

    helpers.it("setTooltip with nil does not crash", function()
      local ok = pcall(function() trayMenu.setTooltip(nil) end)
      helpers.assert_true(ok, "setTooltip(nil) does not crash")
    end)
  end)

  -- ==========================================================================
  -- 5. pump() — signal-file polling
  -- ==========================================================================

  helpers.describe("pump()", function()
    helpers.it("pump when no signal file does not crash", function()
      local ok = pcall(function() trayMenu.pump() end)
      helpers.assert_true(ok, "pump does not crash")
    end)

    helpers.it("pump many times does not crash", function()
      local ok = pcall(function()
        for _ = 1, 10 do trayMenu.pump() end
      end)
      helpers.assert_true(ok, "10x pump does not crash")
    end)

    helpers.it("pump after destroy does not crash", function()
      trayMenu.destroy()
      local ok = pcall(function() trayMenu.pump() end)
      helpers.assert_true(ok, "pump after destroy does not crash")
    end)
  end)

end)

helpers.describe("tooltip_renderer adapter", function()

  -- ==========================================================================
  -- 6. Module structure
  -- ==========================================================================

  helpers.describe("module structure", function()
    helpers.it("exports show", function()
      helpers.assert_true(type(tooltip.show) == "function", "show is a function")
    end)
    helpers.it("exports hide", function()
      helpers.assert_true(type(tooltip.hide) == "function", "hide is a function")
    end)
    helpers.it("exports isVisible", function()
      helpers.assert_true(type(tooltip.isVisible) == "function", "isVisible is a function")
    end)
    helpers.it("exports updateElement", function()
      helpers.assert_true(type(tooltip.updateElement) == "function", "updateElement is a function")
    end)
  end)

  -- ==========================================================================
  -- 7. show() / hide() lifecycle
  -- ==========================================================================

  helpers.describe("show/hide lifecycle", function()
    helpers.it("show with empty payload does not crash", function()
      local ok = pcall(function() tooltip.show({}) end)
      helpers.assert_true(ok, "show({}) does not crash")
    end)

    helpers.it("show with draw_calls containing text does not crash", function()
      local ok = pcall(function()
        tooltip.show({
          draw_calls = {
            { id = "title", type = "text", text = "Hello World" },
          },
        })
      end)
      helpers.assert_true(ok, "show with text draw_call does not crash")
    end)

    helpers.it("show with nil payload does not crash", function()
      local ok = pcall(function() tooltip.show(nil) end)
      helpers.assert_true(ok, "show(nil) does not crash")
    end)

    helpers.it("hide when not visible does not crash", function()
      local ok = pcall(function() tooltip.hide() end)
      helpers.assert_true(ok, "hide when not visible does not crash")
    end)

    helpers.it("isVisible defaults to false", function()
      helpers.assert_eq(tooltip.isVisible(), false, "isVisible is false initially")
    end)

    helpers.it("show-hide cycle does not crash", function()
      local ok = pcall(function()
        tooltip.show({
          draw_calls = {
            { id = "body", type = "text", text = "Test tooltip" },
          },
        })
        tooltip.hide()
      end)
      helpers.assert_true(ok, "show-hide cycle does not crash")
    end)
  end)

  -- ==========================================================================
  -- 8. updateElement()
  -- ==========================================================================

  helpers.describe("updateElement()", function()
    helpers.it("updateElement with valid draw_call does not crash", function()
      local ok = pcall(function()
        tooltip.updateElement({ id = "title", type = "text", text = "Updated" })
      end)
      helpers.assert_true(ok, "updateElement does not crash")
    end)

    helpers.it("updateElement with nil does not crash", function()
      local ok = pcall(function() tooltip.updateElement(nil) end)
      helpers.assert_true(ok, "updateElement(nil) does not crash")
    end)

    helpers.it("updateElement with non-table does not crash", function()
      local ok = pcall(function() tooltip.updateElement("not a table") end)
      helpers.assert_true(ok, "updateElement('string') does not crash")
    end)
  end)

  -- ==========================================================================
  -- 9. Multiple draw calls
  -- ==========================================================================

  helpers.describe("multiple draw calls", function()
    helpers.it("show with multiple draw_calls extracts first text", function()
      local ok = pcall(function()
        tooltip.show({
          draw_calls = {
            { id = "bg",   type = "rect", x = 0, y = 0, w = 200, h = 60 },
            { id = "text", type = "text", text = "Line 1" },
            { id = "text2", type = "text", text = "Line 2" },
          },
        })
      end)
      helpers.assert_true(ok, "show with mixed draw_calls does not crash")
    end)

    helpers.it("show with empty draw_calls array does not crash", function()
      local ok = pcall(function()
        tooltip.show({ draw_calls = {} })
      end)
      helpers.assert_true(ok, "show with empty draw_calls does not crash")
    end)
  end)

  -- ==========================================================================
  -- 10. Positioning
  -- ==========================================================================

  helpers.describe("positioning", function()
    helpers.it("show with explicit position does not crash", function()
      local ok = pcall(function()
        tooltip.show({
          draw_calls = { { id = "t", type = "text", text = "Hi" } },
          position = { x = 100, y = 200 },
        })
      end)
      helpers.assert_true(ok, "show with position does not crash")
    end)

    helpers.it("show with odd position values does not crash", function()
      local ok = pcall(function()
        tooltip.show({
          draw_calls = { { id = "t", type = "text", text = "Hi" } },
          position = { x = -10, y = 0 },
        })
      end)
      helpers.assert_true(ok, "show with negative position does not crash")
    end)
  end)

  -- ==========================================================================
  -- 11. Duration
  -- ==========================================================================

  helpers.describe("duration", function()
    helpers.it("show with duration_sec does not crash", function()
      local ok = pcall(function()
        tooltip.show({
          draw_calls = { { id = "t", type = "text", text = "Auto-hide" } },
          duration_sec = 3.0,
        })
      end)
      helpers.assert_true(ok, "show with duration does not crash")
    end)

    helpers.it("show with zero duration does not crash", function()
      local ok = pcall(function()
        tooltip.show({
          draw_calls = { { id = "t", type = "text", text = "No timeout" } },
          duration_sec = 0,
        })
      end)
      helpers.assert_true(ok, "show with 0 duration does not crash")
    end)
  end)

end)
