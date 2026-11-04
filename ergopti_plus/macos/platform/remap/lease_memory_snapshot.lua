--- platform/remap/lease_memory_snapshot.lua

--- ==============================================================================
--- MODULE: Memory Pressure At A Lease Failure
--- DESCRIPTION:
--- Logs how much memory the Mac had free when a Karabiner lease failed. Silent
--- PONG and READY timeouts on Apple silicon (TODO items 117/140) have one open
--- explanation, starvation: a worker that does not run in time because the
--- system is short of memory. One INFO line per failure window names the free
--- percentage macOS reports, so the next field log confirms or rules it out.
---
--- FEATURES & RATIONALE:
--- 1. Off the failure path: the reading runs in its own task after the fence;
---    the lease outcome never waits for it, and a refused reading is a WARNING.
--- 2. One reading per MIN_INTERVAL_SECONDS: a failure storm logs once.
--- 3. The same parser serves the field run's lease check, so both name the
---    figure the same way.
--- ==============================================================================

local M = {}

local Logger         = require("infra.logger")
local ShellRunner    = require("adapters.shell_runner")
local TimerScheduler = require("adapters.timer_scheduler")

local LOG = "lease_memory"

--- The macOS tool that prints the system-wide free memory percentage.
M.TOOL = "/usr/bin/memory_pressure"

--- Seconds between two readings; a failure inside the window is not read again.
M.MIN_INTERVAL_SECONDS = 60

local NS_PER_SECOND = 1e9

local _last_reading_ns = nil

--- Clears the throttle; tests use it.
function M.reset()
	_last_reading_ns = nil
end

--- Extracts the free percentage from the tool's output.
--- @param output any Output of /usr/bin/memory_pressure.
--- @return integer|nil percent Nil when the summary line is missing.
function M.parse_free_percent(output)
	local value = tostring(output or ""):match("[Ff]ree percentage:%s*(%d+)%%")
	return value and tonumber(value) or nil
end

--- Reads the free memory once for a lease failure, unless one was read inside
--- the throttle window.
--- @param kind string Lease failure kind (pong, ready, mode, ...).
--- @return boolean started True when a reading task started.
function M.note_failure(kind)
	local now_ns = TimerScheduler.now_ns()
	if _last_reading_ns and now_ns - _last_reading_ns < M.MIN_INTERVAL_SECONDS * NS_PER_SECOND then
		Logger.debug(LOG, "Memory reading for a lease failure (%s) skipped: one ran less than %d s ago.",
			tostring(kind), M.MIN_INTERVAL_SECONDS)
		return false
	end
	_last_reading_ns = now_ns
	Logger.start(LOG, "Reading the free memory for a Karabiner lease failure (%s)…", tostring(kind))
	local task = ShellRunner.spawn(M.TOOL, {}, function(code, stdout)
		local percent = code == 0 and M.parse_free_percent(stdout) or nil
		if percent then
			Logger.success(LOG, "Memory free when the Karabiner lease failed (%s): %d%%.", tostring(kind), percent)
		else
			Logger.warn(LOG, "The free memory at a Karabiner lease failure (%s) could not be read: exit %s.",
				tostring(kind), tostring(code))
		end
	end)
	if task.start() ~= true then
		Logger.warn(LOG, "The free memory at a Karabiner lease failure (%s) could not be read: the tool did not start.",
			tostring(kind))
		return false
	end
	return true
end

return M
