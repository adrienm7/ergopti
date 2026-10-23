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

local PhaseStats  = require("infra.phase_stats")
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

-- Label prefix of the mark init.lua records at the end of boot. Pinned against
-- init.lua by tests/unit/infra/logger/test_diagnostic_snapshot.lua.
M.BOOT_COMPLETE_LABEL = "Boot complete"

-- Total boot duration captured at the BOOT_COMPLETE_LABEL mark.
local _boot_complete_ms = nil

-- Require trace: the native require, the modules first loaded since the last
-- stage mark (name and self time), and the load stack used to subtract nested
-- loads from their parent.
local _native_require  = nil
local _loaded_modules  = {}
local _require_stack   = {}
-- A stage reports the modules whose own load took at least this long.
local REQUIRE_REPORT_MS = 3
-- A stage line names at most this many modules.
local REQUIRE_REPORT_MAX = 8
-- Longest sub-stage the DEBUG line still calls routine; above it the line is INFO.
local SUB_STAGE_INFO_MS = 25
-- Timestamp of the previous sub-stage (or of the stage opening) in nanoseconds.
local _sub_last_ns = nil





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

--- Starts timing every first-time `require` until M.complete(): each stage mark
--- then names the modules whose own load (nested loads excluded) was slowest.
--- Idempotent; the wrapper rethrows a load error with its original message.
function M.trace_requires()
	if _native_require ~= nil then return end
	_native_require = _G.require
	_G.require = function(module_name, ...)
		if package.loaded[module_name] ~= nil then return _native_require(module_name, ...) end
		local frame = { children = 0 }
		_require_stack[#_require_stack + 1] = frame
		local started = now_ns()
		local ok, first, second = pcall(_native_require, module_name, ...)
		local total = now_ns() - started
		_require_stack[#_require_stack] = nil
		local parent = _require_stack[#_require_stack]
		if parent then parent.children = parent.children + total end
		_loaded_modules[#_loaded_modules + 1] = {
			name = tostring(module_name), ms = (total - frame.children) / NS_PER_MS }
		if not ok then error(first, 0) end
		return first, second
	end
end

--- Restores the native require.
local function untrace_requires()
	if _native_require == nil then return end
	_G.require = _native_require
	_native_require = nil
end

--- Logs the modules first loaded since the previous mark, slowest first, then
--- clears the list. Silent when the trace is off or nothing crossed the floor.
--- @param stage_name string Stage that just closed.
local function report_stage_requires(stage_name)
	local loaded = _loaded_modules
	_loaded_modules = {}
	if #loaded == 0 then return end
	local total = 0
	for _, entry in ipairs(loaded) do total = total + entry.ms end
	PhaseStats.add("boot.requires", total * NS_PER_MS)
	table.sort(loaded, function(a, b) return a.ms > b.ms end)
	local parts = {}
	for _, entry in ipairs(loaded) do
		if entry.ms < REQUIRE_REPORT_MS or #parts >= REQUIRE_REPORT_MAX then break end
		parts[#parts + 1] = string.format("%s=%.1f ms", entry.name, entry.ms)
	end
	pcall(Logger.evidence, LOG, "Boot stage requires: %s loaded %d module(s) in %.1f ms (own time)%s.",
		stage_name, #loaded, total, #parts > 0 and "; slowest: " .. table.concat(parts, ", ") or "")
end

--- Records the time since the stage opened (or since the previous sub-stage)
--- as one named sub-stage, so a long stage explains itself. Needs an open stage.
--- @param label string Closed sub-stage name, e.g. "hotstring groups".
--- @return number|nil elapsed_ms Milliseconds, nil when no stage is open.
function M.sub(label)
	if _open_stage == nil then return nil end
	local now = now_ns()
	local elapsed_ms = (now - (_sub_last_ns or _stage_start_ns or now)) / NS_PER_MS
	_sub_last_ns = now
	PhaseStats.add("boot_sub." .. tostring(label), elapsed_ms * NS_PER_MS)
	if elapsed_ms >= SUB_STAGE_INFO_MS then
		pcall(Logger.evidence, LOG, "Boot sub-stage: %s / %s took %.1f ms.", _open_stage, tostring(label), elapsed_ms)
	else
		pcall(Logger.debug, LOG, "Boot sub-stage: %s / %s took %.1f ms.", _open_stage, tostring(label), elapsed_ms)
	end
	return elapsed_ms
end

--- Starts (or restarts) the boot timer. Call once, as early as the logger is
--- ready, so subsequent marks measure deltas from a known origin.
function M.begin()
	_start_ns = now_ns()
	_last_ns  = _start_ns
	_open_stage, _stage_start_ns, _last_completed, _complete = nil, nil, nil, false
	_boot_complete_ms = nil
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
	_sub_last_ns = _stage_start_ns
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
	untrace_requires()
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
	PhaseStats.add("boot.stage", stage_ms * NS_PER_MS)
	report_stage_requires(name)
	-- The boot sequence closes with a mark whose label starts with BOOT_COMPLETE_LABEL.
	-- Freezing the total there lets the post-boot diagnostic snapshot report the
	-- real boot duration without the boot sequence having to hand it over.
	if _boot_complete_ms == nil and name:sub(1, #M.BOOT_COMPLETE_LABEL)
		== M.BOOT_COMPLETE_LABEL then
		_boot_complete_ms = total
	end
end

--- Total boot milliseconds frozen by the "Boot complete" mark, or nil before it.
--- @return number|nil
function M.boot_complete_ms()
	return _boot_complete_ms
end

--- Returns the milliseconds elapsed since M.begin() without emitting a log.
--- Useful for callers that want to assert or branch on the running total.
--- @return number Milliseconds since begin (0 when begin() was never called).
function M.elapsed_ms()
	if _start_ns == nil then return 0 end
	return (now_ns() - _start_ns) / NS_PER_MS
end

return M
