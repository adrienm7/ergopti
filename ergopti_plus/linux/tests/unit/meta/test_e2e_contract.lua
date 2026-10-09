--- tests/unit/meta/test_e2e_contract.lua

--- ==============================================================================
--- MODULE: Linux E2E Corpus Contract Regression Tests
--- DESCRIPTION:
--- Proves the corpus is mandatory and that mutating each expected semantic field
--- produces a mismatch. LNX-038 previously passed without the corpus and accepted
--- either of two backspace counts instead of its exact portable expectation.
--- ==============================================================================

local helpers = require("tests.helpers")
local Contract = require("tests.e2e.contract")

local EXPECTED = {
	matched = true,
	replacement = "by the way",
	backspace_count = 3,
}
local RESULT = {
	replacement = "by the way",
	backspace_count = 3,
}

local function observation_by_field(expected, result)
	local fields = {}
	for _, observation in ipairs(Contract.observations(expected, result)) do
		fields[observation.field] = observation
	end
	return fields
end

helpers.describe("linux E2E contract: mandatory exact evidence", function()

	helpers.it("rejects a missing corpus instead of falling back to smoke vectors", function()
		local vectors, load_error = Contract.load_corpus("/__ergopti_missing_corpus__/vectors.json")

		helpers.assert_nil(vectors, "a missing corpus cannot produce an optional empty vector set")
		helpers.assert_contains(load_error, "cannot open corpus",
			"the mandatory input failure must be explicit")
	end)

	helpers.it("rejects a corpus below the checked vector floor", function()
		local valid, validation_error = Contract.validate_vectors({})

		helpers.assert_true(not valid, "an empty or partially discovered corpus must fail")
		helpers.assert_contains(validation_error, tostring(Contract.MIN_VECTOR_COUNT),
			"the stable floor must be part of the diagnosis")
	end)

	helpers.it("detects a mutated matched expectation", function()
		local mutated = { matched = false }
		local fields = observation_by_field(mutated, RESULT)

		helpers.assert_true(fields.matched.actual ~= fields.matched.expected,
			"changing expected.matched must fail its own oracle")
	end)

	helpers.it("detects a mutated replacement expectation", function()
		local mutated = {
			matched = true,
			replacement = "wrong",
			backspace_count = EXPECTED.backspace_count,
		}
		local fields = observation_by_field(mutated, RESULT)

		helpers.assert_true(fields.replacement.actual ~= fields.replacement.expected,
			"changing expected.replacement must fail its own oracle")
	end)

	helpers.it("detects a mutated backspace_count expectation", function()
		local mutated = {
			matched = true,
			replacement = EXPECTED.replacement,
			backspace_count = 999,
		}
		local fields = observation_by_field(mutated, RESULT)

		helpers.assert_true(fields.backspace_count.actual ~= fields.backspace_count.expected,
			"changing expected.backspace_count to 999 must fail, not match an alternative")
	end)

end)
