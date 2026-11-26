--- tests/unit/core/logger/engine/test_callback_accounting.lua

--- ==============================================================================
--- MODULE: Timer-callback accounting window
--- DESCRIPTION:
--- The field run's idle check failed its CPU budget on 2026-10-31 with nothing
--- to say which owner woke the app: the slow-callback report names only holds
--- of 250 ms and more. While an accounting window is open every guarded timer
--- callback is added to its site, so the check names the timers that ran
--- (idle-window-wakers).
--- ==============================================================================

local helpers = require("tests.helpers")

local NS_PER_MS = 1000000

helpers.describe("logger: timer-callback accounting window (idle-window-wakers)", function()
	helpers.it("(idle-window-wakers) counts each guarded callback by its site, only while a window is open", function()
		local saved_logger = package.loaded["core.logger.engine.logger"]
		package.loaded["core.logger.engine.logger"] = nil
		local Fresh = require("core.logger.engine.logger")
		helpers.admit_logger_privacy(Fresh)
		local hs = _G.hs
		local saved = { doAfter = hs.timer.doAfter, absoluteTime = hs.timer.absoluteTime, print = _G.print,
			new = hs.timer.new, doEvery = hs.timer.doEvery, execute = hs.execute,
			delayed_new = hs.timer.delayed and hs.timer.delayed.new or nil }
		local clock = { now = 0 }
		hs.timer.absoluteTime = function() return clock.now end
		hs.timer.doAfter = function(_delay, fn) if type(fn) == "function" then fn() end end
		local ok, err = pcall(function()
			Fresh.set_sink(function() end)
			Fresh.install_runtime_error_capture()
			local function cheap() clock.now = clock.now + 2 * NS_PER_MS end
			local function costly() clock.now = clock.now + 30 * NS_PER_MS end
			hs.timer.doAfter(0, cheap)
			Fresh.begin_callback_accounting()
			helpers.assert_true(not pcall(Fresh.begin_callback_accounting), "a second window is refused")
			for _ = 1, 3 do hs.timer.doAfter(0, cheap) end
			hs.timer.doAfter(0, costly)
			local sites = Fresh.end_callback_accounting()
			hs.timer.doAfter(0, costly)
			helpers.assert_eq(#sites, 2)
			helpers.assert_true(sites[1].site:find("test_callback_accounting.lua:", 1, true) ~= nil,
				"the site names the owner's function")
			helpers.assert_eq(sites[1].count, 1)
			helpers.assert_eq(math.floor(sites[1].ms + 0.5), 30)
			helpers.assert_eq(sites[2].count, 3, "the callback before the window is not counted")
			helpers.assert_eq(math.floor(sites[2].ms + 0.5), 6)
			helpers.assert_true(not pcall(Fresh.end_callback_accounting), "closing a closed window is refused")
		end)
		Fresh.set_sink(nil)
		hs.timer.doAfter, hs.timer.absoluteTime, _G.print = saved.doAfter, saved.absoluteTime, saved.print
		hs.timer.new, hs.timer.doEvery, hs.execute = saved.new, saved.doEvery, saved.execute
		if hs.timer.delayed then hs.timer.delayed.new = saved.delayed_new end
		package.loaded["core.logger.engine.logger"] = saved_logger
		if not ok then error(err, 0) end
	end)
end)
