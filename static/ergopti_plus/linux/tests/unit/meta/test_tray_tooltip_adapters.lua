--- tests/unit/meta/test_tray_tooltip_adapters.lua
---
--- Phase 2B — B5: Integration tests for tray_menu (SNI/AppIndicator) and
--- tooltip_renderer (X11/Wayland overlay) adapters. Both are currently stubbed
--- (TODO: SNI/AppIndicator not yet implemented, tooltip uses notify-send fallback).
---
--- These tests verify:
---   1. Module structure — all contract methods exported
---   2. Idempotency — methods don't crash when called in any order
---   3. Graceful degradation — adapters work when backend is unavailable
---
--- Real SNI + tooltip requires a Linux desktop with:
---   D-Bus session bus, StatusNotifierWatcher, compositor with tray support

local helpers       = require("tests.helpers")
local trayMenu      = helpers.load_module("adapters.tray_menu")
local tooltipRender = helpers.load_module("adapters.tooltip_renderer")

-- ============================================================================
-- B5a: tray_menu adapter
-- ============================================================================

helpers.describe("tray_menu adapter (SNI)", function()

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
  end)

  helpers.describe("setIcon()", function()
    helpers.it("does not crash with nil opts", function()
      local ok = pcall(function() trayMenu.setIcon(nil) end)
      helpers.assert_true(ok, "setIcon(nil) does not crash")
    end)
    helpers.it("does not crash with empty opts", function()
      local ok = pcall(function() trayMenu.setIcon({}) end)
      helpers.assert_true(ok, "setIcon({}) does not crash")
    end)
    helpers.it("does not crash with image path", function()
      local ok = pcall(function()
        trayMenu.setIcon({ image = "/path/to/icon.png", title = "Ergopti" })
      end)
      helpers.assert_true(ok, "setIcon with image+title does not crash")
    end)
  end)

  helpers.describe("setMenu()", function()
    helpers.it("does not crash with nil items", function()
      local ok = pcall(function() trayMenu.setMenu(nil) end)
      helpers.assert_true(ok, "setMenu(nil) does not crash")
    end)
    helpers.it("does not crash with empty items", function()
      local ok = pcall(function() trayMenu.setMenu({}) end)
      helpers.assert_true(ok, "setMenu({}) does not crash")
    end)
    helpers.it("does not crash with menu items", function()
      local ok = pcall(function()
        trayMenu.setMenu({
          { title = "Enable All", fn = function() end },
          { title = "Quit",      fn = function() end },
        })
      end)
      helpers.assert_true(ok, "setMenu with items does not crash")
    end)
    helpers.it("does not crash with checked/disabled items", function()
      local ok = pcall(function()
        trayMenu.setMenu({
          { title = "Toggle",   fn = function() end, checked = true },
          { title = "Greyed",   fn = function() end, disabled = true },
          { title = "Standard", fn = function() end },
        })
      end)
      helpers.assert_true(ok, "setMenu with checked/disabled does not crash")
    end)
  end)

  helpers.describe("setTooltip()", function()
    helpers.it("does not crash with text", function()
      local ok = pcall(function() trayMenu.setTooltip("Hello tooltip") end)
      helpers.assert_true(ok, "setTooltip with text does not crash")
    end)
    helpers.it("does not crash with nil", function()
      local ok = pcall(function() trayMenu.setTooltip(nil) end)
      helpers.assert_true(ok, "setTooltip(nil) does not crash")
    end)
    helpers.it("does not crash with empty string", function()
      local ok = pcall(function() trayMenu.setTooltip("") end)
      helpers.assert_true(ok, "setTooltip('') does not crash")
    end)
  end)

  helpers.describe("destroy()", function()
    helpers.it("does not crash when called idle", function()
      local ok = pcall(function() trayMenu.destroy() end)
      helpers.assert_true(ok, "destroy() idle does not crash")
    end)
    helpers.it("does not crash when called twice", function()
      pcall(function() trayMenu.destroy() end)
      local ok = pcall(function() trayMenu.destroy() end)
      helpers.assert_true(ok, "double destroy() does not crash")
    end)
  end)

  helpers.describe("lifecycle", function()
    helpers.it("setIcon → setMenu → setTooltip → destroy does not crash", function()
      local ok = pcall(function()
        trayMenu.setIcon({ image = "icon.png" })
        trayMenu.setMenu({ { title = "Test", fn = function() end } })
        trayMenu.setTooltip("Tooltip")
        trayMenu.destroy()
      end)
      helpers.assert_true(ok, "full lifecycle does not crash")
    end)
    helpers.it("destroy → setIcon does not crash (re-create after destroy)", function()
      pcall(function() trayMenu.destroy() end)
      local ok = pcall(function()
        trayMenu.setIcon({ image = "icon.png" })
      end)
      helpers.assert_true(ok, "setIcon after destroy does not crash")
    end)
  end)

end)


-- ============================================================================
-- B5b: tooltip_renderer adapter
-- ============================================================================

helpers.describe("tooltip_renderer adapter", function()

  helpers.describe("module structure", function()
    helpers.it("exports show", function()
      helpers.assert_true(type(tooltipRender.show) == "function", "show is a function")
    end)
    helpers.it("exports hide", function()
      helpers.assert_true(type(tooltipRender.hide) == "function", "hide is a function")
    end)
    helpers.it("exports isVisible", function()
      helpers.assert_true(type(tooltipRender.isVisible) == "function", "isVisible is a function")
    end)
    helpers.it("exports updateElement", function()
      helpers.assert_true(type(tooltipRender.updateElement) == "function", "updateElement is a function")
    end)
  end)

  helpers.describe("isVisible()", function()
    helpers.it("returns false initially", function()
      helpers.assert_true(not tooltipRender.isVisible(), "not visible initially")
    end)
  end)

  helpers.describe("show()", function()
    helpers.it("does not crash with nil payload", function()
      local ok = pcall(function() tooltipRender.show(nil) end)
      helpers.assert_true(ok, "show(nil) does not crash")
    end)
    helpers.it("does not crash with empty payload", function()
      local ok = pcall(function() tooltipRender.show({}) end)
      helpers.assert_true(ok, "show({}) does not crash")
    end)
    helpers.it("does not crash with draw_calls", function()
      local ok = pcall(function()
        tooltipRender.show({
          draw_calls = {
            { id = "line1", type = "text", text = "Hello" },
            { id = "line2", type = "text", text = "World" },
          },
          position = { x = 100, y = 200 },
          duration_sec = 3,
        })
      end)
      helpers.assert_true(ok, "show with draw_calls does not crash")
    end)
    helpers.it("does not crash with empty draw_calls", function()
      local ok = pcall(function()
        tooltipRender.show({ draw_calls = {} })
      end)
      helpers.assert_true(ok, "show with empty draw_calls does not crash")
    end)
  end)

  helpers.describe("hide()", function()
    helpers.it("does not crash when called idle", function()
      local ok = pcall(function() tooltipRender.hide() end)
      helpers.assert_true(ok, "hide() idle does not crash")
    end)
    helpers.it("does not crash when called twice", function()
      pcall(function() tooltipRender.hide() end)
      local ok = pcall(function() tooltipRender.hide() end)
      helpers.assert_true(ok, "double hide() does not crash")
    end)
  end)

  helpers.describe("updateElement()", function()
    helpers.it("does not crash with nil draw_call", function()
      local ok = pcall(function() tooltipRender.updateElement(nil) end)
      helpers.assert_true(ok, "updateElement(nil) does not crash")
    end)
    helpers.it("does not crash with draw_call (not visible)", function()
      -- updateElement is a no-op when not visible
      local ok = pcall(function()
        tooltipRender.updateElement({ id = "line1", text = "Updated" })
      end)
      helpers.assert_true(ok, "updateElement not visible does not crash")
    end)
  end)

  helpers.describe("lifecycle", function()
    helpers.it("show → updateElement → hide does not crash", function()
      local ok = pcall(function()
        tooltipRender.show({ draw_calls = {{ text = "Loading..." }} })
        tooltipRender.updateElement({ id = "status", text = "Done" })
        tooltipRender.hide()
      end)
      helpers.assert_true(ok, "tooltip lifecycle does not crash")
    end)
  end)

end)
