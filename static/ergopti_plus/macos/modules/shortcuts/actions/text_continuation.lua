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
--- @param check function|table|nil Exact predicate or full/cached publication receipt.
--- @return function current True until the first refusal or exception.
--- @return function|nil cached RAM-only predicate when a publication receipt was supplied.
function M.new(check)
	local publication = type(check) == "table" and check or nil
	assert(check == nil or type(check) == "function" or (publication
		and type(publication.current) == "function" and type(publication.cached) == "function"),
		"text continuation requires a function, publication receipt or nil")
	local revoked = false
	local function allowed(predicate)
		if revoked then return false end
		if predicate == nil then return true end
		local ok, current = pcall(predicate)
		if ok and current == true then return true end
		revoked = true
		return false
	end
	local current = function() return allowed(publication and publication.current or check) end
	local cached = publication and function() return allowed(publication.cached) end or nil
	return current, cached
end

return M
