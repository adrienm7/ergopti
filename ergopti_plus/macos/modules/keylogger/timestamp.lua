--- modules/keylogger/timestamp.lua

--- ==============================================================================
--- MODULE: Keylogger Timestamp Helper
--- DESCRIPTION:
--- The single source of the "%Y-%m-%d HH:MM:SS.mmm" timestamp used across the
--- keylogger modules (sqlite_writer, log_manager, rotation, export).
---
--- FEATURES & RATIONALE:
--- 1. One clock: the seconds field AND the millisecond fraction are both derived
---    from the SAME wall-clock reading (TimerScheduler.now() -> secondsSinceEpoch).
---    The previous four copies mixed clocks — seconds from os.date (wall time) but
---    the .mmm from (hs.timer.absoluteTime()/1e6) % 1000 (milliseconds-since-boot),
---    which is unrelated to the wall-clock second, so the fraction was meaningless
---    and non-monotonic within a second (F-L1).
--- 2. No direct hs.* dependency: the wall clock comes through the timer_scheduler
---    adapter, so this stays adapter-isolated.
--- ==============================================================================

local M = {}

local TimerScheduler = require("adapters.timer_scheduler")

--- Captures the current wall-clock instant without formatting it. Callers on
--- an input callback can retain this scalar and defer os.date/string work.
--- @return number Seconds since the Unix epoch, including the fraction.
function M.now_epoch()
	return TimerScheduler.now()
end

--- Formats one previously captured wall-clock instant.
--- @param epoch number Seconds since the Unix epoch, including the fraction.
--- @return string The formatted timestamp.
function M.format_epoch(epoch)
	assert(type(epoch) == "number", "epoch must be a number")
	return string.format("%s.%03d",
		os.date("%Y-%m-%d %H:%M:%S", math.floor(epoch)),
		math.floor((epoch % 1) * 1000))
end

--- Returns a "%Y-%m-%d HH:MM:SS.mmm" local-time timestamp whose millisecond
--- fraction is the true sub-second offset of the same wall-clock reading.
--- @return string The formatted timestamp.
function M.now_ts()
	return M.format_epoch(M.now_epoch())
end

return M
