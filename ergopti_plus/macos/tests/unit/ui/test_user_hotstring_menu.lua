--- tests/unit/ui/test_user_hotstring_menu.lua

--- Registers independent shared programmable-menu checks with the macOS renderer.
require("test.user_hotstring_menu_contract").run(require("tests.helpers"), require("infra.manifest_menu"), require("infra.logger"))

local helpers = require("tests.helpers")
local Preferences = require("infra.preferences")
helpers.describe("programmable canonical macOS preferences", function()
	helpers.it("reads both declared nested leaves without evaluating source", function()
		local decoded = { hotstrings = { dynamic = { user_code = { enabled = true, time_activation_seconds = 0.125 } } } }
		local flat = Preferences.flatten_document(decoded)
		helpers.assert_eq(flat.dynamichotstrings_user_code_enabled, true)
		helpers.assert_eq(flat.dynamichotstrings_user_code_time_activation_seconds, 0.125)
	end)
	helpers.it("classifies invalid executable gates and intervals as outdated instead of enabling them", function()
		for _, invalid in ipairs({ -1, math.huge, "500" }) do
			local flat = Preferences.flatten_document({ hotstrings = { dynamic = {
				user_code = { enabled = "true", time_activation_seconds = invalid } } } })
			helpers.assert_nil(flat.dynamichotstrings_user_code_enabled)
			helpers.assert_nil(flat.dynamichotstrings_user_code_time_activation_seconds)
		end
	end)
end)

return true
