--- tests/unit/modules/gestures/test_scroll_block_respects_enabled.lua

--- ==============================================================================
--- MODULE: gestures.engine scroll-block enabled guard regression tests
--- DESCRIPTION:
--- Verifies that the 3-finger scroll-block activation in process_frame respects
--- the _state.enabled flag, so a paused/disabled gesture engine cannot swallow
--- scroll events.
---
--- FEATURES & RATIONALE:
--- 1. Source Invariant: the n >= 3 branch must reference _state.enabled so the
---    unconditional startScrollBlock() call that existed pre-fix cannot return.
--- 2. Pre-fix: `if n >= 3 then startScrollBlock() end` — no enabled check.
---    Post-fix: `if n >= 3 and _state and _state.enabled then startScrollBlock() end`.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ====================================================================================
-- ====================================================================================
-- ======= 1/ scroll-block n>=3 respects enabled flag (gestures-engine-scroll) =======
-- ====================================================================================
-- ====================================================================================

helpers.describe("gestures.engine scroll-block — respects enabled flag (gestures-engine-scroll regression)", function()

	helpers.it("source: the n >= 3 scroll-block branch contains _state.enabled guard", function()
		local src_path = helpers.driver_root() .. "modules/gestures/engine.lua"
		local fh = io.open(src_path, "r")
		helpers.assert_true(fh ~= nil, "gestures/engine.lua must be readable")
		local src = fh:read("*a"); fh:close()

		-- Locate the n >= 3 branch that calls startScrollBlock.
		local branch_pos = src:find("n >= 3 and _state and _state%.enabled", 1, false)
		helpers.assert_true(branch_pos ~= nil,
			"the n >= 3 startScrollBlock branch must contain '_state and _state.enabled' guard")

		-- Verify the guard precedes the call on the same line.
		local guarded_call = src:find("n >= 3 and _state and _state%.enabled then startScrollBlock", 1, false)
		helpers.assert_true(guarded_call ~= nil,
			"startScrollBlock() must be gated by the full 'n >= 3 and _state and _state.enabled' expression")
	end)

	helpers.it("source: stopScrollBlock() on n == 0 remains unconditional (guard must not be added there)", function()
		local src_path = helpers.driver_root() .. "modules/gestures/engine.lua"
		local fh = io.open(src_path, "r")
		helpers.assert_true(fh ~= nil)
		local src = fh:read("*a"); fh:close()

		-- The n == 0 branch must call stopScrollBlock() unconditionally so the block
		-- is always released when fingers lift, regardless of enabled state.
		-- We verify by finding stopScrollBlock at line context where n == 0 is checked.
		local n0_pos  = src:find("if n == 0 then", 1, true)
		local stop_pos = src:find("stopScrollBlock()", 1, true)
		helpers.assert_true(n0_pos ~= nil, "n == 0 branch must exist")
		helpers.assert_true(stop_pos ~= nil, "stopScrollBlock() must exist")
		helpers.assert_true(stop_pos > n0_pos,
			"stopScrollBlock() must appear after the n == 0 block begins")
		-- The stop call must not be behind an enabled guard.
		local guarded_stop = src:find("_state%.enabled.*stopScrollBlock", 1, false)
		helpers.assert_true(guarded_stop == nil,
			"stopScrollBlock() must NOT be guarded by _state.enabled — it must always release the block")
	end)

end)
