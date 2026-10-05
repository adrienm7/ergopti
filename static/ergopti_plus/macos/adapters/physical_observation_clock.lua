--- adapters/physical_observation_clock.lua

--- Exposes the raw host nanosecond sample without fallback, offset or coercion.
local M = {}
local native = hs

--- Reads once and rejects native representation loss before the shared numeric port.
---@return integer observed_ns Raw nanoseconds in the native absolute clock domain.
function M.now()
	assert(native and native.timer and type(native.timer.absoluteTime) == "function",
		"Missing native observation clock")
	local observed_ns = native.timer.absoluteTime()
	assert(math.type(observed_ns) == "integer" and observed_ns >= 0,
		"Invalid native observation clock representation")
	return observed_ns
end

return M
