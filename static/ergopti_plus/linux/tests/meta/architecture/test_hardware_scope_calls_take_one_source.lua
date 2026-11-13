--- tests/meta/architecture/test_hardware_scope_calls_take_one_source.lua

--- ==============================================================================
--- MODULE: Hardware Scope Calls Take One Source (Linux driver)
--- DESCRIPTION:
--- infra/key_combinations_scope.lua takes `expected_source` as the argument
--- after the rows since EDD-1 removed the pause argument (a pause stops typing,
--- not configuration). The hardware test still passed `script.is_paused`
--- there, so the pause function landed in `expected_source` and the Linux E2E
--- desktop-webview job failed (2026-11-12). This guard fails when a hardware
--- runner hands a pause getter to a key-combination scope operation again.
--- ==============================================================================

local helpers = require("tests.helpers")

local RUNNER = helpers.driver_root() .. "/tests/hardware/run_simultaneous_configuration_real.lua"
local OPERATIONS = { "edit", "set_enabled", "set_chord_settings", "copy_taps_to_chords", "apply" }

helpers.describe("hardware scope calls take one source (edd1-scope-source)", function()
	helpers.it("passes no pause getter to a key-combination scope operation (edd1-scope-source)", function()
		local file = assert(io.open(RUNNER, "r"))
		local source = file:read("*a")
		file:close()
		helpers.assert_true(source:find("Scope.copy_taps_to_chords(", 1, true) ~= nil, "the runner still copies taps")
		for _, operation in ipairs(OPERATIONS) do
			for call in source:gmatch("Scope%." .. operation .. "(%b())") do
				helpers.assert_nil(call:find("is_paused", 1, true),
					"Scope." .. operation .. " takes no pause argument since EDD-1: " .. call)
			end
		end
	end)
end)
