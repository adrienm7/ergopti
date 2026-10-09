--- tests/unit/ui/test_healthcheck_retina_scale.lua

--- ==============================================================================
--- MODULE: Healthcheck Retina Scale Regression
--- DESCRIPTION:
--- Checks the real hardware collector against display modes and usable
--- desktop frames that vary independently, as they do when the Dock changes
--- position: the backing scale comes from the display mode, never from the
--- ratio of two frames, which measures Dock space.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("healthcheck-retina-scale", function()
	for _, scale in ipairs({ 1, 2 }) do
		for _, usable_width in ipairs({ 1200, 1440 }) do
			helpers.it("reports native scale " .. scale .. " with usable width " .. usable_width, function()
				local screen = {
					id = function() return 1 end,
					currentMode = function() return { w = 1440, h = 900, scale = scale } end,
					frame = function() return { x = 0, y = 0, w = usable_width, h = 850 } end,
					fullFrame = function() return { x = 0, y = 0, w = 1440, h = 900 } end,
				}
				helpers.load_with_stubs("infra.logger", {
					screen = {
						mainScreen = function() return screen end,
						allScreens = function() return { screen } end,
					},
				})
				package.loaded["ui.healthcheck.helpers"] = nil
				local hardware = require("ui.healthcheck.helpers").collect_hardware()
				helpers.assert_eq(hardware.displays, { string.format("1440×900 @%gx (main)", scale) })
			end)
		end
	end
end)
