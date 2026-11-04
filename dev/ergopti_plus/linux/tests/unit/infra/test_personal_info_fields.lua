--- tests/unit/infra/test_personal_info_fields.lua

--- ==============================================================================
--- MODULE: Personal-Info Field Classification (Linux binding)
--- DESCRIPTION:
--- Pins the decisions infra/personal_info_fields.lua takes on the shared
--- declaration: a declared secret is masked, a declared open field is not, a
--- field nobody classified is masked, and a driver that cannot read the
--- declaration fails closed (masks everything) instead of revealing values.
--- ==============================================================================

local helpers = require("tests.helpers")

local Fields = require("infra.personal_info_fields")
local Paths = require("infra.paths")

helpers.describe("personal info field classification (linux-personal-fields)", function()
	helpers.it("masks a declared secret and shows a declared open field", function()
		Fields._reset()
		helpers.assert_eq(Fields.is_masked("iban"), true)
		helpers.assert_eq(Fields.is_masked("phone_number"), false)
		helpers.assert_true(Fields.for_preview("FR7630006000011234567890189", "iban") ~= "FR7630006000011234567890189")
		helpers.assert_eq(Fields.for_preview("0612345678", "phone_number"), "0612345678")
	end)

	helpers.it("masks a field nobody classified and a missing field name", function()
		Fields._reset()
		helpers.assert_eq(Fields.is_masked("not_a_declared_field"), true)
		helpers.assert_eq(Fields.is_masked(nil), true)
	end)

	helpers.it("keeps the length of a value in a log line but not its content", function()
		Fields._reset()
		local logged = Fields.for_log("secret-value")
		helpers.assert_true(logged:find("secret", 1, true) == nil)
		helpers.assert_eq(#logged > 0, true)
	end)

	helpers.it("fails closed when the shared declaration cannot be located", function()
		local saved = Paths.shared
		Paths.shared = function() return nil end
		Fields._reset()
		local ok, err = pcall(function()
			helpers.assert_eq(Fields.is_masked("phone_number"), true, "an unreadable declaration reveals nothing")
			helpers.assert_true(Fields.for_preview("0612345678", "phone_number") ~= "0612345678")
		end)
		Paths.shared = saved
		Fields._reset()
		if not ok then error(err, 0) end
	end)
end)
