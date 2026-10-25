--- infra/phase_stats.lua

--- ==============================================================================
--- MODULE: Phase Stats
--- DESCRIPTION:
--- Permanent, privacy-safe timing and counting for every phase that can hide
--- latency: per-key hot path stages, menu build items, boot sub-stages, config
--- parses, child processes. The bookkeeping (counts, totals, maxima, the
--- attribution ring and the per-family evidence lines) is the shared
--- _shared/lua/phase_stats_core.lua, which the Linux driver runs as well; this
--- module adds what is specific to Hammerspoon: the nanosecond clock and the
--- periodic flush timer.
---
--- FEATURES & RATIONALE:
--- 1. Near-zero cost: add() allocates nothing after a phase's first use; the
---    flush formats text only when INFO is enabled, so a quiet log level pays
---    for counters and nothing else.
--- 2. Closed names only: phase names are source constants (menu item ids, stage
---    names). No typed text, path or URL ever enters a phase name or a value.
--- 3. Hold attribution: a phase that lasts 2 ms or more is also written to a
---    small ring so the slow-callback report can name the phases that ran
---    during the held window (recent_since).
--- 4. One owner for the interval: start()/stop_reporting() pair the flush timer
---    and reject a second start, like every stateful module.
--- ==============================================================================

local Core = require("phase_stats_core")

local LOG = "phase_stats"

--- Reads the monotonic clock in nanoseconds: Hammerspoon's absoluteTime, with
--- the process CPU clock as the degraded fallback of a headless test run.
--- @return number
local function now_ns()
	local native = rawget(_G, "hs")
	local absolute = type(native) == "table" and type(native.timer) == "table"
		and native.timer.absoluteTime or nil
	if absolute then return absolute() end
	return os.clock() * 1e9
end

local M = Core.new({
	now_ns = now_ns,
	info_enabled = function()
		local Logger = require("infra.logger")
		return Logger.is_enabled(Logger.LEVELS.INFO)
	end,
	evidence = function(format, ...) require("infra.logger").evidence(LOG, format, ...) end,
})

local _handle = nil





-- ============================
-- ============================
-- ======= 1/ Lifecycle =======
-- ============================
-- ============================

--- Starts the periodic flush. A second start is refused.
--- @param interval_sec number|nil Flush interval in seconds.
--- @return boolean started
function M.start(interval_sec)
	local Logger = require("infra.logger")
	if _handle ~= nil then
		Logger.error(LOG, "Phase summary timer is already running; a second start is refused.")
		return false
	end
	local interval = interval_sec or M.DEFAULT_INTERVAL_SEC
	Logger.start(LOG, "Starting the phase summary timer (every %d s)…", interval)
	local handle, committed = require("adapters.timer_scheduler").every(interval, function()
		M.flush(interval)
	end)
	if committed ~= true then
		Logger.error(LOG, "The phase summary timer was not armed.")
		return false
	end
	_handle = handle
	Logger.done(LOG, "Phase summary timer armed.")
	return true
end

--- Stops the periodic flush, emitting the last interval first.
--- @return boolean stopped
function M.stop_reporting()
	if _handle == nil then return true end
	local Logger = require("infra.logger")
	Logger.start(LOG, "Stopping the phase summary timer…")
	M.flush()
	local settled = require("adapters.timer_scheduler").cancel(_handle)
	if settled ~= true then
		Logger.error(LOG, "The phase summary timer could not be stopped.")
		return false
	end
	_handle = nil
	Logger.done(LOG, "Phase summary timer stopped.")
	return true
end

return M
