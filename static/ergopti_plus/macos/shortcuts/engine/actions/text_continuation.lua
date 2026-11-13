--- shortcuts/engine/actions/text_continuation.lua

--- ==============================================================================
--- MODULE: Text Continuation Admission
--- DESCRIPTION:
--- An optional caller-owned receipt may revoke a delayed text transform. Once
--- that receipt refuses, later timers cannot revive the same transformation;
--- clipboard cleanup remains owned by the text pipeline rather than the guard.
--- ==============================================================================

local M = {}

--- Captures the currently classified native destination without probing AX.
--- Full verification remains the deferred producer's responsibility.
--- @return table|nil publication
function M.capture_destination()
	-- A tracker that has not already loaded cannot own a classified destination.
	-- Never load its dependency graph on an input callback.
	local utils = package.loaded["hotstrings.engine.expander.utils"]
	if type(utils) ~= "table" or type(utils.capture_text_destination) ~= "function"
		or type(utils.owns_text_destination) ~= "function" then return nil end
	local receipt = utils.capture_text_destination()
	if type(receipt) ~= "table" or type(receipt.pid) ~= "number"
		or math.tointeger(receipt.pid) == nil or receipt.pid <= 0
		or type(receipt.window_id) ~= "number" or math.tointeger(receipt.window_id) == nil
		or receipt.window_id <= 0 or type(receipt.generation) ~= "number"
		or receipt.element == nil then return nil end
	local function cached()
		local current = utils.capture_text_destination()
		return current ~= nil and current.generation == receipt.generation
			and current.pid == receipt.pid and current.window_id == receipt.window_id
			and current.element == receipt.element
	end
	return { cached = cached, current = function()
		return cached() and utils.owns_text_destination(receipt) == true and cached()
	end }
end

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
