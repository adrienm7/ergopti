--- tests/unit/modules/keymap/test_apply_prediction_own_acceptance.lua

--- ==============================================================================
--- MODULE: apply_prediction hands a self-applying candidate to its owner
--- DESCRIPTION:
--- The translation of the selection (llm_translate_selection) offers a
--- candidate whose acceptance REPLACES the selection through the text
--- pipeline instead of typing at the caret. The keymap bridge must hand its
--- text to the candidate's on_accept, close the tooltip, and neither type,
--- erase, change the buffer, record an accepted prediction nor chain a request.
---
--- ROOT CAUSE ENCODED:
--- apply_prediction typed every accepted candidate at the caret: a translation
--- would have been inserted next to the selection instead of replacing it.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.apply_prediction_fixture")

--- Runs an acceptance of a candidate with its own acceptance.
--- @param outcome any What on_accept returns, or "raise" to throw.
--- @return table result, table calls
local function run(outcome)
	local calls = {}
	local result = fixture.run({
		buffer = "prefix ",
		prediction = {
			deletes = 0, to_type = "See you tomorrow?", verbatim = true,
			on_accept = function(text)
				calls[#calls + 1] = text
				if outcome == "raise" then error("owner failure") end
				return outcome
			end,
		},
	})
	return result, calls
end

--- Counts the key-down events that typed or erased something.
--- @param result table
--- @return number
local function typed_events(result)
	local count = 0
	for _, event in ipairs(result.events or {}) do
		if event.isDown == true then count = count + 1 end
	end
	return count
end

helpers.describe("apply_prediction: a candidate that applies itself", function()
	helpers.it("hands the text to its owner and types nothing at the caret", function()
		local result, calls = run(true)
		helpers.assert_true(result.call_ok, "no Lua error escapes")
		helpers.assert_eq(result.applied, true)
		helpers.assert_eq(#calls, 1, "the owner is called once")
		helpers.assert_eq(calls[1], "See you tomorrow?", "with the candidate's text")
		helpers.assert_eq(typed_events(result), 0, "nothing is typed or erased at the caret")
		helpers.assert_eq(#result.clipboard_writes, 0, "nothing is pasted by the bridge")
		helpers.assert_eq(result.state.buffer, result.buffer_before, "the typed buffer is left alone")
		helpers.assert_true(result.reset_count >= 1, "the tooltip is closed")
		helpers.assert_eq(result.accepted_count, 0, "no accepted prediction is recorded")
		helpers.assert_eq(result.arm_chain_count, 0, "no request is chained")
	end)

	helpers.it("reports a refusal or a failure of the owner as not applied", function()
		local refused, refused_calls = run(false)
		helpers.assert_eq(refused.applied, false)
		helpers.assert_eq(#refused_calls, 1)
		helpers.assert_eq(typed_events(refused), 0)

		local raised = run("raise")
		helpers.assert_true(raised.call_ok, "the owner's error is contained")
		helpers.assert_eq(raised.applied, false)
		helpers.assert_eq(typed_events(raised), 0)
	end)
end)
