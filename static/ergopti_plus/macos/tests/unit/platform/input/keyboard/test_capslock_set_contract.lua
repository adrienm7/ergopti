--- static/ergopti_plus/macos/tests/unit/platform/input/keyboard/test_capslock_set_contract.lua
--- Verifies that HID's returned state matches the requested Caps Lock state.
local helpers = require("tests.helpers")

helpers.describe("Caps Lock set receipt", function()
	helpers.it("returns false when the HID capability is unavailable", function()
		local key_state = helpers.load_with_stubs("platform.input.key_state", { hid = {} })
		local called, result = pcall(key_state.set_capslock, true)
		helpers.assert_eq(called, true)
		helpers.assert_eq(result, false)
	end)

	helpers.it("reports only the requested native state as success", function()
		local actual = false
		local key_state = helpers.load_with_stubs("platform.input.key_state", {
			hid = { capslock = { set = function() return actual end } },
		})
		helpers.assert_eq(key_state.set_capslock(true), false)
		helpers.assert_eq(key_state.set_capslock(false), true)
		actual = true
		helpers.assert_eq(key_state.set_capslock(false), false)
		helpers.assert_eq(key_state.set_capslock(true), true)
	end)
end)
