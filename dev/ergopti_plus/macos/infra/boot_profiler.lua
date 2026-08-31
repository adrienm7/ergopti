--- infra/boot_profiler.lua

--- ==============================================================================
--- MODULE: Boot Profiler
--- DESCRIPTION:
--- Lightweight monotonic phase timing for startup diagnosis, ported from the
--- Windows AHK driver (infra/boot_profiler.ahk). The Hammerspoon driver loads a
--- large hotstring corpus, builds the menubar, and arms several watchers at boot;
--- when a user reports a slow start there was previously no way to see WHICH phase
--- dominated. M.mark() emits one INFO line per phase with the delta since the
--- previous mark and the running total, so the log alone tells you where boot time
--- goes — no profiler attach, no reload.
---
--- FEATURES & RATIONALE:
--- 1. Zero behavioural impact: pure timing reads plus one INFO log per phase.
--- 2. Fail-safe: every log call is wrapped so a profiler glitch can never abort
---    or delay boot — a missing logger simply makes the mark silent.
--- 3. Monotonic clock: reads nanoseconds via the TimerScheduler port adapter
---    (the macOS analog of A_TickCount), available before any heavy module.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local Timer  = require("adapters.timer_scheduler")
local LOG    = "BootProfile"

-- Monotonic nanoseconds captured at the previous mark and at M.begin(). A nil
-- origin means begin() has not run; zero remains a valid arbitrary clock value.
local _last_ns  = nil
local _start_ns = nil

-- Monotonic nanoseconds → milliseconds. The AHK driver works directly in ticks
-- (A_TickCount is already ms); Hammerspoon's clock is in nanoseconds, so every
-- duration is scaled here in exactly one place.
local NS_PER_MS = 1e6





-- ==========================================
-- ==========================================
-- ======= 1/ Boot phase profiler API =======
-- ==========================================
-- ==========================================

--- Returns the current monotonic timestamp in nanoseconds. Routed through the
--- TimerScheduler port adapter so wall-clock adjustments cannot skew durations.
--- @return number Nanoseconds from an arbitrary monotonic origin.
local function now_ns()
	return Timer.now_ns()
end

--- Starts (or restarts) the boot timer. Call once, as early as the logger is
--- ready, so subsequent marks measure deltas from a known origin.
function M.begin()
	_start_ns = now_ns()
	_last_ns  = _start_ns
	pcall(Logger.info, LOG, "Boot timing started.")
end

--- Logs the time since the previous mark and since M.begin().
--- Tolerates a mark fired before begin() by anchoring the origin on first use,
--- so the profiler never logs a nonsensical negative or huge total.
--- @param phase_name string Human-readable label for the phase that just ended.
function M.mark(phase_name)
	local n = now_ns()
	if _start_ns == nil then
		_start_ns = n
		_last_ns  = n
	end
	local delta = (n - _last_ns) / NS_PER_MS
	local total = (n - _start_ns) / NS_PER_MS
	_last_ns = n
	pcall(Logger.info, LOG, "%s: +%.1f ms (total %.1f ms).", tostring(phase_name), delta, total)
end

--- Returns the milliseconds elapsed since M.begin() without emitting a log.
--- Useful for callers that want to assert or branch on the running total.
--- @return number Milliseconds since begin (0 when begin() was never called).
function M.elapsed_ms()
	if _start_ns == nil then return 0 end
	return (now_ns() - _start_ns) / NS_PER_MS
end

return M
