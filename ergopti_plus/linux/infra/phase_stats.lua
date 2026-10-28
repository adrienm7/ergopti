--- infra/phase_stats.lua

--- ==============================================================================
--- MODULE: Phase Stats (Linux)
--- DESCRIPTION:
--- Open-named phase timing for work that PerfCounters' closed enum cannot hold:
--- one phase per child program (process.<program>), boot sub-stages, config
--- parses. The bookkeeping is the shared _shared/lua/phase_stats_core.lua, the
--- same code the macOS driver runs; this module adds the Linux clock, the
--- evidence sink and the flush cadence.
---
--- FEATURES & RATIONALE:
--- 1. Mirrors macOS: the phase names (process.<program>) and the evidence line
---    ("Phase summary [process] over 300 s: ...") are identical, so one search
---    reads a log from either OS.
--- 2. No timer of its own. The event loop's periodic tick calls maybe_flush(),
---    like PerfCounters, so there is nothing to stop at shutdown and no second
---    owner of the loop's cadence.
--- 3. Names only: a phase name is a program basename or a source constant; the
---    command line, which can carry user text in a heredoc, never reaches it.
--- ==============================================================================

local Core      = require("phase_stats_core")
local Logger    = require("logger.shim")
local Monotonic = require("infra.monotonic")

local LOG = "phase_stats"

-- The monotonic source reads milliseconds; the shared core counts nanoseconds.
local NANOSECONDS_PER_MILLISECOND = 1e6

local M = Core.new({
	now_ns = function() return Monotonic.now_ms() * NANOSECONDS_PER_MILLISECOND end,
	info_enabled = function()
		-- The print-fallback shim has no level filter: everything it receives prints.
		if type(Logger.get_level) ~= "function" then return true end
		return Logger.get_level() <= Logger.LEVELS.INFO
	end,
	evidence = function(format, ...) Logger.evidence(LOG, format, ...) end,
	-- Linux reports its log volume on the PerfCounters interval line instead.
	memory_note = function() return nil end,
})

-- Monotonic milliseconds when the current interval started; nil until the first
-- tick opens it.
local _interval_start_ms = nil

--- Called from the event loop's periodic tick: emits the summary when an
--- interval has elapsed and starts the next one.
--- @param now_ms number|nil Monotonic milliseconds; read when absent.
--- @return boolean flushed
function M.maybe_flush(now_ms)
	now_ms = now_ms or Monotonic.now_ms()
	if _interval_start_ms == nil then
		_interval_start_ms = now_ms
		return false
	end
	local elapsed_sec = (now_ms - _interval_start_ms) / 1000
	if elapsed_sec < M.DEFAULT_INTERVAL_SEC then return false end
	_interval_start_ms = now_ms
	M.flush(elapsed_sec)
	return true
end

--- Forgets the interval start and every figure. Tests only.
function M._reset_for_test()
	_interval_start_ms = nil
	M.reset()
	M.use_clock(nil)
end

return M
