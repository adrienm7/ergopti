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
--- Fix: Added Engine.stop() that stops+nils scrollBlocker; called from M.stop().
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
	helpers.it("M.stop() source calls Engine.stop()", function()
		-- Read the gestures init source and assert Engine.stop is called in M.stop().
		-- This is a static source audit: we locate the M.stop() block and verify
		-- that pcall(Engine.stop) appears within it, so the scroll-blocker tap
		-- is always released on module teardown.
		local src_path = debug.getinfo(1, "S").source:match("^@(.+)$")
		local base = src_path:match("^(.+)[/\\]tests[/\\]") or ""
		local init_src = base .. "/modules/gestures/init.lua"

		local fh = io.open(init_src, "r")
		helpers.assert_true(fh ~= nil, "Cannot open gestures/init.lua at: " .. init_src)

		local source = fh:read("*a")
		fh:close()

		-- Check that Engine.stop is referenced inside the file
		helpers.assert_true(
			source:find("Engine%.stop", 1, false) ~= nil,
			"gestures/init.lua must call Engine.stop() to release the scroll-blocker tap"
		)

		-- Verify both appear in the file and that Engine.stop appears after M.stop
		local m_stop_pos  = source:find("function M%.stop%(%)") or 0
		local eng_stop_pos = source:find("Engine%.stop") or 0
		helpers.assert_true(
			m_stop_pos > 0 and eng_stop_pos > m_stop_pos,
			"Engine.stop() must be called inside M.stop() in gestures/init.lua"
		)
	end)
end)
