--- static/ergopti_plus/macos/tests/unit/adapters/system/test_visible_window_inventory.lua
--- Tests the native visible-window inventory used by both window ports.
local helpers = require("tests.helpers")

helpers.describe("visible window inventories", function()
	helpers.it("both ports consume the central stub's visible inventory", function()
		local native = dofile("tests/stubs/hs.lua")
		local app = { name = function() return "App" end, bundleID = function() return "app" end }
		local shown = { id = function() return 4 end, title = function() return "Shown" end,
			application = function() return app end, isVisible = function() return true end }
		local hidden = { id = function() return 5 end, title = function() return "Hidden" end,
			application = function() return app end, isVisible = function() return false end }
		native.window.__windows = { shown, hidden }
		local info = helpers.load_with_stubs("adapters.window_info", { window = native.window })
		local manager = helpers.load_with_stubs("adapters.window_manager", { window = native.window })
		local rows = info.getAll()
		helpers.assert_eq(#rows, 1)
		helpers.assert_eq(rows[1].windowTitle, "Shown")
		helpers.assert_eq(manager.getList(), { 4 })
	end)

	helpers.it("exclude hidden and minimized windows from both ports", function()
		local visible = { id = function() return 1 end, title = function() return "Visible" end,
			application = function() return { name = function() return "App" end, bundleID = function() return "app" end } end }
		local hidden = { id = function() return 2 end, title = function() return "Hidden" end,
			application = visible.application }
		local native = { allWindows = function() return { visible, hidden } end,
			visibleWindows = function() return { visible } end }
		local info = helpers.load_with_stubs("adapters.window_info", { window = native })
		local manager = helpers.load_with_stubs("adapters.window_manager", { window = native })
		helpers.assert_eq(#info.getAll(), 1)
		helpers.assert_eq(manager.getList(), { 1 })
	end)
end)
