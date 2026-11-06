--- tests/unit/adapters/system/test_mouse_position_admission.lua
local helpers = require("tests.helpers")

helpers.describe("mouse position admission", function()
	helpers.it("refuses invalid coordinates without moving the cursor", function()
		local calls = {}
		local mouse = helpers.load_with_stubs("adapters.mouse_control", {
			mouse = { absolutePosition = function(pos) calls[#calls + 1] = pos; return pos end },
		})
		for _, point in ipairs({ { "invalid", 20 }, { 10, math.huge }, { 0/0, 20 } }) do
			helpers.assert_eq(mouse.setPos(point[1], point[2]), false)
		end
		helpers.assert_eq(#calls, 0)
		helpers.assert_eq(mouse.setPos(-100, 20), true)
		helpers.assert_eq(calls[1].x, -100)
		helpers.assert_eq(calls[1].y, 20)
	end)

	helpers.it("requires native readback near the requested position", function()
		local returned = { x = 10.5, y = 20.5 }
		local mouse = helpers.load_with_stubs("adapters.mouse_control", {
			mouse = { absolutePosition = function() return returned end },
		})
		helpers.assert_eq(mouse.setPos(10, 20), true, "sub-point rounding is accepted")
		returned = { x = 11, y = 20 }
		helpers.assert_eq(mouse.setPos(10, 20), false, "a different position is refused")
		returned = { x = 0 / 0, y = 20 }
		helpers.assert_eq(mouse.setPos(10, 20), false)
		returned = nil
		helpers.assert_eq(mouse.setPos(10, 20), false)
	end)
end)
