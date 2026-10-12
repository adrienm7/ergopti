--- tests/unit/lib/test_logger_repeat_collapsing.lua

--- ==============================================================================
--- MODULE: Logger Repeat Collapsing — macOS Ownership
--- DESCRIPTION:
--- The shared corpus pins WHAT repeat collapsing emits. This file pins what the
--- macOS driver owns around it: arming exactly once with a committed periodic
--- tick, the tick closing a streak that fell silent, a refused tick leaving the
--- layer disarmed, the exit/reload drain carrying pending summaries, and root
--- init.lua arming it once the native sink owns the file.
---
--- ROOT CAUSE ENCODED:
--- A periodic source with changing counters (the gestures health check, the
--- lease heartbeat) filled the daily log with thousands of near-identical lines,
--- because the only suppression matched byte-identical consecutive lines. A
--- collapser that is never armed, never flushed on a timer, or never flushed at
--- exit brings the flood back or loses the counts, silently.
--- ==============================================================================

local helpers = require("tests.helpers")
local Logger  = require("infra.logger")
helpers.admit_logger_privacy(Logger)
local Timings = require("infra.timings")





-- ==========================
-- ==========================
-- ======= 1/ Fixture =======
-- ==========================
-- ==========================

--- A TimerScheduler double that records every timer and never fires one.
--- @param refuse boolean|nil True to report the tick as not committed.
--- @return table
local function fake_scheduler(refuse)
	local scheduler = { ticks = {}, cancelled = {} }
	function scheduler.every(interval_sec, fn)
		local handle = { interval_sec = interval_sec, fn = fn }
		scheduler.ticks[#scheduler.ticks + 1] = handle
		return handle, refuse ~= true
	end
	function scheduler.cancel(handle)
		scheduler.cancelled[#scheduler.cancelled + 1] = handle
		return true
	end
	return scheduler
end

--- Runs a scenario on a driven clock with the sink captured, and always leaves
--- collapsing disarmed and the hooks restored, even when the scenario fails.
--- @param scenario function Receives (set_time, lines).
local function with_driven_logger(scenario)
	local now = 0
	local lines = {}
	local saved_clock, saved_stamp, saved_level = Logger.clock_fn, Logger.timestamp_fn, Logger.current_level
	Logger.clock_fn = function() return now end
	Logger.timestamp_fn = function() return os.date("%Y-%m-%d %H:%M:%S", 1768467600 + now) .. ":000" end
	Logger.set_level("DEBUG")
	Logger.reset_dedup()
	Logger.set_sink(function(line) lines[#lines + 1] = line end)
	local ok, err = pcall(scenario, function(t) now = t end, lines)
	Logger.set_sink(nil)
	Logger.disable_repeat_collapsing()
	Logger.reset_dedup()
	Logger.ring_buffer_clear()
	Logger.clock_fn, Logger.timestamp_fn = saved_clock, saved_stamp
	Logger.set_level(saved_level)
	if not ok then error(err, 0) end
end

--- Counts the repeat summaries among captured lines.
--- @param lines table
--- @return number
local function repeat_summaries(lines)
	local count = 0
	for _, line in ipairs(lines) do
		if line:find("\u{2191} \"", 1, true) then count = count + 1 end
	end
	return count
end





-- ===============================================
-- ===============================================
-- ======= 2/ Arming and the Periodic Tick =======
-- ===============================================
-- ===============================================

helpers.describe("logger repeat collapsing: macOS arming and tick", function()
	helpers.it("arms once with one tick at the registry's logger flush interval", function()
		with_driven_logger(function()
			local scheduler = fake_scheduler()
			helpers.assert_eq(Logger.enable_repeat_collapsing(scheduler), true)
			helpers.assert_eq(Logger.repeat_collapsing_enabled(), true)
			helpers.assert_eq(#scheduler.ticks, 1, "arming must commit exactly one periodic tick")
			helpers.assert_eq(scheduler.ticks[1].interval_sec, Timings.sec("logger", "flush_interval_ms"),
				"the tick runs at the shared registry's logger flush interval")

			local again, err = Logger.enable_repeat_collapsing(scheduler)
			helpers.assert_eq(again, false, "a second arming must be refused")
			helpers.assert_true(tostring(err):find("already", 1, true) ~= nil,
				"the refusal must say why, got: " .. tostring(err))
			helpers.assert_eq(#scheduler.ticks, 1, "a refused arming must not commit a second tick")
		end)
	end)

	helpers.it("the tick closes a streak that fell silent once its window elapsed", function()
		with_driven_logger(function(set_time, lines)
			local scheduler = fake_scheduler()
			Logger.enable_repeat_collapsing(scheduler)
			local window_sec = Timings.sec("logger", "repeat_window_ms")

			set_time(0)
			Logger.debug("corpus", "Health-check tick (watchers=%d)", 1)
			set_time(30)
			Logger.debug("corpus", "Health-check tick (watchers=%d)", 1)
			helpers.assert_eq(#lines, 1, "the second occurrence inside the window must be withheld")

			set_time(window_sec - 1)
			scheduler.ticks[1].fn()
			helpers.assert_eq(repeat_summaries(lines), 0, "a tick inside the window must emit nothing")

			set_time(window_sec)
			scheduler.ticks[1].fn()
			helpers.assert_eq(repeat_summaries(lines), 1,
				"the tick must summarise a streak whose source fell silent, not wait for another line")
			helpers.assert_true(lines[#lines]:find("repeated 1 more time", 1, true) ~= nil,
				"the summary must carry the withheld count, got: " .. tostring(lines[#lines]))
		end)
	end)

	helpers.it("a tick that cannot be committed leaves collapsing disarmed", function()
		with_driven_logger(function(_, lines)
			local scheduler = fake_scheduler(true)
			local armed, err = Logger.enable_repeat_collapsing(scheduler)
			helpers.assert_eq(armed, false, "an uncommitted tick must fail the arming")
			helpers.assert_true(err ~= nil, "the failure must carry its reason")
			helpers.assert_eq(Logger.repeat_collapsing_enabled(), false,
				"half-armed collapsing would withhold lines that no tick will ever summarise")
			helpers.assert_eq(scheduler.cancelled[1], scheduler.ticks[1],
				"the exact uncommitted handle must be released")

			Logger.debug("corpus", "Refused %d", 1)
			Logger.debug("corpus", "Refused %d", 2)
			helpers.assert_eq(#lines, 2, "a disarmed layer must withhold nothing")
		end)
	end)

	helpers.it("disarming cancels the exact tick it committed", function()
		with_driven_logger(function()
			local scheduler = fake_scheduler()
			Logger.enable_repeat_collapsing(scheduler)
			helpers.assert_eq(Logger.disable_repeat_collapsing(), true)
			helpers.assert_eq(scheduler.cancelled[1], scheduler.ticks[1])
			helpers.assert_eq(Logger.repeat_collapsing_enabled(), false)
		end)
	end)
end)





-- ==================================
-- ==================================
-- ======= 3/ Exit and Reload =======
-- ==================================
-- ==================================

helpers.describe("logger repeat collapsing: exit and reload flush", function()
	helpers.it("the shutdown drain carries every pending summary", function()
		with_driven_logger(function(set_time, lines)
			Logger.enable_repeat_collapsing(fake_scheduler())
			set_time(0)
			Logger.info("corpus", "Poll.")
			set_time(30)
			Logger.info("corpus", "Poll.")

			local summaries_when_done = nil
			local committed = Logger.begin_async_sink_shutdown(function()
				summaries_when_done = repeat_summaries(lines)
			end)
			helpers.assert_eq(committed, true)
			helpers.assert_eq(summaries_when_done, 1,
				"the pending summary must be emitted before the drain completes, or exit loses its count")
		end)
	end)
end)





-- ===============================
-- ===============================
-- ======= 4/ Boot Arms It =======
-- ===============================
-- ===============================

helpers.describe("logger repeat collapsing: root init.lua arms it", function()
	helpers.it("arms once, after the native sink owns the file and before runtime capture", function()
		-- Located by a symbol unique to root init.lua, so the guard survives a move.
		local src, err = helpers.read_driver_unit("async_log_ready, async_log_err")
		helpers.assert_true(src ~= nil and src ~= "", "root init.lua must be locatable: " .. tostring(err))
		local code = src:gsub("%-%-[^\n]*", "")

		local arms = {}
		for at in code:gmatch("()Logger%.enable_repeat_collapsing%(TimerScheduler%)") do arms[#arms + 1] = at end
		helpers.assert_eq(#arms, 1, "init.lua must arm repeat collapsing exactly once, with the TimerScheduler")

		local sink_at = code:find("Logger.start_async_sink(TimerScheduler)", 1, true)
		local capture_at = code:find("Logger.install_runtime_error_capture()", 1, true)
		helpers.assert_true(sink_at ~= nil and capture_at ~= nil,
			"prerequisite: init.lua still commits the native sink and installs runtime capture")
		helpers.assert_true(arms[1] > sink_at,
			"arming before the native sink commits would route the first summaries to the boot file")
		helpers.assert_true(arms[1] < capture_at,
			"arming must precede the runtime so its periodic lines are collapsed from the start")
	end)
end)
