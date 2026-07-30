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
-- ===================================================================================
-- ======= 1/ scroll-block n>=3 respects enabled flag (gestures-engine-scroll) =======
-- ===================================================================================
-- ====================================================================================

helpers.describe("gestures.engine scroll-block — respects enabled flag (gestures-engine-scroll regression)", function()

	helpers.it("source: the n >= 3 scroll-block branch contains _state.enabled guard", function()
		-- Selected by a declaration unique to modules/gestures/engine.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function triggerLiveAxisIfNeeded")
		helpers.assert_true(src ~= nil, "modules/gestures/engine.lua source must be locatable")

		-- Locate the n >= 3 branch that calls startScrollBlock. The gate now also
		-- checks _state.suspended so a paused engine cannot activate scroll-block
		-- even if the user feature flag is true.
		local branch_pos = src:find("n >= 3 and _state and _state%.enabled and not _state%.suspended", 1, false)
		helpers.assert_true(branch_pos ~= nil,
			"the n >= 3 startScrollBlock branch must contain 'enabled and not suspended' guard")

		-- Verify the guard precedes the call on the same line.
		local guarded_call = src:find(
			"n >= 3 and _state and _state%.enabled and not _state%.suspended then startScrollBlock", 1, false)
		helpers.assert_true(guarded_call ~= nil,
			"startScrollBlock() must be gated by the full enabled+suspended expression")
	end)

	helpers.it("source: stopScrollBlock() on n == 0 remains unconditional (guard must not be added there)", function()
		-- Selected by a declaration unique to modules/gestures/engine.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function triggerLiveAxisIfNeeded")
		helpers.assert_true(src ~= nil, "modules/gestures/engine.lua source must be locatable")

		-- The n == 0 branch must call stopScrollBlock() unconditionally so the block
		-- is always released when fingers lift, regardless of enabled state.
		-- We verify by finding stopScrollBlock at line context where n == 0 is checked.
		-- NOTE: search from n0_pos, not from 1, because stopScrollBlock is also defined
		-- as a local function earlier in the file; we need the CALL SITE inside the block.
		local n0_pos  = src:find("if n == 0 then", 1, true)
		helpers.assert_true(n0_pos ~= nil, "n == 0 branch must exist")
		local stop_pos = src:find("stopScrollBlock()", n0_pos, true)
		helpers.assert_true(stop_pos ~= nil,
			"stopScrollBlock() must be called within the n == 0 block")
		-- The stop call must not be behind an enabled guard. Scan line by line to avoid
		-- Lua's cross-line '.' matching: we want to verify no SINGLE LINE has both
		-- _state.enabled and stopScrollBlock together.
		local guarded_stop_line = nil
		for line in src:gmatch("[^\n]+") do
			if line:find("_state%.enabled", 1, false) and line:find("stopScrollBlock", 1, true) then
				guarded_stop_line = line
				break
			end
		end
		helpers.assert_true(guarded_stop_line == nil,
			"stopScrollBlock() must NOT be on the same line as an _state.enabled check")
	end)

end)
