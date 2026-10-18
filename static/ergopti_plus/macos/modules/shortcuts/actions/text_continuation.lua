--- modules/shortcuts/actions/text_continuation.lua

--- ==============================================================================
--- MODULE: Text Continuation Admission
--- DESCRIPTION:
--- An optional caller-owned receipt may revoke a delayed text transform. Once
--- that receipt refuses, later timers cannot revive the same transformation;
--- clipboard cleanup remains owned by the text pipeline rather than the guard.
--- ==============================================================================

local M = {}

--- Builds a latched admission check without changing unguarded text actions.
--- @param check function|nil Exact current-context predicate.
--- @return function current True until the first refusal or exception.
function M.new(check)
	assert(check == nil or type(check) == "function", "text continuation must be a function or nil")
	local revoked = false
	return function()
		if revoked then return false end
		if check == nil then return true end
		local ok, current = pcall(check)
		if ok and current == true then return true end
		revoked = true
		return false
	end
end

return M
