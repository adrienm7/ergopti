--- _shared/lua/dynamic_hotstrings/menu_publication.lua

--- ==============================================================================
--- MODULE: Programmable Menu Publication
--- DESCRIPTION:
--- Joins native configuration revisions with acknowledged preference publication.
--- Failed inverses retain the exact native snapshot across menu rebuilds.
--- ==============================================================================

local M = {}

--- Creates one native menu's retained configuration inverse owner.
--- @return table publication Scoped runtime and preference publication API.
function M.new()
	local pending
	local publication = {}
	local function restore()
		if not pending then return true end
		local called, accepted = pcall(pending.native.user_code_scope_restore, pending.snapshot)
		if not called or accepted ~= true then return false end
		pending = nil
		return true
	end

	--- Publishes scalar intent without discarding callbacks on a refused save.
	--- @param native table Actual programmable facade with revision-bound scope ports.
	--- @param enabled boolean Requested source activation.
	--- @param seconds number Requested activation interval.
	--- @param persist function Exact durable preferences publisher.
	--- @return boolean committed
	function publication.commit(native, enabled, seconds, persist)
		if pending and pending.native ~= native then return false end
		if restore() ~= true or type(native.user_code_scope_snapshot) ~= "function"
			or type(native.user_code_scope_adopt) ~= "function"
			or type(native.user_code_scope_restore) ~= "function" then return false end
		local captured, snapshot = pcall(native.user_code_scope_snapshot)
		if not captured or type(snapshot) ~= "table" then return false end
		pending = { native = native, snapshot = snapshot }
		local applied, accepted = pcall(native.user_code_scope_adopt, snapshot, seconds, enabled)
		if applied and accepted == true then
			local written, committed = pcall(persist)
			if written and committed == true then pending = nil; return true end
		end
		restore()
		return false
	end

	--- Reports retained native inverse debt without granting further mutation.
	--- @return boolean retained
	function publication.pending() return pending ~= nil end
	return publication
end

return M
