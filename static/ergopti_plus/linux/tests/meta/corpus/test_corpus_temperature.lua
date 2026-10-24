--- tests/meta/corpus/test_corpus_temperature.lua

--- ==============================================================================
--- MODULE: Diversity Temperature Corpus Consumer (Linux)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/llm/temperature_vectors.json through the shared
--- algorithm (_shared/lua/llm/temperature.lua), then proves the Linux engine's
--- entry point, Inference.variant_temperature, answers what the shared
--- algorithm answers for the shipped inference.json policy.
---
--- ROOT CAUSE ENCODED:
--- The step-and-floor algorithm was typed three times, in AutoHotkey, in the
--- macOS api_common and in the Linux inference policy, and the Linux copy had
--- no test at all, so its drift from the other two would have gone unseen.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local SHARED = helpers.driver_root() .. "/../_shared/"
local TOLERANCE = 1e-9

--- Reads and decodes one shared file.
--- @param relative string Path under _shared/.
--- @return table decoded
local function read_json(relative)
	local fh = assert(io.open(SHARED .. relative, "r"), "cannot open " .. relative)
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

helpers.describe("temperature corpus: the shared diversity temperature on Linux", function()
	local corpus = read_json("tests/corpus/llm/temperature_vectors.json")
	local shipped = read_json("modules/llm/inference.json").diversity_temperature
	local Temperature = helpers.load_module("llm.temperature")
	local Inference = helpers.load_module("modules.llm.inference")

	helpers.it("the corpus holds the base thresholds, the floor and the clamp", function()
		helpers.assert_true(#corpus.vectors >= 12, "vectors")
		helpers.assert_eq(Temperature.validate(corpus.policy), corpus.policy)
	end)

	for _, vector in ipairs(corpus.vectors) do
		helpers.it("temperature vector '" .. vector.id .. "'", function()
			assert_close(Temperature.variant(corpus.policy, vector.base, vector.index, vector.step),
				vector.expected, vector.id)
			-- The engine never passes a step of its own: the base chooses it.
			if vector.step == nil then
				assert_close(Inference.variant_temperature(vector.base, vector.index),
					Temperature.variant(shipped, vector.base, vector.index),
					vector.id .. " through Inference with the shipped policy")
			end
		end)
	end

	helpers.it("a policy missing a key is refused, not defaulted", function()
		local partial = {}
		for key, value in pairs(corpus.policy) do partial[key] = value end
		partial.step_default = nil
		local ok, err = pcall(Temperature.variant, partial, 0.5, 2)
		helpers.assert_eq(ok, false, "an incomplete policy must raise")
		helpers.assert_contains(tostring(err), "step_default")
	end)
end)
