--- tests/unit/meta/test_gestures_manager.lua

--- ==============================================================================
--- MODULE: Gestures Manager Tests
--- Tests the Linux gestures module — action registry, slot management,
--- enable/disable, menu integration.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("modules/gestures/manager.lua", function()

  -- ==========================================================================
  -- 1. Module structural
  -- ==========================================================================

  helpers.it("module loads without error", function()
    local ok, mod = pcall(require, "modules.gestures.manager")
    helpers.assert_true(ok, "require should succeed")
    helpers.assert_true(type(mod) == "table", "should return a table")
  end)

  local M = helpers.load_module("modules.gestures.manager")

  helpers.it("exports public API surface", function()
    helpers.assert_true(type(M.is_enabled) == "function", "is_enabled")
    helpers.assert_true(type(M.enable) == "function", "enable")
    helpers.assert_true(type(M.disable) == "function", "disable")
    helpers.assert_true(type(M.toggle) == "function", "toggle")
    helpers.assert_true(type(M.get_action) == "function", "get_action")
    helpers.assert_true(type(M.set_action) == "function", "set_action")
    helpers.assert_true(type(M.get_all_actions) == "function", "get_all_actions")
    helpers.assert_true(type(M.reset_defaults) == "function", "reset_defaults")
    helpers.assert_true(type(M.start_reading) == "function", "start_reading")
    helpers.assert_true(type(M.stop_reading) == "function", "stop_reading")
    helpers.assert_true(type(M.is_reading) == "function", "is_reading")
    helpers.assert_true(type(M.get_action_label) == "function", "get_action_label")
    helpers.assert_true(type(M.get_action_names) == "function", "get_action_names")
    helpers.assert_true(type(M.process_frame) == "function", "process_frame")
    helpers.assert_true(type(M.init) == "function", "init")
    helpers.assert_true(type(M.DEFAULT_GESTURES) == "table", "DEFAULT_GESTURES")
    helpers.assert_true(type(M.SINGLE_SLOTS) == "table", "SINGLE_SLOTS")
    helpers.assert_true(type(M.AXIS_SLOTS) == "table", "AXIS_SLOTS")
  end)

  -- ==========================================================================
  -- 2. Defaults
  -- ==========================================================================

  helpers.it("DEFAULT_GESTURES has expected slots", function()
    helpers.assert_true(M.DEFAULT_GESTURES.tap_2 ~= nil, "has tap_2")
    helpers.assert_true(M.DEFAULT_GESTURES.tap_3 ~= nil, "has tap_3")
    helpers.assert_true(M.DEFAULT_GESTURES.swipe_3_left ~= nil, "has swipe_3_left")
    helpers.assert_true(M.DEFAULT_GESTURES.swipe_4_right ~= nil, "has swipe_4_right")
  end)

  helpers.it("SINGLE_SLOTS has at least 30 entries", function()
    helpers.assert_true(#M.SINGLE_SLOTS >= 30, "should have 30+ single slots")
  end)

  helpers.it("AXIS_SLOTS has 3 entries", function()
    helpers.assert_eq(#M.AXIS_SLOTS, 3)
  end)

  -- ==========================================================================
  -- 3. Enable / disable / toggle
  -- ==========================================================================

  helpers.it("is_enabled returns false initially", function()
    helpers.assert_eq(M.is_enabled(), false)
  end)

  helpers.it("enable sets enabled to true", function()
    M.enable()
    helpers.assert_true(M.is_enabled())
    M.disable()
  end)

  helpers.it("disable sets enabled to false", function()
    M.enable()
    M.disable()
    helpers.assert_eq(M.is_enabled(), false)
  end)

  helpers.it("toggle flips state", function()
    M.disable()
    M.toggle()
    helpers.assert_true(M.is_enabled())
    M.toggle()
    helpers.assert_eq(M.is_enabled(), false)
  end)

  -- ==========================================================================
  -- 4. Gesture slot management
  -- ==========================================================================

  helpers.it("get_action returns default for known slot", function()
    local action = M.get_action("swipe_3_left")
    helpers.assert_true(type(action) == "string")
    helpers.assert_true(#action > 0, "action should not be empty")
  end)

  helpers.it("set_action updates a slot", function()
    M.set_action("swipe_3_left", "vol_up")
    helpers.assert_eq(M.get_action("swipe_3_left"), "vol_up")
    M.set_action("swipe_3_left", "ws_prev")  -- restore
  end)

  helpers.it("set_action works for tap slots too", function()
    M.set_action("tap_3", "enter")
    helpers.assert_eq(M.get_action("tap_3"), "enter")
    M.set_action("tap_3", "left_click_toggle")  -- restore
  end)

  helpers.it("get_all_actions returns full mapping", function()
    local all = M.get_all_actions()
    helpers.assert_true(type(all) == "table")
    helpers.assert_true(all.swipe_3_left ~= nil)
    helpers.assert_true(all.tap_4 ~= nil)
  end)

  helpers.it("reset_defaults restores defaults", function()
    M.set_action("swipe_3_left", "vol_up")
    M.reset_defaults()
    helpers.assert_eq(M.get_action("swipe_3_left"), "ws_prev")
  end)

  -- ==========================================================================
  -- 5. Action labels
  -- ==========================================================================

  helpers.it("get_action_label returns label for known action", function()
    local label = M.get_action_label("vol_up")
    helpers.assert_true(type(label) == "string")
    helpers.assert_true(#label > 0, "label should not be empty")
  end)

  helpers.it("get_action_label returns fallback for unknown action", function()
    local label = M.get_action_label("bogus_action")
    helpers.assert_true(type(label) == "string")
  end)

  helpers.it("get_action_names returns sorted list", function()
    local names = M.get_action_names()
    helpers.assert_true(type(names) == "table")
    helpers.assert_true(#names > 10, "should have many actions")
    helpers.assert_true(names[1] ~= nil)
  end)

  -- ==========================================================================
  -- 6. Reading state
  -- ==========================================================================

  helpers.it("is_reading returns false initially", function()
    helpers.assert_eq(M.is_reading(), false)
  end)

  helpers.it("start_reading sets reading to true", function()
    M.start_reading()
    helpers.assert_true(M.is_reading())
    M.stop_reading()
  end)

  helpers.it("stop_reading sets reading to false", function()
    M.start_reading()
    M.stop_reading()
    helpers.assert_eq(M.is_reading(), false)
  end)

  -- ==========================================================================
  -- 7. Process frame (no-op stub)
  -- ==========================================================================

  helpers.it("process_frame does not crash with empty touches", function()
    local ok = pcall(M.process_frame, {})
    helpers.assert_true(ok, "process_frame should not crash")
  end)

  helpers.it("process_frame does not crash with touch data", function()
    local ok = pcall(M.process_frame, { { x = 100, y = 200 } })
    helpers.assert_true(ok, "process_frame should not crash with touch data")
  end)

  helpers.it("process_frame does nothing when disabled", function()
    M.disable()
    local ok = pcall(M.process_frame, { { x = 100, y = 200 } })
    helpers.assert_true(ok)
  end)

  -- ==========================================================================
  -- 8. Init
  -- ==========================================================================

  helpers.it("init with empty opts does not crash", function()
    local ok = pcall(function() M.init({}) end)
    helpers.assert_true(ok)
  end)

  helpers.it("init with enabled=true starts reading", function()
    M.init({ enabled = true })
    helpers.assert_true(M.is_enabled())
    helpers.assert_true(M.is_reading())
    M.disable()
    M.stop_reading()
  end)

  -- ==========================================================================
  -- 9. Menu builder integration
  -- ==========================================================================

  helpers.it("menu_builder renders gestures section when context present", function()
    local ok_mb, menu_builder = pcall(require, "modules.menu.menu_builder")
    if not ok_mb or not menu_builder then
      helpers.assert_true(true, "menu_builder not available — skipping")
      return
    end

    M.enable()
    local items = menu_builder.build({
      _version = "3.0.0",
      gestures = M,
    })

    local found = false
    for _, item in ipairs(items) do
      if type(item) == "table" and item.title and (item.title:find("Gestes") or item.title:find("gestures") or item.title:find("🖐")) then
        found = true
        helpers.assert_true(type(item.menu) == "table", "gestures should have a submenu")
        helpers.assert_true(#item.menu > 0, "gestures submenu should have items")
        break
      end
    end
    helpers.assert_true(found, "menu should contain a gestures section")
    M.disable()
  end)

  helpers.it("menu_builder handles nil gestures gracefully", function()
    local ok_mb, menu_builder = pcall(require, "modules.menu.menu_builder")
    if not ok_mb or not menu_builder then
      helpers.assert_true(true, "menu_builder not available — skipping")
      return
    end

    local items = menu_builder.build({
      _version = "3.0.0",
      gestures = nil,
    })

    local found = false
    for _, item in ipairs(items) do
      if type(item) == "table" and item.title and (item.title:find("Gestes") or item.title:find("gestures") or item.title:find("🖐")) then
        found = true
        break
      end
    end
    helpers.assert_true(found, "menu should contain a gestures stub when module absent")
  end)

end)
