--- infra/reload_timing.lua

--- ==============================================================================
--- MODULE: Reload Duration Across The Restart (Linux)
--- DESCRIPTION:
--- Measures a Reload from its request to the successor's boot completion and
--- judges it against [budgets] driver_reload_ms, as the macOS driver does
--- after hs.reload(). On Linux a Reload is a daemon restart
--- (infra/reload_restart.lua), so the request and the end of the boot run in
--- two processes: the requesting daemon stamps the request time in a file
--- beside the store, and the successor reads and retires it at boot
--- completion.
---
--- FEATURES & RATIONALE:
--- 1. Wall clock, not the monotonic one: the two readings belong to two
---    processes, and the stamp must survive a systemd restart, which inherits
---    no argument and no environment from the requesting daemon.
--- 2. The stamp is one-shot: the successor removes it whatever it holds, a
---    failed or abandoned restart removes it at once, so a later ordinary start
---    never reports a reload.
--- 3. The same log line as macOS ("Reload completed in N ms ...") and the
---    shared overrun warning (_shared/lua/perf_budget.lua), so
---    tools/dev/field-log-analyse.py reads both drivers with one pattern.
--- 4. Diagnostics only: a stamp that cannot be written or read is logged as an
---    error and never blocks the reload or the boot.
--- ==============================================================================

local M = {}

local Files = require("adapters.file_system")
local Logger = require("logger.shim")
local NativePath = require("native_path")
local Shell = require("adapters.shell_runner")
local Storage = require("adapters.storage")

local LOG = "infra.reload_timing"

-- The stamp's whole content; the version names its grammar.
local STAMP_FORMAT = "ERGOPTI_RELOAD_REQUEST_V1\nrequested_at_ms=%d\n"
local STAMP_PATTERN = "^ERGOPTI_RELOAD_REQUEST_V1\nrequested_at_ms=(%d+)\n$"

-- luv.gettimeofday() reports seconds and microseconds.
local MS_PER_SECOND = 1000
local US_PER_MS = 1000

--- Reads the wall clock in epoch milliseconds; tests replace it.
local function wall_clock_ms()
	local seconds, microseconds = require("luv").gettimeofday()
	return seconds * MS_PER_SECOND + math.floor(microseconds / US_PER_MS)
end

local _clock = wall_clock_ms

--- The stamp file, next to the store's other restart hand-offs.
--- @return string path
function M.path()
	return Storage.path() .. ".reload-requested"
end

--- Stamps the time of a Reload request before the restart is requested.
--- @return boolean stamped
function M.mark()
	local path = M.path()
	local made, acknowledged = pcall(Shell.run, "mkdir -p -- " .. Shell.quote(NativePath.dirname(path)) .. " 2>/dev/null")
	local written = made and acknowledged == true
		and Files.write(path, string.format(STAMP_FORMAT, math.floor(_clock())))
	if written ~= true then
		Logger.error(LOG, "The reload request time could not be written: this reload goes unmeasured.")
		return false
	end
	return true
end

--- Retires the stamp of a restart that was refused or abandoned.
--- @return boolean cleared
function M.clear()
	local cleared = Files.delete(M.path())
	if cleared ~= true then Logger.error(LOG, "The stale reload request time could not be removed.") end
	return cleared == true
end

--- At boot completion: reports the reload this boot follows, if any, and retires its stamp.
--- @return number|nil reload_ms The reload's duration, nil when this boot follows no reload.
function M.complete()
	local path = M.path()
	local read, content, status = pcall(Files.read_with_status, path)
	if read and status == "absent" then return nil end
	local requested = read and status == "ok" and type(content) == "string" and content:match(STAMP_PATTERN)
	M.clear()
	if not requested then
		Logger.error(LOG, "The reload request time is unreadable or malformed; the reload goes unmeasured.")
		return nil
	end
	local reload_ms = _clock() - tonumber(requested)
	if reload_ms < 0 then
		Logger.error(LOG, "The reload request time lies %d ms in the future (the clock moved back); "
			.. "the reload goes unmeasured.", math.floor(-reload_ms))
		return nil
	end
	Logger.info(LOG, "Reload completed in %.0f ms (reload request to boot complete).", reload_ms)
	require("perf_budget").judge(Logger, LOG, "reload", reload_ms,
		function() return require("infra.timings").ms("budgets", "driver_reload_ms") end)
	return reload_ms
end

--- Replaces the wall clock (tests only). Pass nil to restore it.
--- @param fn function|nil Zero-argument function returning epoch milliseconds.
function M._use_clock(fn)
	_clock = fn or wall_clock_ms
end

return M
