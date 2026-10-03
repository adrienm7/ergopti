--- _shared/lua/llm/display_policy.lua

--- ==============================================================================
--- MODULE: Prediction Display Polarity
--- DESCRIPTION:
--- Keeps the canonical progressive preference opposite to the native show-all
--- checkbox. Drivers retain persistence, readiness and presentation ownership.
--- ==============================================================================

local M = {}





-- =================================
-- =================================
-- =================================
-- =================================
-- =================================

--- Converts the canonical progressive preference to the show-all checkbox.
--- @param progressive boolean
--- @return boolean
function M.show_all(progressive)
	assert(type(progressive) == "boolean", "progressive display must be boolean")
	return not progressive
end

--- Converts a native show-all preference back to canonical progressive display.
--- @param show_all boolean
--- @return boolean
function M.progressive(show_all)
	return M.show_all(show_all)
end

--- Whether a current native owner may change the multi-prediction display mode.
--- @param count number
--- @param blocked boolean
--- @return boolean
function M.ready(count, blocked)
	return blocked == false and type(count) == "number"
		and count == math.floor(count) and count >= 2
end

return M
