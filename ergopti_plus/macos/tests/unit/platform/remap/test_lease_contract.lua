--- tests/unit/platform/remap/test_lease_contract.lua

--- ==============================================================================
--- MODULE: Karabiner Lease Contract Tests
--- DESCRIPTION:
--- Pins the pure token and variable-name contract shared by the Karabiner JSON
--- generator and lifecycle controller, preventing a split-brain generation.
--- ==============================================================================

local helpers = require("tests.helpers")
local Contract = require("platform.remap.lease_contract")

local TOKEN = "00112233445566778899aabbccddeeff"
local UUID = "00112233-4455-6677-8899-aabbccddeeff"





-- =======================================
-- =======================================
-- ======= 1/ Canonical Token Form =======
-- =======================================
-- =======================================

helpers.describe("Karabiner lease contract: canonical token form", function()
	helpers.it("accepts only exact lowercase 32-hex runtime tokens", function()
		helpers.assert_true(Contract.is_valid_token(TOKEN), "canonical token must be valid")
		for _, invalid in ipairs({
			TOKEN:upper(),
			TOKEN:sub(1, 31),
			TOKEN .. "0",
			TOKEN:sub(1, 31) .. "g",
			UUID,
		}) do
			helpers.assert_true(not Contract.is_valid_token(invalid),
				"non-canonical runtime token must be rejected: " .. invalid)
		end
		helpers.assert_true(not Contract.is_valid_token(false), "non-string tokens must be rejected")
	end)

	helpers.it("normalizes exact hexadecimal and RFC UUID host inputs", function()
		helpers.assert_eq(TOKEN, Contract.normalize_token(TOKEN:upper()))
		helpers.assert_eq(TOKEN, Contract.normalize_token(UUID:upper()))
	end)

	helpers.it("rejects malformed UUID punctuation and placement", function()
		for _, invalid in ipairs({
			"001122334-455-6677-8899-aabbccddeeff",
			"00112233_4455-6677-8899-aabbccddeeff",
			"00112233-4455-6677-8899-aabbccddegff",
			"00112233-4455-6677-8899-aabbccddeef",
		}) do
			local token, err = Contract.normalize_token(invalid)
			helpers.assert_nil(token, "malformed UUID must not normalize: " .. invalid)
			helpers.assert_true(type(err) == "string" and err ~= "",
				"malformed UUID must explain rejection")
		end
	end)
end)





-- =========================================
-- =========================================
-- ======= 2/ Exact Variable Names =========
-- =========================================
-- =========================================

helpers.describe("Karabiner lease contract: exact variable names", function()
	helpers.it("derives one stable atomic mode and revocation bundle", function()
		local variables, err = Contract.variables(TOKEN)
		helpers.assert_nil(err, "canonical token must derive variables")
		helpers.assert_eq(TOKEN, variables.token)
		helpers.assert_eq("ergopti_mode_" .. TOKEN, variables.mode)
		helpers.assert_eq("ergopti_revoked_" .. TOKEN, variables.revoked)
		helpers.assert_eq(variables.mode, Contract.mode_variable_name(TOKEN))
		helpers.assert_eq(variables.revoked, Contract.revoked_variable_name(TOKEN))
		helpers.assert_eq(Contract.MODE_OFF, 0)
		helpers.assert_eq(Contract.MODE_ACTIVE, 1)
		helpers.assert_eq(Contract.MODE_PAUSED, 2)
	end)

	helpers.it("derives and parses exact generation-scoped runtime names", function()
		local cases = {
			"layer_active",
			"capsword",
			"ke_held_right_command",
		}
		for _, logical_name in ipairs(cases) do
			local expected = "ergopti_" .. logical_name .. "_" .. TOKEN
			local scoped, scope_err = Contract.runtime_variable_name(logical_name, TOKEN)
			helpers.assert_nil(scope_err)
			helpers.assert_eq(scoped, expected)
			local parsed_logical, parsed_token = Contract.parse_runtime_variable_name(scoped)
			helpers.assert_eq(parsed_logical, logical_name)
			helpers.assert_eq(parsed_token, TOKEN)
			helpers.assert_true(Contract.is_runtime_variable_name(scoped))
			helpers.assert_true(Contract.is_managed_variable_name(scoped))
		end
	end)

	helpers.it("rejects foreign, malformed, and stock runtime-name candidates", function()
		for _, name in ipairs({
			"personal_layer",
			"system.use_fkeys_as_standard_function_keys",
			"ke_held_",
			"ke_held_Right-Command",
		}) do
			helpers.assert_true(not Contract.is_runtime_logical_name(name),
				name .. " must stay outside Ergopti runtime ownership")
			local scoped, err = Contract.runtime_variable_name(name, TOKEN)
			helpers.assert_nil(scoped)
			helpers.assert_true(type(err) == "string" and err ~= "")
		end
		for _, malformed in ipairs({
			"ergopti_layer_active_bad",
			"ergopti_capsword_" .. TOKEN:upper(),
			"ergopti_ke_held_right_command_" .. TOKEN:sub(1, 31),
		}) do
			helpers.assert_true(Contract.is_runtime_variable_namespace_name(malformed),
				"mistyped driver prefixes remain reserved")
			helpers.assert_true(not Contract.is_runtime_variable_name(malformed))
			helpers.assert_true(Contract.is_managed_variable_name(malformed))
		end
	end)

	helpers.it("recognizes the current and legacy reserved namespaces", function()
		helpers.assert_true(Contract.is_managed_variable_name("ergopti_mode_" .. TOKEN))
		helpers.assert_true(Contract.is_managed_variable_name("ergopti_revoked_" .. TOKEN))
		helpers.assert_true(Contract.is_managed_variable_name("ergopti_lease_" .. TOKEN))
		helpers.assert_true(Contract.is_managed_variable_name("ergopti_pause_" .. TOKEN))
		helpers.assert_true(not Contract.is_managed_variable_name("ergopti_modes_" .. TOKEN))
		helpers.assert_true(not Contract.is_managed_variable_name("xergopti_mode_" .. TOKEN))
		helpers.assert_true(not Contract.is_managed_variable_name(false))
	end)
end)
