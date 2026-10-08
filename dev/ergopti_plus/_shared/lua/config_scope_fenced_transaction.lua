--- _shared/lua/config_scope_fenced_transaction.lua

--- ==============================================================================
--- MODULE: Fenced Configuration Transaction
--- DESCRIPTION:
--- Retains exact native claims and a primary inverse until runtime, source and
--- release acknowledgements settle. Native owners supply their existing ports;
--- no canceled user action, input device or asynchronous stop is replayed here.
--- ==============================================================================

local M = {}

--- Binds a synchronous primary transaction to its native configuration claims.
--- @param options table public owner, optional private native_token, transaction,
---   scope, ordered fences and
---   available() -> literal true while a new apply/revert is admitted.
--- @return table owner apply, revert, release, pending and retry_restore.
function M.new(options)
	assert(type(options) == "table" and type(options.owner) == "table"
		and type(options.transaction) == "table" and type(options.scope) == "string" and options.scope ~= ""
		and type(options.available) == "function" and type(options.fences) == "table" and #options.fences > 0,
		"a fenced transaction requires its exact owner, primary transaction and native ports")
	assert(options.native_token == nil or type(options.native_token) == "table", "a native claim token must be a table")
	local owner, transaction, ports = options.owner, options.transaction, {}
	-- Native primitives may inspect only their claim's primary compensation;
	-- the public owner still includes every in-flight stage and release debt.
	local native_token = options.native_token or owner
	for _, name in ipairs({ "apply", "revert", "release", "committed", "pending", "retry_restore" }) do
		assert(type(transaction[name]) == "function", "primary transaction lacks " .. name)
	end
	for index in pairs(options.fences) do
		assert(type(index) == "number" and index % 1 == 0 and index >= 1 and index <= #options.fences,
			"configuration claims require a dense ordered list")
	end
	for index = 1, #options.fences do
		local port = options.fences[index]
		assert(type(port) == "table" and type(port.acquire) == "function" and type(port.release) == "function",
			"configuration claims require explicit acquisition and release")
		ports[#ports + 1] = { acquire = port.acquire, release = port.release }
	end
	local held, inverse_owed, busy, release_claim_limit = {}, false, false, nil
	local function acquire(limit)
		for index = #held + 1, limit or #ports do
			local port = ports[index]
			local called, acquired = pcall(port.acquire, native_token)
			if not called or acquired ~= true then return false, "configuration acquisition remains pending" end
			held[#held + 1] = port
		end
		return true
	end
	local function reclaim_releases()
		if release_claim_limit then
			if acquire(release_claim_limit) ~= true then return false end
			release_claim_limit = nil
		end
		return true
	end
	local function release()
		if reclaim_releases() ~= true then return false, "configuration release ownership remains pending" end
		local claimed = #held
		for index = #held, 1, -1 do
			local called, released = pcall(held[index].release, native_token)
			if not called or released ~= true then
				if #held < claimed then
					-- A later refusal cannot leave an acknowledged admission gate
					-- open while this cohort still owns its sibling cleanup debt.
					release_claim_limit = claimed
					reclaim_releases()
				end
				return false, "configuration release remains pending"
			end
			held[index] = nil
		end
		return true
	end
	local function settle_inverse()
		if inverse_owed or transaction.pending() then
			if acquire() ~= true then return false, "configuration rollback ownership remains pending" end
			if inverse_owed then
				transaction.revert()
				inverse_owed = transaction.committed()
			end
			if inverse_owed or transaction.retry_restore() ~= true then return false, "configuration rollback remains pending" end
		end
		return release()
	end
	function owner.pending() return busy or inverse_owed or release_claim_limit ~= nil or #held > 0 or transaction.pending() end
	function owner.apply(mode)
		if owner.pending() or (mode ~= "clear" and mode ~= "recommended") then return false end
		busy = true
		local admitted, available = pcall(options.available)
		if not admitted or available ~= true then busy = false; return false, "configuration admission refused" end
		local acquired, detail = acquire()
		if acquired ~= true then release(); busy = false; return false, detail end
		local committed
		committed, detail = transaction.apply(options.scope, mode)
		if transaction.pending() then busy = false; return false, detail end
		local released, release_detail = release()
		if released ~= true then
			inverse_owed = committed == true
			if inverse_owed then settle_inverse() end
			busy = false
			return false, release_detail
		end
		busy = false
		return committed, detail
	end
	function owner.retry_restore()
		if busy then return false end
		busy = true
		local restored, detail = settle_inverse()
		busy = false
		return restored, detail
	end
	function owner.revert()
		if owner.pending() then return false, "configuration is already owned" end
		busy = true
		local admitted, available = pcall(options.available)
		if not admitted or available ~= true then busy = false; return false, "configuration admission refused" end
		inverse_owed = transaction.committed()
		if acquire() ~= true then busy = false; return false, "configuration rollback ownership remains pending" end
		local reverted, detail = transaction.revert()
		inverse_owed = transaction.committed()
		if transaction.pending() or inverse_owed then busy = false; return false, detail end
		local released, release_detail = release()
		busy = false
		if released ~= true then return false, release_detail end
		return reverted, detail
	end
	function owner.release()
		if owner.pending() then return false end
		transaction.release()
		return true
	end
	return owner
end

return M
