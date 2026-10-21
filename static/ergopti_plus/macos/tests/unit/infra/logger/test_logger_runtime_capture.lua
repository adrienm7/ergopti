--- tests/unit/infra/logger/test_logger_runtime_capture.lua

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




helpers.admit_logger_privacy(Logger)
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

	-- An uncaught error is an ERROR like any other for the error window: it used
	-- to be written through the private dispatcher, which skipped the handler, so
	-- the one error class a user can never see in a log opened no window either
	helpers.it("hands an uncaught timer error to the error handler, with its template (error-dialog-template)", function()
		package.loaded["infra.logger"] = nil
		local Fresh = require("infra.logger")
		helpers.admit_logger_privacy(Fresh)
		local hs = _G.hs
		local saved = {
			doAfter     = hs.timer.doAfter,
			doEvery     = hs.timer.doEvery,
			new         = hs.timer.new,
			delayed_new = hs.timer.delayed and hs.timer.delayed.new or nil,
			print       = _G.print,
		}
		hs.timer.doAfter = function(_delay, fn) if type(fn) == "function" then fn() end end
		local calls = {}
		Fresh.set_sink(function() end)
		Fresh.set_level("DEBUG")
		Fresh.set_error_notification_handler(function(module_name, message, template)
			calls[#calls + 1] = { module = module_name, message = message, template = template }
			return true
		end)
		Fresh.install_runtime_error_capture()
		pcall(function() hs.timer.doAfter(0, function() error("boom-for-the-window") end) end)
		Fresh.set_error_notification_handler(nil)
		Fresh.set_sink(nil)
		hs.timer.doAfter = saved.doAfter
		hs.timer.doEvery = saved.doEvery
		hs.timer.new     = saved.new
		if hs.timer.delayed then hs.timer.delayed.new = saved.delayed_new end
		_G.print = saved.print
		package.loaded["infra.logger"] = nil

		helpers.assert_eq(#calls, 1, "the uncaught timer error must reach the error handler")
		helpers.assert_eq(calls[1].module, "runtime")
		helpers.assert_eq(calls[1].template, "Uncaught error in hs.timer.%s callback: %s")
		helpers.assert_true(calls[1].message:find("boom-for-the-window", 1, true) ~= nil)
	end)

	-- A thrown object whose __tostring raises used to escape the guard through
	-- its own tostring() and reach Hammerspoon's console (timer-error-object-2026-10-21).
	helpers.it("contains a timer error object whose formatter raises (timer-error-object-2026-10-21)", function()
		package.loaded["infra.logger"] = nil
		local Fresh = require("infra.logger")
		helpers.admit_logger_privacy(Fresh)
		local hs = _G.hs
		local saved = {
			doAfter     = hs.timer.doAfter,
			doEvery     = hs.timer.doEvery,
			new         = hs.timer.new,
			delayed_new = hs.timer.delayed and hs.timer.delayed.new or nil,
			print       = _G.print,
		}
		hs.timer.doAfter = function(_delay, fn) if type(fn) == "function" then fn() end end
		local captured, formatted = {}, 0
		Fresh.set_sink(function(line) captured[#captured + 1] = line end)
		Fresh.set_level("DEBUG")
		Fresh.install_runtime_error_capture()
		local hostile = setmetatable({}, { __tostring = function()
			formatted = formatted + 1
			error(setmetatable({}, { __tostring = function() error("formatter failure") end }))
		end })
		local ok = pcall(function() hs.timer.doAfter(0, function() error(hostile) end) end)
		Fresh.set_sink(nil)
		hs.timer.doAfter = saved.doAfter
		hs.timer.doEvery = saved.doEvery
		hs.timer.new     = saved.new
		if hs.timer.delayed then hs.timer.delayed.new = saved.delayed_new end
		_G.print = saved.print
		package.loaded["infra.logger"] = nil

		helpers.assert_true(ok, "the guard must contain the object and its failing formatter")
		helpers.assert_eq(formatted, 0, "reporting must not run foreign formatting code")
		local found = false
		for _, line in ipairs(captured) do
			if line:find("Uncaught error", 1, true) and line:find("error object (table)", 1, true) then found = true end
		end
		helpers.assert_true(found, "the contained failure must still be logged")
	end)

	--- Installs a fresh capture over a scripted clock and runs `body`.
	--- @param body function Receives (Fresh, clock, captured).
	local function with_scripted_clock(body)
		package.loaded["infra.logger"] = nil
		local Fresh = require("infra.logger")
		helpers.admit_logger_privacy(Fresh)
		local hs = _G.hs
		local saved = {
			doAfter       = hs.timer.doAfter,
			doEvery       = hs.timer.doEvery,
			new           = hs.timer.new,
			delayed_new   = hs.timer.delayed and hs.timer.delayed.new or nil,
			absoluteTime  = hs.timer.absoluteTime,
			print         = _G.print,
		}
		local clock = { now = 0 }
		hs.timer.absoluteTime = function() return clock.now end
		hs.timer.doAfter = function(_delay, fn) if type(fn) == "function" then fn() end end
		local captured = {}
		Fresh.set_sink(function(line) captured[#captured + 1] = line end)
		Fresh.set_level("DEBUG")
		Fresh.install_runtime_error_capture()
		local ok, err = pcall(body, Fresh, clock, captured)
		Fresh.set_sink(nil)
		hs.timer.doAfter = saved.doAfter
		hs.timer.doEvery = saved.doEvery
		hs.timer.new     = saved.new
		hs.timer.absoluteTime = saved.absoluteTime
		if hs.timer.delayed then hs.timer.delayed.new = saved.delayed_new end
		_G.print = saved.print
		package.loaded["infra.logger"] = nil
		if not ok then error(err, 0) end
	end

	--- Counts captured lines that contain `needle`.
	local function count_lines(captured, needle)
		local count = 0
		for _, line in ipairs(captured) do
			if line:find(needle, 1, true) then count = count + 1 end
		end
		return count
	end

	-- Issue #99: one ingest flush held the main thread for 13.4 s. The taps were
	-- disabled and the lease lost its heartbeats, and no line named the callback
	-- (slow-timer-callback-report).
	helpers.it("names a timer callback that held the main thread (slow-timer-callback-report)", function()
		with_scripted_clock(function(_, clock, captured)
			local function slow_flush() clock.now = clock.now + 13400 * 1000000 end
			hs.timer.doAfter(0, slow_flush)
			helpers.assert_eq(count_lines(captured, "held the main thread for 13400 ms"), 1,
				"a 13.4 s hold must be reported with its duration")
			helpers.assert_eq(count_lines(captured, "test_logger_runtime_capture.lua:"), 1,
				"the report must name the callback's own source line")
			helpers.assert_eq(count_lines(captured, "[WARNING]"), 1)
		end)
	end)

	helpers.it("stays silent below a second and reports one site once a minute (slow-timer-callback-report)", function()
		with_scripted_clock(function(_, clock, captured)
			local function quick() clock.now = clock.now + 900 * 1000000 end
			hs.timer.doAfter(0, quick)
			helpers.assert_eq(count_lines(captured, "held the main thread"), 0,
				"a hold under a second disables no tap and must not be reported")
			local hold_ms = 2000
			local function slow() clock.now = clock.now + hold_ms * 1000000 end
			hs.timer.doAfter(0, slow)
			hs.timer.doAfter(0, slow)
			helpers.assert_eq(count_lines(captured, "held the main thread"), 1,
				"a site that stalls on every tick must not write a line per tick")
			clock.now = clock.now + 61 * 1000 * 1000000
			-- Another duration, since the logger folds an identical repeated line.
			hold_ms = 2500
			hs.timer.doAfter(0, slow)
			helpers.assert_eq(count_lines(captured, "held the main thread"), 2,
				"the same site is reported again after a minute")
		end)
	end)

	helpers.it("names the owner's callback behind the timer scheduler's closure (slow-timer-callback-report)", function()
		with_scripted_clock(function(_, clock, captured)
			local function owner_callback() clock.now = clock.now + 5000 * 1000000 end
			-- A closure compiled under the scheduler's chunk name stands for its wrapper.
			local wrapper = load("local cb = ...; return function() cb() end",
				"@adapters/timer_scheduler.lua")(owner_callback)
			hs.timer.doAfter(0, wrapper)
			helpers.assert_eq(count_lines(captured, "timer_scheduler.lua"), 0,
				"the scheduler's own wrapper names no owner")
			helpers.assert_eq(count_lines(captured, "test_logger_runtime_capture.lua:"), 1,
				"the report must resolve the owner's callback")
		end)
	end)
end)
