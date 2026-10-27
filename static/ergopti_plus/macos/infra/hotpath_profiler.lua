--- infra/hotpath_profiler.lua

--- ==============================================================================
--- MODULE: Hot-path Profiler
--- DESCRIPTION:
--- Sub-millisecond timing for the per-keystroke hot path, ported from the Windows
--- AHK driver (infra/hotpath_profiler.ahk). BootProfile measures one-shot startup
--- phases in milliseconds; that is far too coarse for a keystroke that should
--- complete in well under a millisecond. This module reads a nanosecond-resolution
--- monotonic clock (via the TimerScheduler adapter) and logs ONLY segments that
--- exceed a threshold, so normal typing produces zero log noise while any real
--- hitch surfaces with the segment that spent the time.
---
--- FEATURES & RATIONALE:
--- 1. Nanosecond precision: the only way to see a 2 ms vs 0.2 ms keystroke.
--- 2. Threshold-gated: a slow keystroke is logged, a fast one is silent — the log
---    stays useful instead of drowning in one line per character.
--- 3. Near-zero overhead: two clock reads and a subtraction per keystroke, which
---    is negligible against the match + tooltip work it wraps, so it can stay on
---    permanently as a latency tripwire.
--- 4. Nesting attribution (shared hotpath_segments.new_nesting): now() opens a
---    frame and log_if_slow() closes it, so a segment is judged on its own time
---    and a slow one is reported with the declared segment around it: a slow
---    trigger match inside a keystroke is one line for the match, in keydown.
--- 5. Names and numbers only: the WARNING carries segment names and durations,
---    never the typed character or the buffer.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local Timer  = require("adapters.timer_scheduler")
local PhaseStats = require("infra.phase_stats")
local Segments = require("hotpath_segments")
local Timings = require("infra.timings")
local LOG    = "HotPath"

-- Phase name of each label, built once so a keystroke never concatenates.
local _phase_names = {}

-- Segments whose processing exceeds this many milliseconds are logged at
-- WARNING. The budget and the declared segments live in the shared inventory
-- (_shared/lua/hotpath_segments.lua), so macOS and Linux share one policy.
local DEFAULT_SLOW_MS = Timings.ms("logger", "hotpath_slow_ms")
local _slow_ms = DEFAULT_SLOW_MS
-- A declared segment with its own measured threshold keeps it whatever the
-- runtime default is; built once so the hot path is one table read.
local _segment_slow_ms = {}
for name in pairs(Segments.for_driver("macos")) do
	if Segments.threshold_ms(name, DEFAULT_SLOW_MS) ~= DEFAULT_SLOW_MS then
		_segment_slow_ms[name] = Segments.threshold_ms(name, DEFAULT_SLOW_MS)
	end
end

-- Rate limiter of the WARNING (window shared with Linux); PhaseStats keeps
-- counting every slow occurrence.
local _admit_slow = Segments.new_slow_gate()

-- Nanoseconds per millisecond.
local NS_PER_MS = 1e6

--- The threshold of a segment in milliseconds.
--- @param label string Declared segment name.
--- @return number
local function threshold_of(label)
	return _segment_slow_ms[label] or _slow_ms
end

--- Logs one slow segment, rate limited per segment.
--- @param report table { segment, parent, total_ms, own_ms } from the nesting tracker.
--- @param now_ms number
local function report_slow(report, now_ms)
	local admitted, skipped = _admit_slow(report.segment, now_ms)
	if admitted then
		pcall(Logger.warn, LOG, "Slow %s: %.2f ms own, %.2f ms total, parent %s (%d similar since the last line).",
			report.segment, report.own_ms, report.total_ms, report.parent, skipped)
	end
end

-- Open segments, in nesting order. Stamps are nanoseconds; the tracker works in
-- milliseconds, and the division of one stamp always yields the same number.
local _nesting = Segments.new_nesting(threshold_of, report_slow)





-- ==================================================
-- ==================================================
-- ======= 1/ Hot-path keystroke profiler API =======
-- ==================================================
-- ==================================================

--- Reads the current high-resolution timestamp in nanoseconds. Routed through
--- the TimerScheduler port adapter (monotonic ns, with a wall-clock fallback)
--- so this module carries no direct timer-API dependency.
--- Opens a segment frame: every now() is closed by log_if_slow().
--- @return number Raw nanosecond timestamp; pass to M.log_if_slow as the start.
function M.now()
	local start_ns = Timer.now_ns()
	_nesting.open(start_ns / NS_PER_MS)
	return start_ns
end

--- Returns elapsed milliseconds since a `M.now()` timestamp. Lets the hot path
--- measure individual sub-segments (e.g. trigger matching vs. preview rebuild)
--- so a slow keystroke can be attributed to a specific stage in its log line,
--- without each call site re-deriving the nanosecond→millisecond conversion.
--- @param start_ns number Nanosecond timestamp captured by M.now().
--- @return number elapsed_ms Milliseconds elapsed since `start_ns`.
function M.elapsed_ms(start_ns)
	return (Timer.now_ns() - (start_ns or 0)) / NS_PER_MS
end

--- Sets the default slow threshold in milliseconds. Lets a developer tighten or
--- loosen the tripwire without editing the constant; a segment with its own
--- measured threshold keeps it. Logs the new value at DEBUG.
--- @param ms number New threshold in milliseconds.
function M.set_threshold_ms(ms)
	if type(ms) == "number" and ms > 0 then
		_slow_ms = ms
		Logger.debug(LOG, "Slow-keystroke threshold: %.1f ms.", ms)
	end
end

--- Closes the segment opened by M.now() and logs a WARNING when its own time
--- (minus the segments closed inside it) exceeds the threshold, with its parent.
--- Silent (and nearly free) for fast keystrokes so the hot path stays clean.
--- @param label string Declared hot-path segment name (e.g. "keydown").
--- @param start_ns number Nanosecond timestamp captured by M.now() at entry.
--- @return number elapsed_ms The measured wall-clock duration in milliseconds.
function M.log_if_slow(label, start_ns)
	if type(start_ns) ~= "number" then error("hot-path segment '" .. tostring(label) .. "' closed without a now() stamp", 2) end
	local now_ns = Timer.now_ns()
	local phase = _phase_names[label]
	if phase == nil then
		phase = "hotpath." .. tostring(label)
		_phase_names[label] = phase
	end
	PhaseStats.add(phase, now_ns - start_ns)
	return (_nesting.close(label, start_ns / NS_PER_MS, now_ns / NS_PER_MS))
end

--- Forgets every open frame and the rate limiter. Tests only.
function M._reset_for_test()
	_nesting = Segments.new_nesting(threshold_of, report_slow)
	_admit_slow = Segments.new_slow_gate()
end

return M
