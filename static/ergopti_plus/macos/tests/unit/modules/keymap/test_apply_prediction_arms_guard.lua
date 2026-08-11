--- tests/unit/modules/keymap/test_apply_prediction_arms_guard.lua

--- ==============================================================================
--- MODULE: apply_prediction callback collector regression
--- DESCRIPTION:
--- The legacy test asserted timestamp/counter ordering that no longer exists.
--- This behavioral replacement drives the real bridge, expander, text emitter,
--- and SyntheticInput callback collector, then verifies the actual tagged Quartz
--- batch returned to Hammerspoon for the direct-keystroke path.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.apply_prediction_fixture")


helpers.describe("apply_prediction: direct text uses one tagged callback batch", function()
	helpers.it("returns the replacement keystrokes and reports acceptance", function()
		local result = fixture.run({ text = "ok", buffer = "prefix " })

		helpers.assert_true(result.call_ok,
			"apply_prediction must not throw inside the eventtap callback")
		helpers.assert_eq(result.applied, true,
			"a constructed direct-text replacement must report success")
		helpers.assert_eq(result.consume, true,
			"the validation key is consumed only after replacement output is accepted")
		helpers.assert_type(result.events, "table",
			"the callback must return the replacement event batch to Quartz")
		helpers.assert_eq(#result.events, 4,
			"two characters must produce exactly two tagged key pairs")
		helpers.assert_eq(result.state.buffer, "prefix ok",
			"the logical buffer must describe the text in the returned batch")
		helpers.assert_eq(result.accepted_count, 1,
			"successful output must emit exactly one LLM acceptance record")
		helpers.assert_eq(result.notified_count, 1,
			"the keylogger must be notified once for the logical replacement")
		helpers.assert_eq(result.arm_chain_count, 1,
			"the next-prediction chain is armed only after replacement acceptance")

		helpers.assert_nil(result.state.expected_synthetic_chars,
			"the migrated path must not recreate the removed character ledger")
		helpers.assert_nil(result.state.expected_synthetic_deletes,
			"the migrated path must not recreate the removed deletion ledger")
		helpers.assert_nil(result.state.last_synthetic_arm_time,
			"immutable provenance replaces the legacy timing guard")

		for index, event in ipairs(result.events) do
			local metadata = result.provenance.classify(event, "apply-keystroke-test")
			helpers.assert_not_nil(metadata,
				"every returned event must carry Ergopti synthetic provenance")
			helpers.assert_eq(metadata.owner, "llm")
			helpers.assert_eq(metadata.effect, "replacement")
			helpers.assert_eq(metadata.loopback, false)
			helpers.assert_eq(metadata.ordinal, math.ceil(index / 2))
			helpers.assert_eq(metadata.phase, index % 2 == 1 and "down" or "up")
		end

		helpers.assert_eq(result.events[1]:getUnicodeString(), "o")
		helpers.assert_eq(result.events[3]:getUnicodeString(), "k")
	end)

	helpers.it("returns false and no batch when the engine has no prediction", function()
		local result = fixture.run({
			text = "unused",
			buffer = "prefix ",
			no_prediction = true,
		})

		helpers.assert_true(result.call_ok)
		helpers.assert_eq(result.applied, false,
			"an invalid prediction index must remain a non-acceptance")
		helpers.assert_eq(result.consume, false,
			"without a prediction the validation key must pass through")
		helpers.assert_nil(result.events)
		helpers.assert_eq(result.state.buffer, result.buffer_before)
		helpers.assert_eq(result.accepted_count, 0)
		helpers.assert_eq(result.arm_chain_count, 0)
		helpers.assert_eq(result.synthetic.stats().active_transactions, 0)
		helpers.assert_eq(result.synthetic.stats().records, 0)
	end)

	for _, case in ipairs({
		{ name = "throw", options = { overlap_error = true } },
		{ name = "nil", options = { overlap_nil = true } },
	}) do
		helpers.it("rejects output when overlap resolution returns " .. case.name, function()
			local result = fixture.run({
				text = "texte",
				buffer = "Je tex",
				overlap_error = case.options.overlap_error,
				overlap_nil = case.options.overlap_nil,
			})

			helpers.assert_true(result.call_ok,
				"overlap failure must be contained before the eventtap boundary")
			helpers.assert_eq(result.applied, false,
				"unsafe unnormalised text must not be accepted")
			helpers.assert_eq(result.consume, false)
			helpers.assert_nil(result.events,
				"no deletion or text event may escape after overlap resolution failed")
			helpers.assert_eq(result.state.buffer, result.buffer_before)
			helpers.assert_eq(result.accepted_count, 0)
			helpers.assert_eq(result.arm_chain_count, 0)
			helpers.assert_eq(result.reset_count, 1,
				"the prediction consumed before normalisation must be cleaned up")
	end)
	end

	for _, case in ipairs({
		{ name = "false", value = false },
		{ name = "nil", value = function() return nil end },
	}) do
		helpers.it("commits accepted text without chaining when native reset returns " .. case.name, function()
			local result = fixture.run({
				text = "ok",
				buffer = "prefix ",
				reset_result = case.value,
			})

			helpers.assert_true(result.call_ok)
			helpers.assert_eq(result.applied, true,
				"a cleanup refusal after the logical fence must not eat accepted text")
			helpers.assert_eq(result.consume, true)
			helpers.assert_eq(#result.events, 4)
			helpers.assert_eq(result.state.buffer, "prefix ok")
			helpers.assert_eq(result.accepted_count, 1)
			helpers.assert_eq(result.arm_chain_count, 0,
				"no new request may chain behind cleanup that did not commit")
			helpers.assert_eq(result.reset_count, 1)
			helpers.assert_eq(result.timer_delta, 2,
				"the normal replacement deferral plus one cleanup retry must remain owned")
		end)
	end

	helpers.it("contains a reset throw and commits already-fenced text without chaining", function()
		local result = fixture.run({
			text = "ok",
			buffer = "prefix ",
			reset_result = function() error("RESET_THROW") end,
		})

		helpers.assert_true(result.call_ok,
			"reset failure must be contained before the callback collector aborts")
		helpers.assert_eq(result.applied, true)
		helpers.assert_eq(result.consume, true)
		helpers.assert_eq(#result.events, 4)
		helpers.assert_eq(result.state.buffer, "prefix ok")
		helpers.assert_eq(result.accepted_count, 1)
		helpers.assert_eq(result.arm_chain_count, 0)
		helpers.assert_eq(result.timer_delta, 2)
	end)

	for _, case in ipairs({
		{ name = "false", value = false },
		{ name = "nil", value = function() return nil end },
		{ name = "throw", value = function() error("ARM_THROW") end },
	}) do
		helpers.it("keeps accepted text committed when chain arm returns " .. case.name, function()
			local result = fixture.run({
				text = "ok",
				buffer = "prefix ",
				arm_chain_result = case.value,
			})

			helpers.assert_true(result.call_ok,
				"post-output chain failure must never abort the collected text batch")
			helpers.assert_eq(result.applied, true)
			helpers.assert_eq(result.consume, true)
			helpers.assert_eq(#result.events, 4)
			helpers.assert_eq(result.state.buffer, "prefix ok")
			helpers.assert_eq(result.accepted_count, 1)
			helpers.assert_eq(result.arm_chain_count, 1)
			helpers.assert_eq(result.timer_delta, 1,
				"F16 must not be emitted when no fallback chain owner exists")
		end)
	end

	helpers.it("does not leak a partial text_utils stub to later tests", function()
		fixture.run({ text = "x", buffer = "" })
		package.loaded["infra.text_utils"] = nil
		local real_text_utils = helpers.load_with_stubs("infra.text_utils")

		helpers.assert_type(real_text_utils, "table")
		helpers.assert_type(real_text_utils.utf8_len, "function",
			"fixture teardown must leave the real utf8_len loadable")
		helpers.assert_type(real_text_utils.repl_title, "function",
			"fixture teardown must leave the full text_utils surface loadable")
	end)
end)
