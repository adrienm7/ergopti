--- _shared/lua/gestures/sensitivity.lua

--- ==============================================================================
--- MODULE: Gesture Sensitivity Range
--- DESCRIPTION:
--- Owns the menu choices and the safe range for incremental swipe distances,
--- in millimetres, for the macOS engine and the Linux gesture manager alike.
--- ==============================================================================

local M = {}
local OPTIONS = { 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0, 6.0,
	7.0, 8.0, 10.0, 12.0, 15.0, 20.0, 25.0, 30.0, 40.0, 50.0, 60.0 }

--- Returns the supported range's menu values without exposing the source table.
--- @return table values
function M.options()
	local result = {}
	for index, value in ipairs(OPTIONS) do result[index] = value end
	return result
end

--- Coerces a sensitivity within the supported range, or rejects it.
--- @param value any Candidate sensitivity.
--- @return number|nil sensitivity
function M.coerce(value)
	local number = tonumber(value)
	if type(number) ~= "number" or number < OPTIONS[1] or number > OPTIONS[#OPTIONS]
		or number ~= number then return nil end
	return number
end

return M
