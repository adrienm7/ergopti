--- tests/unit/modules/keystats/privacy/test_focus_guard_expected_text_owner.lua

--- ==============================================================================
--- MODULE: Expected Prediction Text Destination
--- DESCRIPTION:
--- A new publication may join only the original focus retained by its AI offer.
--- A valid current field must never substitute for a different original target.
--- ==============================================================================
local helpers = require("tests.helpers")
local fixture = require("tests.support.text_owner_fixture")

helpers.describe("expected text destination admission", function()
	helpers.it("admits the exact original expected native target", function()
		fixture.with(function(guard)
			local owner = guard.capture_text_owner("atspi::1.23:/field/original")
			helpers.assert_type(owner, "table")
			helpers.assert_true(owner.current() and owner.cached())
		end)
	end)
	helpers.it("never lends the current field to a different expected native target", function()
		fixture.with(function(guard)
			helpers.assert_eq(guard.capture_text_owner("atspi::1.23:/field/successor"), nil)
		end)
	end)
end)
