--- tests/unit/lib/test_logger_runtime_capture.lua

--- ==============================================================================
--- MODULE: Logger Runtime Error Capture — regression
--- DESCRIPTION:
--- Locks down M.install_runtime_error_capture(): a Lua error thrown inside an
--- hs.timer callback must be LOGGED (so it reaches the unified file log) instead
--- of vanishing into the Hammerspoon Console. This is the failure class that
--- silently killed predictions (the dangling StreamingHandler.ngram_predict
--- call) and the LLM boot sequence — Hammerspoon swallows callback throws whole,
--- and the console is too noisy to read and cannot be exported, so the file log
--- has to be self-sufficient.
---
--- FEATURES & RATIONALE:
--- 1. Fresh module instance: package.loaded is reset so the one-shot install
---    guard starts false and the wrap is actually applied for the assertion.
--- 2. Synchronous drive: the hs stub records timers without firing them, so the
---    test overrides doAfter to invoke its callback inline, exercising the guard.
--- 3. Full restore: every global the install mutates (hs.timer.*, print) is
---    saved and restored so the wrap never leaks into other test files.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.logger"] = nil
local Logger = require("infra.logger")




-- ===================================================
-- ===================================================
-- ======= 1/ Timer-callback error capture ===========
-- ===================================================
-- ===================================================

helpers.describe("logger — runtime error capture", function()
	helpers.it("exposes install_runtime_error_capture", function()
		helpers.assert_eq(type(Logger.install_runtime_error_capture), "function")
	end)

	helpers.it("logs uncaught errors thrown inside hs.timer callbacks (so they land in the file, not just the Console)", function()
		local hs = _G.hs
		local saved = {
			doAfter     = hs.timer.doAfter,
			doEvery     = hs.timer.doEvery,
			new         = hs.timer.new,
			delayed_new = hs.timer.delayed and hs.timer.delayed.new or nil,
			print       = _G.print,
			level       = Logger.current_level,
		}

		-- The stub records timers without firing them; drive the callback inline
		-- so the installed guard's xpcall actually runs.
		hs.timer.doAfter = function(_delay, fn) if type(fn) == "function" then fn() end end

		local captured = {}
		Logger.set_sink(function(line) captured[#captured + 1] = line end)
		Logger.set_level("DEBUG")

		Logger.install_runtime_error_capture()

		-- A throwing timer callback must be swallowed by the guard (no propagation)
		-- AND logged so the traceback reaches the file log.
		local ok = pcall(function()
			hs.timer.doAfter(0, function() error("boom-in-timer") end)
		end)

		-- Restore every global the install mutated + test-only state.
		Logger.set_sink(nil)
		Logger.current_level = saved.level
		hs.timer.doAfter = saved.doAfter
		hs.timer.doEvery = saved.doEvery
		hs.timer.new     = saved.new
		if hs.timer.delayed then hs.timer.delayed.new = saved.delayed_new end
		_G.print = saved.print

		helpers.assert_true(ok, "a throwing timer callback must be swallowed by the guard, not propagated to the runloop")

		local found = false
		for _, line in ipairs(captured) do
			if line:find("Uncaught error", 1, true) and line:find("boom-in-timer", 1, true) then
				found = true
				break
			end
		end
		helpers.assert_true(found, "the timer-callback error must be logged so it reaches the file log")
	end)
end)
