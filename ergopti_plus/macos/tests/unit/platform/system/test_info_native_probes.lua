--- tests/unit/platform/system/test_info_native_probes.lua

--- ==============================================================================
--- MODULE: System information native probes
--- DESCRIPTION:
--- Exercises real adapter reads through the documented Hammerspoon host/screen
--- return shapes, including unavailable IOKit and disconnected displays.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("system information native probes", function()
	helpers.it("preserves fractional HID idle seconds and rejects unreadable observations", function()
		local idle = 0
		local info = helpers.load_with_stubs("platform.system.info", {
			host = { idleTime = function() if idle == "error" then error("IOKit unavailable") end; return idle end },
		})
		helpers.assert_eq(info.input_idle_seconds(), 0)
		idle = 0.125
		helpers.assert_eq(info.input_idle_seconds(), 0.125)
		idle = -1
		helpers.assert_eq(info.input_idle_seconds(), nil)
		idle = "error"
		helpers.assert_eq(info.input_idle_seconds(), nil)
	end)

	helpers.it("reads the screen mode's scale and tolerates a disappearing display", function()
		local screen = { currentMode = function() return { w = 1440, h = 900, scale = 2 } end }
		local info = helpers.load_with_stubs("platform.system.info", {
			screen = { allScreens = function() return screen and { screen } or {} end,
				mainScreen = function() return screen end },
		})
		helpers.assert_eq(info.monitor_count(), 1)
		helpers.assert_eq(info.main_screen_scale(), 2)
		screen = nil
		helpers.assert_eq(info.monitor_count(), 0)
		helpers.assert_eq(info.main_screen_scale(), nil)
	end)
end)
