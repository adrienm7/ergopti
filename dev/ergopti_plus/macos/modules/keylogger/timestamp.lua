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

--- Returns a "%Y-%m-%d HH:MM:SS.mmm" local-time timestamp whose millisecond
--- fraction is the true sub-second offset of the same wall-clock reading.
--- @return string The formatted timestamp.
function M.now_ts()
	local t = TimerScheduler.now()
	return string.format("%s.%03d",
		os.date("%Y-%m-%d %H:%M:%S", math.floor(t)),
		math.floor((t % 1) * 1000))
end

return M
