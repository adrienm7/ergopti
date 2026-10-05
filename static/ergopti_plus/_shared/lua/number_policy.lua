--- _shared/lua/number_policy.lua
--- ==============================================================================
--- MODULE: Finite Number Policy
--- DESCRIPTION:
--- Pure numeric admission shared by runtime adapters. Rejects non-numbers,
--- infinities and NaN without imposing a native range or rounding policy.
--- ==============================================================================

local M = {}

--- Reports whether a value is a finite Lua number.
--- @param value any Candidate numeric value.
--- @return boolean finite True for numbers excluding infinities and NaN.
function M.is_finite(value)
	return type(value) == "number" and value == value
		and value ~= math.huge and value ~= -math.huge
end

return M
