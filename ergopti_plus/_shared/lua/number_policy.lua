--- _shared/lua/number_policy.lua
--- ==============================================================================
--- MODULE: Finite Number Policy
--- DESCRIPTION:
--- Pure numeric admission shared by runtime adapters. Rejects non-numbers,
--- infinities and NaN, and owns the one ceiling every relative timer delay
--- must respect before any driver converts it to a native integer. The
--- boundary vectors live in _shared/tests/corpus/timer/delay_ceiling_vectors.json.
--- ==============================================================================

local M = {}

--- Longest relative timer delay any driver arms, in milliseconds (2^53).
--- Every integer up to it is exact in a double, so each runtime converts it
--- to its native integer without loss. Above it the runtimes disagree: Lua 5.4
--- refuses the integer conversion past 2^63, while LuaJIT's conversion of a
--- double beyond the native range is undefined and armed a timer that never
--- fired. One finite ceiling makes the refusal identical everywhere.
M.MAX_TIMER_DELAY_MS = 2 ^ 53

--- Reports whether a value is a finite Lua number.
--- @param value any Candidate numeric value.
--- @return boolean finite True for numbers excluding infinities and NaN.
function M.is_finite(value)
	return type(value) == "number" and value == value
		and value ~= math.huge and value ~= -math.huge
end

--- Reports whether a relative delay in milliseconds may reach a native timer.
--- Only the upper bound is owned here: each caller keeps its own lower bound,
--- clamping a negative delay to zero or refusing it as its contract says.
--- @param milliseconds any Candidate delay in milliseconds.
--- @return boolean admitted True for a finite delay not above the ceiling.
function M.within_timer_ceiling(milliseconds)
	return M.is_finite(milliseconds) and milliseconds <= M.MAX_TIMER_DELAY_MS
end

--- Converts a relative delay in seconds to admitted milliseconds.
--- The product is taken in floating point: Lua 5.4 multiplies two integers
--- in wrapping integer arithmetic, so a huge integer second count turned
--- negative and armed a timer that fired at once.
--- @param seconds any Candidate delay in seconds.
--- @return number|nil milliseconds Unrounded delay, or nil when refused.
function M.timer_delay_ms(seconds)
	if not M.is_finite(seconds) then return nil end
	local milliseconds = seconds * 1000.0
	if not M.within_timer_ceiling(milliseconds) then return nil end
	return milliseconds
end

return M
