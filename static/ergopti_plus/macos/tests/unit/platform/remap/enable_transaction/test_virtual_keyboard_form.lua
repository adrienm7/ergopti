--- tests/unit/platform/remap/enable_transaction/test_virtual_keyboard_form.lua

--- ==============================================================================
--- MODULE: Deployed Virtual Keyboard Form Accessor
--- DESCRIPTION:
--- Keyboard geometry resolves the ISO pair with the form the bridge deploys
--- (issue #95). The accessor answers it only while the integration is on.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.remap_transaction_fixture")

helpers.describe("karabiner virtual_keyboard_form", function()
	helpers.it("answers the resolved form while enabled and nil once disabled", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap()
			helpers.assert_true(remap.get_enabled())
			-- The fixture's layout resolver answers "ansi"; a regeneration resolves
			-- the action list with it and records that form for the generator.
			remap.AVAILABLE_ACTIONS = {}
			remap.regenerate()
			helpers.assert_eq(remap.virtual_keyboard_form(), "ansi",
				"the enabled bridge must answer the form its actions resolved with")
			helpers.assert_true(remap.set_enabled(false))
			calls.finish_stop(true, "stopped")
			helpers.assert_eq(remap.get_enabled(), false)
			helpers.assert_nil(remap.virtual_keyboard_form(),
				"a disabled bridge deploys no virtual keyboard form")
		end)
	end)
end)
