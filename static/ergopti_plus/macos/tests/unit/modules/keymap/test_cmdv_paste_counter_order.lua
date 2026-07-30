--- tests/unit/modules/keymap/test_cmdv_paste_counter_order.lua

--- ==============================================================================
--- MODULE: Regression — Cmd+V paste-counter drain must precede the chars guard
--- DESCRIPTION:
--- Audit finding F-H1. In onKeyDownRaw's `if flags.cmd or flags.ctrl` branch the
--- early chars guard `if #expected_synthetic_chars > 0 then return false` ran
--- BEFORE the dedicated paste-counter drain. A terminator-expand-via-paste (a
--- long/unicode hotstring whose non-consumed space terminator is re-typed) arms
--- BOTH expected_synthetic_pastes (the Cmd+V echo) AND expected_synthetic_chars
--- (the terminator). The OS posts the Cmd+V echo first; the chars guard intercepted
--- it and returned WITHOUT decrementing expected_synthetic_pastes, leaving the
--- counter stuck at >0 so the user's NEXT genuine Cmd+V was silently swallowed.
---
--- Root cause = guard ORDER, so this test pins the order at source level (the
--- declaration-index of the paste drain must be BEFORE the chars guard within the
--- Cmd branch), per the audit's "assert the ordering, not that a line exists".
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("onKeyDownRaw drains the paste counter before the chars guard", function()
	helpers.it("paste-counter guard precedes the expected_synthetic_chars guard in the Cmd branch", function()
		-- Selected by a declaration unique to modules/keymap/init.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function invalidate_observed_context")
		helpers.assert_true(src ~= nil, "modules/keymap/init.lua source must be locatable")

		-- Locate the start of the Cmd/Ctrl branch that handles a Cmd keystroke.
		local branch = src:find("if flags%.cmd or flags%.ctrl then")
		helpers.assert_true(branch ~= nil, "could not find the 'flags.cmd or flags.ctrl' branch")

		-- First occurrence of each guard AFTER the branch start (the block's own copies).
		local paste_guard = src:find('keyCode == hs.keycodes.map["v"]', branch, true)
		local chars_guard = src:find("#CoreState.expected_synthetic_chars > 0", branch, true)

		helpers.assert_true(paste_guard ~= nil, "paste-counter (keyCode==v) guard missing in the Cmd branch")
		helpers.assert_true(chars_guard ~= nil, "expected_synthetic_chars guard missing in the Cmd branch")

		-- The root-cause assertion: the paste drain must come first, otherwise the
		-- chars guard masks it and the paste counter desyncs.
		helpers.assert_true(paste_guard < chars_guard,
			"the Cmd+V paste-counter drain must precede the expected_synthetic_chars guard")

		-- And the drain must actually decrement the counter (not just early-return).
		local decrement = src:find("CoreState.expected_synthetic_pastes = CoreState.expected_synthetic_pastes %- 1", branch)
		helpers.assert_true(decrement ~= nil and decrement < chars_guard,
			"the paste guard must decrement expected_synthetic_pastes before the chars guard")
	end)
end)
