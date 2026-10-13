--- _shared/lua/keylogger/physical_release.lua

--- Pure duration validation and hold accounting for approved physical releases.
--- Capture identity, matching, privacy and event attribution belong to the caller.
local M = {}

--- Largest millisecond delta representable by the signed-64 nanosecond converter.
--- The derived bound is exactly representable even on a double-only Lua runtime.
M.MAX_HOLD_MS = math.floor((2 ^ 63 - 1) / 1000000)

--- Requires a finite nonnegative integer duration in milliseconds.
---@param hold_ms number Original HID-derived duration.
---@return number hold_ms Validated duration.
function M.duration(hold_ms)
	assert(type(hold_ms) == "number" and hold_ms >= 0 and hold_ms <= M.MAX_HOLD_MS and hold_ms % 1 == 0,
		"Physical release requires nonnegative integer hold_ms")
	return hold_ms
end

--- Adds one release to an existing hold row without crediting another press.
---@param row table Hold sum, count, maximum and tap/hold counters.
---@param hold_ms number Original HID-derived duration.
---@param threshold_ms number Shared tap/hold boundary, inclusive for taps.
function M.accumulate(row, hold_ms, threshold_ms)
	M.duration(hold_ms)
	row.sum_ms, row.count = row.sum_ms + hold_ms, row.count + 1
	row.max_ms = math.max(row.max_ms, hold_ms)
	if hold_ms <= threshold_ms then row.tap_count = row.tap_count + 1
	else row.hold_count = row.hold_count + 1 end
end

return M
