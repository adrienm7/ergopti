--- infra/hotpath_profiler.lua

--- ==============================================================================
--- MODULE: Hot-path Profiler
--- DESCRIPTION:
--- Sub-millisecond timing for the per-keystroke hot path, ported from the Windows
--- AHK driver (infra/hotpath_profiler.ahk). BootProfile measures one-shot startup
--- phases in milliseconds; that is far too coarse for a keystroke that should
--- complete in well under a millisecond. This module reads a nanosecond-resolution
--- monotonic clock (via the TimerScheduler adapter) and logs ONLY keystrokes that
--- exceed a threshold, so
--- normal typing produces zero log noise while any real hitch surfaces with the
--- offending character and buffer for diagnosis.
---
--- FEATURES & RATIONALE:
--- 1. Nanosecond precision: the only way to see a 2 ms vs 0.2 ms keystroke.
--- 2. Threshold-gated: a slow keystroke is logged, a fast one is silent — the log
---    stays useful instead of drowning in one line per character.
--- 3. Near-zero overhead: two clock reads and a subtraction per keystroke, which
---    is negligible against the match + tooltip work it wraps, so it can stay on
---    permanently as a latency tripwire.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local Timer  = require("adapters.timer_scheduler")
local LOG    = "HotPath"

-- Keystrokes whose hot-path processing exceeds this many milliseconds are logged
-- at WARNING. A 20 ms budget filters harmless one-off scheduler jitter while
-- preserving a visible typing hitch as an actionable diagnostic.
local DEFAULT_SLOW_MS = 20.0
local _slow_ms        = DEFAULT_SLOW_MS

-- Nanoseconds per millisecond — the conversion applied once per slow keystroke.
local NS_PER_MS = 1e6





-- ==================================================
-- ==================================================
-- ======= 1/ Hot-path keystroke profiler API =======
-- ==================================================
-- ==================================================

--- Reads the current high-resolution timestamp in nanoseconds. Routed through
--- the TimerScheduler port adapter (monotonic ns, with a wall-clock fallback)
--- so this module carries no direct timer-API dependency.
--- @return number Raw nanosecond timestamp; pass to M.log_if_slow as the start.
function M.now()
	return Timer.now_ns()
end

--- Returns elapsed milliseconds since a `M.now()` timestamp. Lets the hot path
--- measure individual sub-segments (e.g. trigger matching vs. preview rebuild)
--- so a slow keystroke can be attributed to a specific stage in its log line,
--- without each call site re-deriving the nanosecond→millisecond conversion.
--- @param start_ns number Nanosecond timestamp captured by M.now().
--- @return number elapsed_ms Milliseconds elapsed since `start_ns`.
function M.elapsed_ms(start_ns)
	return (M.now() - (start_ns or 0)) / NS_PER_MS
end

--- Sets the slow-keystroke threshold in milliseconds. Lets a developer tighten or
--- loosen the tripwire without editing the constant. Logs the new value at DEBUG.
--- @param ms number New threshold in milliseconds.
function M.set_threshold_ms(ms)
	if type(ms) == "number" and ms > 0 then
		_slow_ms = ms
		Logger.debug(LOG, "Slow-keystroke threshold: %.1f ms.", ms)
	end
end

--- Logs a WARNING when the elapsed time since `start_ns` exceeds the threshold.
--- Silent (and nearly free) for fast keystrokes so the hot path stays clean.
--- @param label string Hot-path segment name (e.g. "keydown").
--- @param start_ns number Nanosecond timestamp captured by M.now() at entry.
--- @param detail string|nil Context shown when slow (typed char, buffer, …).
--- @return number elapsed_ms The measured duration in milliseconds.
function M.log_if_slow(label, start_ns, detail)
	local elapsed_ms = (M.now() - (start_ns or 0)) / NS_PER_MS
	if elapsed_ms > _slow_ms then
		pcall(Logger.warn, LOG, "Slow %s: %.2f ms (%s).",
			tostring(label), elapsed_ms, tostring(detail or ""))
	end
	return elapsed_ms
end

return M
