--- tests/unit/modules/gestures/navigation/test_switcher_initialization_retry.lua

--- ==============================================================================
--- MODULE: Native Switcher Initialization Retry
--- DESCRIPTION:
--- A facade failure after input initialization must not initialize that owner twice.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("native switcher initialization", function()
	helpers.it("retries the facade after the input owner was initialized", function()
		helpers.with_fresh_modules({ "modules.gestures.native_app_switcher_action",
			"modules.gestures.native_app_switcher", "adapters.synthetic_input",
			"adapters.system_switcher_runtime", "infra.timings", "infra.logger" }, function()
			local input_calls, facade_calls = 0, 0
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.timings"] = { sec = function() return 1 end }
			package.loaded["adapters.system_switcher_runtime"] = { descriptor = function() return {} end }
			package.loaded["adapters.synthetic_input"] = { init_system_switcher = function()
				input_calls = input_calls + 1
				return input_calls == 1
			end }
			package.loaded["modules.gestures.native_app_switcher"] = {
				init = function() facade_calls = facade_calls + 1; return facade_calls == 2 end,
				resume = function() return true end,
				request = function() return {}, true end,
			}
			local action = require("modules.gestures.native_app_switcher_action")
			local publication = { current = function() return true end, cached = function() return true end }
			helpers.assert_eq(action.request("gestures", publication), false)
			helpers.assert_eq(action.request("gestures", publication), true)
			helpers.assert_eq(input_calls, 1)
			helpers.assert_eq(facade_calls, 2)
		end)
	end)
end)
