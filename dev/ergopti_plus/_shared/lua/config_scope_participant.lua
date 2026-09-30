--- _shared/lua/config_scope_participant.lua

--- ==============================================================================
--- MODULE: Synchronous Scope Participant
--- DESCRIPTION:
--- Adapts a scope owner whose operations settle before they return (every
--- config.toml owner built on config_scope_transaction) to the continuation
--- contract of config_scope_composition, so the composition can revert or
--- release exactly the owner that committed.
--- ==============================================================================

local M = {}

--- Wraps one synchronous scope owner provider.
--- @param ports table apply(mode) -> committed, detail (creates the owner) and
---   owner() -> the owner of the latest request, or nil before the first one.
--- @return table participant apply, revert, release, pending, retry_restore.
function M.synchronous(ports)
	assert(type(ports) == "table" and type(ports.apply) == "function" and type(ports.owner) == "function",
		"a synchronous scope participant requires apply and owner ports")
	local function current()
		local owner = ports.owner()
		assert(owner == nil or (type(owner) == "table" and type(owner.revert) == "function"
			and type(owner.release) == "function" and type(owner.pending) == "function"
			and type(owner.retry_restore) == "function"), "scope owner cannot take part in a composition")
		return owner
	end
	local participant = {}
	function participant.apply(mode, done)
		local committed, detail = ports.apply(mode)
		return done(committed == true, detail)
	end
	function participant.revert(done)
		local owner = current()
		if owner == nil then return done(false, "no committed scope to revert") end
		local reverted, detail = owner.revert()
		return done(reverted == true, detail)
	end
	function participant.release()
		local owner = current()
		if owner ~= nil then owner.release() end
	end
	function participant.pending()
		local owner = current()
		return owner ~= nil and owner.pending() == true
	end
	function participant.retry_restore(done)
		local owner = current()
		if owner == nil then return done(true) end
		return done(owner.retry_restore() == true)
	end
	return participant
end

return M
