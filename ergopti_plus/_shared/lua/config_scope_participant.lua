--- _shared/lua/config_scope_participant.lua

--- ==============================================================================
--- MODULE: Synchronous Scope Participant
--- DESCRIPTION:
--- Adapts a scope owner whose operations settle before they return to the
--- continuation contract of config_scope_composition. The exact request owner
--- retains its inverse even when a later request replaces the provider's owner.
--- ==============================================================================

local M = {}

--- Wraps one synchronous scope owner provider.
--- @param ports table apply(mode) -> committed, detail (creates the owner) and
---   owner() -> the owner of the latest request, or nil before the first one.
--- @return table participant apply, revert, release, pending, retry_restore.
function M.synchronous(ports)
	assert(type(ports) == "table" and type(ports.apply) == "function" and type(ports.owner) == "function",
		"a synchronous scope participant requires apply and owner ports")
	local cohort, committed, applying, missing = nil, false, false, false
	local function provider()
		local owner = ports.owner()
		assert(owner == nil or (type(owner) == "table" and type(owner.revert) == "function"
			and type(owner.release) == "function" and type(owner.pending) == "function"
			and type(owner.retry_restore) == "function"), "scope owner cannot take part in a composition")
		return owner
	end
	local participant = {}
	function participant.pending()
		if applying or missing then return true end
		local owner = cohort or provider()
		return owner ~= nil and owner.pending() ~= false
	end
	function participant.apply(mode, done)
		if applying or missing or committed then
			return done(false, "the participant retains an unsettled request")
		end
		applying = true
		local admitted, latest = pcall(function()
			if cohort ~= nil and cohort.pending() ~= false then return false end
			local owner = provider()
			return owner == nil or owner.pending() == false
		end)
		if not admitted or latest ~= true then
			applying = false
			return done(false, admitted and "the current scope provider retains unsettled debt" or tostring(latest))
		end
		local called, ok, detail = pcall(ports.apply, mode)
		local captured, owner = pcall(provider)
		applying = false
		cohort, committed = captured and owner or nil, false
		if not captured or (cohort == nil and (ok == true or not called)) then
			missing = true
			return done(false, "the scope request did not retain a valid owner")
		end
		if not called then return done(false, tostring(ok)) end
		committed = ok == true
		return done(committed, detail)
	end
	function participant.revert(done)
		if applying or missing then return done(false, "the scope request owner is unavailable") end
		if cohort == nil then return done(false, "no committed scope to revert") end
		local reverted, detail = cohort.revert()
		if reverted == true then committed = false end
		return done(reverted == true, detail)
	end
	function participant.release()
		if applying or missing or (cohort ~= nil and cohort.pending() ~= false) then return false end
		if cohort ~= nil then
			-- Existing void release ports return nil on success; literal false
			-- explicitly refuses and must retain this exact inverse. Other types
			-- cannot acknowledge the supported void-or-boolean release contract.
			local released, detail = cohort.release()
			if released ~= nil and released ~= true then return false, detail or "scope inverse release refused" end
		end
		cohort, committed = nil, false
	end
	function participant.retry_restore(done)
		if applying or missing then return done(false, "the scope request owner is unavailable") end
		if cohort == nil then return done(true) end
		if committed and cohort.pending() == false then
			return done(false, "the committed scope still requires its inverse")
		end
		local restored, detail = cohort.retry_restore()
		if restored == true then cohort, committed = nil, false end
		return done(restored == true, detail)
	end
	return participant
end

return M
