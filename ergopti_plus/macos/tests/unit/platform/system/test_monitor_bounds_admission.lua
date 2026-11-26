--- tests/unit/platform/system/test_monitor_bounds_admission.lua
local helpers = require("tests.helpers")

helpers.describe("monitor bounds admission", function()
	helpers.it("does not substitute monitor one for an invalid index", function()
		local mouse = helpers.load_with_stubs("adapters.mouse_control", {
			screen = { allScreens = function()
				return { { fullFrame = function() return { x = 10, y = 20, w = 30, h = 40 } end } }
			end },
		})
		local empty = { left = 0, top = 0, right = 0, bottom = 0 }
		helpers.assert_eq(mouse.getMonitorBounds(nil), empty)
		helpers.assert_eq(mouse.getMonitorBounds("invalid"), empty)
		helpers.assert_eq(mouse.getMonitorBounds(1), { left = 10, top = 20, right = 40, bottom = 60 })
	end)
end)
