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
--- 4. Paired stages: M.stage() opens a named stage with a START line and
---    M.mark() closes it with SUCCESS and its duration, so a START without a
---    SUCCESS pins where a boot died. M.current_stage() names that stage for
---    fatal reports.
--- 5. Crash-proof trail: every stage line is also appended synchronously to the
---    fallback boot log (and to launcher.log until the user log folder is
---    ready) through adapters/boot_journal, because Logger lines queued for
---    the native worker die with os.exit().
--- ==============================================================================

local M = {}

local Logger      = require("infra.logger")
local Timer       = require("adapters.timer_scheduler")
local BootJournal = require("adapters.boot_journal")
local LOG         = "BootProfile"

-- Monotonic nanoseconds captured at the previous mark and at M.begin(). A nil
-- origin means begin() has not run; zero remains a valid arbitrary clock value.
local _last_ns  = nil
local _start_ns = nil

-- Open stage name and its start, the last completed stage, and completion.
local _open_stage     = nil
local _stage_start_ns = nil
local _last_completed = nil
local _complete       = false

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
	_open_stage, _stage_start_ns, _last_completed, _complete = nil, nil, nil, false
	pcall(Logger.info, LOG, "Boot timing started.")
	pcall(BootJournal.append, "INFO", "Boot timing started.")
end

--- Opens one named boot stage. Its START line is persisted synchronously, so a
--- process that dies inside the stage leaves the stage name behind.
--- @param stage_name string Human-readable stage label, closed by M.mark().
function M.stage(stage_name)
	local name = tostring(stage_name)
	if _open_stage ~= nil then
		pcall(Logger.warn, LOG, "Boot stage '%s' opened while '%s' is still open.", name, _open_stage)
	end
	_open_stage = name
	_stage_start_ns = now_ns()
	pcall(Logger.start, LOG, "Boot stage started: %s.", name)
	pcall(BootJournal.append, "START", "Boot stage started: " .. name .. ".")
end

--- Names the stage a fatal abort interrupted.
--- @return string stage Open stage, else the stage after the last completed one.
function M.current_stage()
	if _open_stage ~= nil then return _open_stage end
	if _last_completed ~= nil then return "after " .. _last_completed end
	return "before boot timing"
end

--- Reports whether M.complete() has run for this boot.
--- @return boolean
function M.is_complete()
	return _complete
end

--- Records the whole boot duration once every stage has completed.
function M.complete()
	_complete = true
	local total = _start_ns and (now_ns() - _start_ns) / NS_PER_MS or 0
	pcall(Logger.success, LOG, "Boot complete in %.0f ms.", total)
	pcall(BootJournal.append, "SUCCESS", string.format("Boot complete in %.0f ms.", total))
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
	local name = tostring(phase_name)
	if _open_stage ~= name then
		pcall(Logger.warn, LOG, "Boot mark '%s' closes no matching open stage (open: %s).",
			name, tostring(_open_stage))
	end
	local stage_ms = (_open_stage == name and _stage_start_ns) and (n - _stage_start_ns) / NS_PER_MS or delta
	_open_stage, _stage_start_ns, _last_completed = nil, nil, name
	local format = "Boot stage completed: %s in %.1f ms (+%.1f ms, total %.1f ms)."
	pcall(Logger.success, LOG, format, name, stage_ms, delta, total)
	pcall(BootJournal.append, "SUCCESS", string.format(format, name, stage_ms, delta, total))
end

--- Returns the milliseconds elapsed since M.begin() without emitting a log.
--- Useful for callers that want to assert or branch on the running total.
--- @return number Milliseconds since begin (0 when begin() was never called).
function M.elapsed_ms()
	if _start_ns == nil then return 0 end
	return (now_ns() - _start_ns) / NS_PER_MS
end

return M
