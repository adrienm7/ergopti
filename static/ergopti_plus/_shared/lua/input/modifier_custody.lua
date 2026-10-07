--- _shared/lua/input/modifier_custody.lua

--- ==============================================================================
--- MODULE: Shared Source-Aware Output Custody
--- DESCRIPTION:
--- Serializes original and synthetic ownership through captured transport ports.
--- A software ACK is not a kernel lease or evidence of physical delivery.
--- ==============================================================================

local M = {}

local function codes(set)
	local result = {}
	for code in pairs(set) do result[#result + 1] = code end
	table.sort(result)
	return result
end

local function equal(left, right)
	if #left ~= #right then return false end
	for index, code in ipairs(left) do if right[index] ~= code then return false end end
	return true
end

function M.new(writer, capability)
	local owners, down = {}, {}
	local epoch
	if capability then
		if type(writer) ~= "table" or type(writer.output_view) ~= "function" then return nil end
		local ok, initial = pcall(writer.output_view, capability)
		if not ok or type(initial) ~= "table" or type(initial.down) ~= "table"
			or next(initial.down) ~= nil or type(initial.write_epoch) ~= "number"
			or initial.write_epoch < 0 or initial.write_epoch % 1 ~= 0 then return nil end
		epoch = initial.write_epoch
	end
	local busy, debt, pending = false, false, {}
	local reservation = nil
	local lifted = {}
	local broker = {}

	local function reserve()
		if debt or busy then return nil end
		if not capability then busy = true; return {} end
		local view = writer.output_view(capability)
		if not view or view.write_epoch ~= epoch or not equal(view.down, codes(down)) then debt = true; return nil end
		local token = writer.acquire_transaction(capability)
		if token then busy = true; reservation = token end
		return token
	end

	local function commit(token)
		if capability then
			local view = writer.transaction_view(token)
			if not view or not equal(view.down, codes(down)) or not writer.commit_transaction(token, codes(down)) then
				debt = true; return false
			end
			epoch = view.write_epoch
		end
		busy = false
		reservation = nil
		return true
	end

	local function wire(token, code, value, callback)
		local ok
		if capability then
			if callback then ok = writer.dispatch_transaction(token, callback, code, value)
			else ok = writer.transaction_emit(token, code, value) end
		else
			local called, accepted = pcall(callback, code, value)
			ok = called and accepted == true
		end
		if not ok then debt = true; return false end
		if value == 1 then down[code] = true elseif value == 0 then down[code] = nil end
		return true
	end

	local function active(code, except)
		for owner, row in pairs(owners) do
			if owner ~= except and row.code == code and row.state == "held" then return true end
		end
		return false
	end

	local function edge(token, owner, code, value, callback)
		local row = owners[owner]
		local disposition, writes = "ownership", 0
		if value == 1 then
			if row then return { ok = row.code == code, native_writes = 0, disposition = "duplicate" } end
			owners[owner] = { code = code, state = "held" }
			if not down[code] then
				if not wire(token, code, 1, callback) then return { ok = false, native_writes = 1, disposition = "debt" } end
				writes = 1
			end
		elseif value == 0 then
			if not row then return { ok = true, native_writes = 0, disposition = "unmatched" } end
			if row.code ~= code then return { ok = false, native_writes = 0, disposition = "refused" } end
			if row.state == "held" and not active(code, owner) and down[code] then
				if not wire(token, code, 0, callback) then return { ok = false, native_writes = 1, disposition = "debt" } end
				writes = 1
			end
			disposition = row.state == "spent" and "spent-retirement" or "ownership"
			owners[owner] = nil
		elseif value == 2 then
			if not row or row.code ~= code then return { ok = false, native_writes = 0, disposition = "refused" } end
			if row.state == "held" and down[code] then
				if not wire(token, code, 2, callback) then return { ok = false, native_writes = 1, disposition = "debt" } end
				writes = 1
			else disposition = "spent-repeat" end
		else return { ok = false, native_writes = 0, disposition = "refused" } end
		return { ok = true, native_writes = writes, disposition = disposition }
	end

	local function drain(token)
		while not debt and #pending > 0 do
			local row = table.remove(pending, 1)
			if not edge(token, row[1], row[2], row[3], row[4]).ok then debt = true end
		end
		return not debt
	end

	local function surviving(exact)
		local remaining = {}
		for owner, row in pairs(exact) do
			if owners[owner] == row then
				if row.state ~= "suspended" then debt = true; return nil end
				remaining[owner] = row
			end
		end
		return remaining
	end

	--- Settles one original source/key or synthetic producer/key edge.
	--- Reentrant retirement queues only an existing holder's release.
	--- @param owner table Exact opaque private owner identifier.
	--- @param code integer Keycode.
	--- @param value integer Native transition.
	--- @param callback function|nil Exact raw forwarding adapter.
	--- @return table receipt Explicit wire count and ownership disposition.
	function broker.edge(owner, code, value, callback)
		if type(owner) ~= "table" then return { ok = false, native_writes = 0, disposition = "owner" } end
		if busy then
			if not debt and value == 0 and owners[owner] and owners[owner].code == code then
				pending[#pending + 1] = { owner, code, value, callback }
				return { ok = true, native_writes = 0, disposition = "queued-retirement" }
			end
			return { ok = false, native_writes = 0, disposition = "busy" }
		end
		local token = reserve()
		if not token then return { ok = false, native_writes = 0, disposition = "currency" } end
		local result = edge(token, owner, code, value, callback)
		if result.ok then result.ok = drain(token) end
		if result.ok then result.ok = commit(token) else debt = true end
		return result
	end

	--- Settles an engine's explicitly typed temporary owner handoff.
	--- @param code integer Aggregate acknowledged key.
	--- @param state string "suspended" or "restored".
	--- @param callback function Exact raw adapter.
	--- @return table receipt
	function broker.handoff(code, state, callback)
		local token = reserve()
		if not token then return { ok = false, native_writes = 0 } end
		local writes, accepted = 0, false
		if state == "suspended" and not lifted[code] and down[code] then
			local exact = {}
			for owner, row in pairs(owners) do
				if row.code == code and row.state == "held" then exact[owner] = row end
			end
			if next(exact) and wire(token, code, 0, callback) then
				for _, row in pairs(exact) do row.state = "suspended" end
				lifted[code], writes, accepted = exact, 1, true
			end
		elseif state == "restored" and lifted[code] and not down[code] then
			local exact = surviving(lifted[code])
			if exact and next(exact) == nil then
				lifted[code], accepted = nil, true
			elseif exact and wire(token, code, 1, callback) then
				for _, row in pairs(exact) do row.state = "held" end
				lifted[code], writes, accepted = nil, 1, true
			end
		end
		if accepted then accepted = drain(token) end
		if not accepted then debt = true end
		return { ok = accepted and commit(token), native_writes = writes, disposition = state }
	end

	--- Reserves synthetic delivery and typed original-owner handoffs.
	--- @return table|nil session Exact checked channel proxy.
	function broker.begin()
		local token = reserve()
		if not token then return nil end
		local suspended, synthetic, finished = {}, {}, false
		local session = {}
		local function emit(code, value)
			if finished or debt or (value ~= 0 and value ~= 1) then return false end
			if value == 1 then
				if down[code] then return false end
				if not wire(token, code, value) then return false end
				synthetic[code] = true
			else
				if not down[code] then return true end
				if not wire(token, code, value) then return false end
				if synthetic[code] then synthetic[code] = nil
				else
					for _, row in pairs(owners) do
						if row.code == code and row.state == "held" then row.state = "spent" end
					end
				end
			end
			return true
		end
		function session.neutralize(code)
			if finished or debt or not drain(token) then return false end
			if suspended[code] then return true end
			if not down[code] then return true end
			local exact = {}
			for owner, row in pairs(owners) do
				if row.code == code and row.state == "held" then exact[owner] = row end
			end
			if next(exact) == nil then return false end
			if not wire(token, code, 0) then return false end
			for _, row in pairs(exact) do row.state = "suspended" end
			suspended[code] = exact
			return true
		end
		function session.restore(code)
			if finished or debt or not drain(token) then return false end
			local exact = suspended[code]
			if not exact then return true end
			exact = surviving(exact)
			if not exact then return false end
			if next(exact) == nil then suspended[code] = nil; return true end
			if down[code] or not wire(token, code, 1) then return false end
			for _, row in pairs(exact) do row.state = "held" end
			suspended[code] = nil
			return drain(token)
		end
		function session.finish()
			if finished or debt or not drain(token) then return false end
			if next(suspended) or next(synthetic) then debt = true; return false end
			finished = true
			return commit(token)
		end
		function session.borrow(code)
			return not finished and not debt and drain(token) and down[code] == true
		end
		function session.is_open() return not finished and not debt and (not capability or writer.transaction_current(token)) end
		session.emit = emit
		return session
	end

	--- Retires only this broker's exact transport after unresolved output debt.
	--- @return boolean acknowledged
	function broker.retire()
		if not capability then return false end
		if reservation then return writer.retire_transaction(reservation) == true end
		return writer.close_owned(capability) == true
	end

	function broker.has_debt() return debt end
	function broker.view()
		local result = { down = codes(down), busy = busy, debt = debt, owners = {} }
		for owner, row in pairs(owners) do result.owners[owner] = { code = row.code, state = row.state } end
		return result
	end
	return broker
end

return M
