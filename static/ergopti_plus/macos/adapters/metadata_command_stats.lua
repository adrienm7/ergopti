--- adapters/metadata_command_stats.lua

--- ==============================================================================
--- MODULE: Synchronous Metadata Command Counter
--- DESCRIPTION:
--- Every atomic publication of an existing file forks shell commands from the
--- Hammerspoon process (ACL listing, metadata-preserving copy) and waits for
--- them on the main thread. The slow ingest and slow preferences save reports
--- read this counter so a field log says how much of a hold those forks cost
--- (Mac field ledger L16, L17). It holds two numbers and never any path.
--- ==============================================================================

local M = {}

local NANOSECONDS_PER_MILLISECOND = 1000000
local _count, _ns = 0, 0

--- Reads the monotonic clock, or nil when the host has none (headless runs).
--- @return number|nil nanoseconds
function M.clock()
	local host_timer = type(hs) == "table" and hs.timer or nil
	if type(host_timer) ~= "table" or type(host_timer.absoluteTime) ~= "function" then return nil end
	return host_timer.absoluteTime()
end

--- Counts one finished command and charges its duration when it was timed.
--- @param started number|nil Value of M.clock() before the command.
function M.record(started)
	_count = _count + 1
	local now = started and M.clock()
	if now then _ns = _ns + (now - started) end
end

--- Returns the cumulative command count and wall-clock milliseconds.
--- @return integer count Commands run since load.
--- @return number ms Milliseconds spent waiting for them.
function M.snapshot()
	return _count, _ns / NANOSECONDS_PER_MILLISECOND
end

return M
