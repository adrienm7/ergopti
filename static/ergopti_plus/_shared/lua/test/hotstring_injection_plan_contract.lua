--- _shared/lua/test/hotstring_injection_plan_contract.lua

--- ==============================================================================
--- MODULE: Hotstring Injection Plan Contract
--- DESCRIPTION:
--- Replays _shared/tests/corpus/hotstrings/injection_plan_vectors.json through
--- `hotstring_engine.injection_plan` on macOS and Linux: what to erase, what to
--- type, which terminator to replay and what the buffer holds afterwards. The
--- driver-specific engines are tied to the same plan by their own suites
--- (family_samples, sequence_vectors, cascade_vectors); this file pins the plan.
--- ==============================================================================

--- Maps the lossless JSON null to nil.
local function plain(Json, value)
	if Json.is_null(value) then return nil end
	return value
end

--- Registers the vector replay and the refusals.
--- @param helpers table Driver test helpers.
--- @param corpus table The decoded corpus (Json.decode_lossless).
--- @param expected_count number The vector count the contract was written for.
return function(helpers, corpus, expected_count)
	local Json = require("json")
	local Plan = require("hotstring_engine.injection_plan")
	assert(#corpus.vectors == expected_count,
		"injection_plan_vectors.json holds " .. #corpus.vectors .. " vectors, the contract expects " .. expected_count)

	helpers.describe("shared hotstring injection plan vectors", function()
		for _, vector in ipairs(corpus.vectors) do
			helpers.it(vector.id, function()
				local input = vector.input
				local cascade = input.cascade
				if cascade ~= nil then
					cascade = {
						replacement = cascade.replacement, trigger_len = cascade.trigger_len,
						tail = plain(Json, cascade.tail), final_result = cascade.final_result,
					}
				end
				local plan = Plan.build({
					path = input.path, trigger_len = input.trigger_len, event_len = input.event_len,
					event_on_screen = input.event_on_screen, nbsp_stripped = input.nbsp_stripped,
					replacement = input.replacement, terminator = input.terminator,
					consume_terminator = input.consume_terminator, final_result = input.final_result,
					cascade = cascade,
				})
				local expect = vector.expect
				helpers.assert_eq(plan.erase, expect.erase, "erase")
				helpers.assert_eq(plan.text, expect.text, "text")
				helpers.assert_eq(plan.tail, plain(Json, expect.tail), "tail")
				helpers.assert_eq(plan.replay, plain(Json, expect.replay), "replay")
				helpers.assert_eq(plan.buffer_suffix, expect.buffer_suffix, "buffer suffix")
				helpers.assert_eq(plan.final_result, expect.final_result, "final result")
			end)
		end
	end)

	helpers.describe("hotstring injection plan refusals", function()
		helpers.it("refuses an unknown path and a malformed length", function()
			helpers.assert_true(not pcall(Plan.erase_count, { path = "x", trigger_len = 1, event_len = 1, event_on_screen = true }), "refused")
			helpers.assert_true(not pcall(Plan.erase_count, { path = "auto", trigger_len = -1, event_len = 1, event_on_screen = true }), "refused")
			helpers.assert_true(not pcall(Plan.erase_count, { path = "auto", trigger_len = 1, event_len = 1 }), "refused")
			helpers.assert_true(not pcall(Plan.build, { path = "auto", trigger_len = 1, event_len = 1, event_on_screen = true }), "refused")
		end)
	end)
end
