--- tests/unit/modules/gestures/test_engine_stop_releases_scroll_blocker.lua

--- ==============================================================================
--- MODULE: Regression — Engine.stop() releases the scroll-blocker eventtap
--- DESCRIPTION:
--- Guards against the bug where Engine had no stop() function: every Hammerspoon
--- reload created a new scrollBlocker eventtap via Engine.init() without stopping
--- the previous one, so N reloads left N concurrent scroll eventtaps running.
---
--- Root cause (2026-06-19): scrollBlocker was a file-local variable with no
--- teardown path. Engine.init() guards with `if not scrollBlocker` — but because
--- the module table is cached by require(), re-require returns the same module.
--- The real problem is that gestures/init.lua M.stop() never called Engine.stop().
---
--- Fix: Added Engine.stop() that stops+nils scrollBlocker; the shared exact
--- teardown helper calls it, and M.stop() delegates to that helper.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ===========================================================
-- ===========================================================
-- ======= 1/ Engine exposes a stop() function ===============
-- ===========================================================
-- ===========================================================

helpers.describe("Engine.stop(): contract", function()
	helpers.it("Engine module exports a stop() function", function()
		local Engine = helpers.load_with_stubs("modules.gestures.engine")
		helpers.assert_true(
			type(Engine.stop) == "function",
			"Engine must export stop() so gestures/init.lua M.stop() can call it"
		)
	end)
end)




-- ===========================================================
-- ===========================================================
-- ======= 2/ gestures init M.stop() calls Engine.stop() ====
-- ===========================================================
-- ===========================================================

helpers.describe("gestures init M.stop(): tears down engine", function()
	helpers.it("M.stop() delegates to the helper that stops Engine", function()
		local source = helpers.read_driver_source("local function schedule_emergency_recycle")
		helpers.assert_true(source ~= nil and source ~= "",
			"modules/gestures/init.lua source must be locatable")
		local teardown_pos = source:find("teardown_gesture_runtime = function", 1, true)
		local teardown_end = teardown_pos
			and source:find("\nlocal function reject_gesture_start", teardown_pos, true)
		local m_stop_pos = source:find("function M.stop()", 1, true)
		local m_stop_end = m_stop_pos and source:find("\nfunction M.diagnose()", m_stop_pos, true)
		helpers.assert_true(teardown_pos ~= nil and teardown_end ~= nil
			and m_stop_pos ~= nil and m_stop_end ~= nil,
			"the shared teardown and public stop entry point must remain bounded")

		local teardown = source:sub(teardown_pos, teardown_end - 1)
		local stop_body = source:sub(m_stop_pos, m_stop_end - 1)
		helpers.assert_true(
			teardown:find("xpcall(Engine.stop, debug.traceback)", 1, true) ~= nil,
			"the shared gesture teardown must stop Engine to release the scroll blocker")
		helpers.assert_true(
			stop_body:find("teardown_gesture_runtime(false)", 1, true) ~= nil,
			"M.stop() must route through the exact teardown that owns Engine.stop")
	end)
end)
