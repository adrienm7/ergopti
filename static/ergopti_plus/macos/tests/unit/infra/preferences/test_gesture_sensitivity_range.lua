--- tests/unit/infra/preferences/test_gesture_sensitivity_range.lua

--- ==============================================================================
--- MODULE: Gesture Sensitivity Preference Range
--- DESCRIPTION:
--- A hand-edited extreme setting must not reach the incremental gesture loop.
--- ==============================================================================

local helpers = require("tests.helpers")
local OutputFixture = require("tests.support.toml_output_fixture")

helpers.describe("gesture sensitivity preference admission", function()
	helpers.it("loads supported numbers and leaves an extreme value outdated", function()
		helpers.with_stub_scope({ "infra.preferences", "adapters.file_system", "infra.logger",
			"logger.shim", "config_outdated" }, function()
			local logger = helpers.make_logger_stub()
			package.loaded["infra.logger"], package.loaded["logger.shim"] = logger, logger
			package.loaded["adapters.file_system"] = nil
			require("config_outdated").reset_for_tests()
			local preferences = helpers.load_with_stubs("infra.preferences")
			OutputFixture.with_output(function(path)
				local file = assert(io.open(path, "wb"))
				assert(file:write('[gestures.sensitivities]\nswipe_3_left = 1e-300\nswipe_3_right = 1.25\n'))
				assert(file:close())
				local state, status = preferences.load(path)
				helpers.assert_eq(status, "ok")
				helpers.assert_nil(state.gesture_sensitivities.swipe_3_left)
				helpers.assert_eq(state.gesture_sensitivities.swipe_3_right, 1.25)
			end)
		end)
	end)
end)
