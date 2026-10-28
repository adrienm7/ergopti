--- tests/unit/modules/llm/vectors/test_temperature_vectors.lua

--- ==============================================================================
--- MODULE: Diversity Temperature Corpus (macOS)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/llm/temperature_vectors.json through the shared
--- algorithm (_shared/lua/llm/temperature.lua), then proves the macOS backends'
--- entry point, ApiCommon.get_diversity_temperature, answers what the shared
--- algorithm answers for the shipped inference.json policy.
---
--- ROOT CAUSE ENCODED:
--- The step-and-floor algorithm was typed three times, in AutoHotkey, in the
--- macOS api_common and in the Linux inference policy, with constants shared
--- and nothing pinning the rule itself, so a change to one copy would drift
--- from the other two unnoticed.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")
local ApiCommon = helpers.load_with_stubs("modules.llm.api_common")
local Temperature = require("llm.temperature")

local TOLERANCE = 1e-9

--- Reads and decodes one shared file.
--- @param relative string Path under _shared/.
--- @return table decoded
local function read_json(relative)
	local fh = assert(io.open(helpers.shared(relative), "r"), "cannot open " .. relative)
	local raw = fh:read("*a")
	fh:close()
	return assert(Json.decode(raw), relative .. " is not valid JSON")
end

--- Asserts two temperatures agree within the corpus tolerance.
--- @param actual number
--- @param expected number
--- @param label string
local function assert_close(actual, expected, label)
	helpers.assert_true(type(actual) == "number" and math.abs(actual - expected) < TOLERANCE,
		string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)))
end

helpers.describe("diversity temperature corpus (macOS)", function()
	local corpus = read_json("tests/corpus/llm/temperature_vectors.json")
	local shipped = read_json("modules/llm/inference.json").diversity_temperature

	helpers.it("the corpus holds the base thresholds, the floor and the clamp", function()
		helpers.assert_true(#corpus.vectors >= 12, "vectors")
		helpers.assert_eq(Temperature.validate(corpus.policy), corpus.policy)
	end)

	for _, vector in ipairs(corpus.vectors) do
		helpers.it("vector '" .. vector.id .. "'", function()
			assert_close(Temperature.variant(corpus.policy, vector.base, vector.index, vector.step),
				vector.expected, vector.id)
			assert_close(ApiCommon.get_diversity_temperature(vector.base, vector.index, vector.step),
				Temperature.variant(shipped, vector.base, vector.index, vector.step),
				vector.id .. " through ApiCommon with the shipped policy")
		end)
	end

	helpers.it("a policy missing a key is refused, not defaulted", function()
		local partial = {}
		for key, value in pairs(corpus.policy) do partial[key] = value end
		partial.effective_base_floor = nil
		local ok, err = pcall(Temperature.variant, partial, 0.1, 2)
		helpers.assert_eq(ok, false, "an incomplete policy must raise")
		helpers.assert_contains(tostring(err), "effective_base_floor")
	end)
end)
