--- tests/unit/modules/keymap/test_apply_prediction_paste_ops.lua

--- ==============================================================================
--- MODULE: apply_prediction clipboard batch regression
--- DESCRIPTION:
--- Drives a paste-sized completion through the real keymap emitter and
--- SyntheticInput collector. The contract is the tagged Cmd+V pair and logical
--- buffer, not the removed expected_synthetic_pastes compatibility counter.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.apply_prediction_fixture")


helpers.describe("apply_prediction: clipboard text uses one tagged callback batch", function()
	helpers.it("returns Cmd+V provenance while preserving the logical completion", function()
		local completion = ("p"):rep(60)
		local result = fixture.run({ text = completion, buffer = "prefix " })

		helpers.assert_true(result.call_ok,
			"the clipboard acceptance path must not throw in the eventtap")
		helpers.assert_eq(result.applied, true,
			"a constructed clipboard replacement must report success")
		helpers.assert_eq(result.consume, true)
		helpers.assert_type(result.events, "table",
			"the callback must return the paste key pair")
		helpers.assert_eq(#result.events, 2,
			"a long completion is one tagged Cmd+V down/up pair, not sixty echoes")
		helpers.assert_eq(result.events[1].key, "v")
		helpers.assert_eq(result.events[2].key, "v")
		helpers.assert_eq(result.events[1].mods[1], "cmd")
		helpers.assert_eq(result.clipboard_writes[1], completion,
			"the pasteboard payload must equal the accepted logical completion")
		helpers.assert_eq(result.state.buffer, "prefix " .. completion,
			"the buffer must include clipboard text even though it emits no text key pairs")
		helpers.assert_eq(result.accepted_count, 1)
		helpers.assert_eq(result.notified_count, 1)
		helpers.assert_eq(result.arm_chain_count, 1)

		helpers.assert_nil(result.state.expected_synthetic_pastes,
			"paste ownership comes from immutable event tags, not a mutable counter")
		helpers.assert_nil(result.state.expected_synthetic_chars)
		helpers.assert_nil(result.state.expected_synthetic_deletes)

		for index, event in ipairs(result.events) do
			local metadata = result.provenance.classify(event, "apply-paste-test")
			helpers.assert_not_nil(metadata,
				"both Cmd+V phases must carry replacement provenance")
			helpers.assert_eq(metadata.owner, "llm")
			helpers.assert_eq(metadata.effect, "replacement")
			helpers.assert_eq(metadata.ordinal, 1)
			helpers.assert_eq(metadata.phase, index == 1 and "down" or "up")
		end
	end)
end)
