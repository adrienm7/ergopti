--- tests/unit/hotstrings/engine/expander/llm_bridge/test_choke_point.lua

--- ==============================================================================
--- MODULE: llm_bridge injection choke-point regression test
--- DESCRIPTION:
--- Encodes the F-INFO-1 architectural invariant: every prediction replacement
--- MUST route through expander.perform_text_replacement(), the single
--- transaction that owns the Quartz tags, the logical log and the engine state.
---
--- RATIONALE:
--- The old version of this file read llm_bridge.lua and asserted that legacy
--- tracker assignments were absent from its text, which a renamed field or a
--- second emission route defeats. It now drives the real bridge with the choke
--- point replaced by a recorder that types nothing: whatever the bridge posts
--- or commits by itself then shows up as an event, a collected key or a buffer
--- change, so a second provenance path fails here whatever it is called.
--- ==============================================================================

local helpers = require("tests.helpers")
local ApplyFixture = require("tests.support.apply_prediction_fixture")




-- ==================================================================
-- ==================================================================
-- ======= 1/ Choke-Point Routing ===================================
-- ==================================================================
-- ==================================================================

--- Builds a choke point that records each call and leaves both callbacks unrun.
--- @return table expander Double exposing perform_text_replacement.
--- @return table calls Recorded calls.
local function recording_expander()
	local calls = {}
	local expander = {
		init = function() return true end,
		perform_text_replacement = function(deletes, emit, commit, is_final, is_ignored, owner)
			calls[#calls + 1] = {
				deletes = deletes,
				emit = emit,
				commit = commit,
				is_final = is_final,
				is_ignored = is_ignored,
				owner = owner,
			}
			return true, { id = "recorded-transaction" }
		end,
	}
	return expander, calls
end

helpers.describe("llm_bridge: F-INFO-1 injection choke point", function()

	helpers.it("hands the accepted prediction to expander.perform_text_replacement once", function()
		local expander, calls = recording_expander()
		local result = ApplyFixture.run({
			text = "world",
			buffer = "hello wor",
			deletes = 3,
			expander = expander,
		})
		helpers.assert_true(result.call_ok, "apply_prediction must not raise: " .. tostring(result.applied))
		helpers.assert_eq(result.applied, true, "a replacement the choke point accepted must be applied")
		helpers.assert_eq(#calls, 1, "the prediction must reach the choke point exactly once")
		helpers.assert_eq(calls[1].deletes, 3, "the choke point must receive the deletion count")
		helpers.assert_eq(type(calls[1].emit), "function", "the text must reach the choke point as its emitter")
		helpers.assert_eq(type(calls[1].commit), "function", "the buffer update must reach the choke point as its commit")
		helpers.assert_eq(calls[1].is_final, true, "an accepted prediction is final: no hotstring rescan")
		helpers.assert_eq(calls[1].is_ignored, true, "the chain signal, not the inactivity timer, follows an accept")
		helpers.assert_eq(calls[1].owner, "llm", "the transaction must name the LLM as its owner")
	end)


	helpers.it("posts no key and moves no buffer outside the choke point", function()
		local expander = recording_expander()
		local result = ApplyFixture.run({
			text = "world",
			buffer = "hello wor",
			deletes = 3,
			expander = expander,
		})
		helpers.assert_eq(result.applied, true, "the recorded replacement must be applied")
		helpers.assert_eq(#result.posted_events, 0,
			"a key posted while the choke point typed nothing is a second injection path")
		helpers.assert_eq(#(result.events or {}), 0,
			"a key collected while the choke point typed nothing is a second injection path")
		helpers.assert_eq(result.state.buffer, "hello wor",
			"only the choke point's commit may move the buffer; it was never run")
	end)


	helpers.it("types the prediction and moves the buffer when the choke point runs its callbacks", function()
		local expander, calls = recording_expander()
		local result = ApplyFixture.run({
			text = "world",
			buffer = "hello wor",
			deletes = 3,
			expander = expander,
		})
		helpers.assert_eq(#calls, 1, "the prediction must reach the choke point")
		calls[1].commit()
		helpers.assert_eq(result.state.buffer, "hello world",
			"the commit handed to the choke point must splice the accepted text into the buffer")
	end)


	helpers.it("rejects the prediction when the choke point refuses it", function()
		local result = ApplyFixture.run({ text = "world", buffer = "hello wor", deletes = 3, expander_failure = true })
		helpers.assert_true(result.call_ok, "a refused replacement must not raise")
		helpers.assert_eq(result.applied, false, "a replacement the choke point refused is not applied")
		helpers.assert_eq(#result.posted_events, 0, "a refused replacement must post nothing")
		helpers.assert_eq(result.accepted_count, 0, "a refused replacement must not be counted as accepted")
	end)

end)
