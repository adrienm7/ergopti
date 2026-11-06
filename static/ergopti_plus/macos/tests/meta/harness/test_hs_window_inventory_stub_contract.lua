--- static/ergopti_plus/macos/tests/meta/harness/test_hs_window_inventory_stub_contract.lua
--- Verifies that the central window stub models native visible inventories.
local helpers = require("tests.helpers")

helpers.describe("hs.window inventory stub", function()
	helpers.it("exposes only visible windows and resets its inventory", function()
		local hs_stub = dofile("tests/stubs/hs.lua")
		local visible = { isVisible = function() return true end }
		local hidden = { isVisible = function() return false end }
		hs_stub.window.__windows = { visible, hidden }
		helpers.assert_eq(hs_stub.window.allWindows(), { visible, hidden })
		helpers.assert_eq(hs_stub.window.visibleWindows(), { visible })
		hs_stub.__reset()
		helpers.assert_eq(hs_stub.window.visibleWindows(), {})
	end)
end)
