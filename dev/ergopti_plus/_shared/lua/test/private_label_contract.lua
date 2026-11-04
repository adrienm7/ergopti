--- _shared/lua/test/private_label_contract.lua

--- ==============================================================================
--- MODULE: Private Label Contract
--- DESCRIPTION:
--- Pins the placeholder a log line prints for a user-chosen name to the one the
--- redaction policy declares, and its refusal of a non-string. Both Lua drivers
--- replay it; their loaders are covered by their own "name never in the log" tests.
--- ==============================================================================

--- Registers the contract.
--- @param helpers table Driver test helpers.
--- @param policy table The decoded _shared/modules/diagnostics/redaction.json.
return function(helpers, policy)
	local PrivateLabel = require("diagnostics.private_label")

	helpers.describe("private label (shared contract)", function()
		helpers.it("uses the placeholder the redaction policy declares", function()
			helpers.assert_eq(PrivateLabel.PLACEHOLDER, policy.config_name_placeholder)
		end)

		helpers.it("masks any name and never echoes it", function()
			helpers.assert_eq(PrivateLabel.mask("my_personal_pack"), PrivateLabel.PLACEHOLDER)
			helpers.assert_eq(PrivateLabel.mask(""), PrivateLabel.PLACEHOLDER)
		end)

		helpers.it("refuses a name that is not a string", function()
			helpers.assert_true(not pcall(PrivateLabel.mask, nil), "nil refused")
			helpers.assert_true(not pcall(PrivateLabel.mask, 3), "number refused")
		end)
	end)
end
