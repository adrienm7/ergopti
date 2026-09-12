--- modules/keylogger/physical_delivery.lua

--- Delivers decoded physical batches under an explicitly admitted capture owner.
--- Transport framing, native coverage admission and timestamp context belong to callers.
local M = {}
local UINT64_MAX = "18446744073709551615"

local function decimal(value, positive)
	assert(type(value) == "string" and value:match("^%d+$")
		and (value == "0" or value:sub(1, 1) ~= "0")
		and (#value < #UINT64_MAX or (#value == #UINT64_MAX and value <= UINT64_MAX))
		and (not positive or value ~= "0"), "Invalid physical decimal identifier")
	return value
end

local function successor(value)
	assert(value ~= UINT64_MAX, "Physical sequence exhausted")
	local prefix, suffix = value:match("^(.-)(9*)$")
	if prefix == "" then return "1" .. string.rep("0", #suffix) end
	return prefix:sub(1, -2) .. tostring(tonumber(prefix:sub(-1)) + 1) .. string.rep("0", #suffix)
end

--- Creates a single-use receiver; a stopped or failed owner cannot be reopened.
---@param dependencies table admit, context, keycode and emit callbacks; batch_limit.
---@return table receiver
function M.new(dependencies)
	for _, name in ipairs({ "admit", "context", "keycode", "emit" }) do
		assert(type(dependencies[name]) == "function", "Missing physical delivery callback: " .. name)
	end
	local limit = dependencies.batch_limit
	assert(type(limit) == "number" and limit >= 1 and limit % 1 == 0, "Invalid physical batch limit")
	local state, ownership, sequence = "new", nil, "0"
	local receiver = {}

	--- Returns whether this receiver still owns delivery.
	---@return boolean
	function receiver.active() return state == "active" or state == "delivering" end

	--- Revokes delivery before any successor capture can begin.
	function receiver.stop() state, ownership = "stopped", nil end

	--- Admits a producer envelope through the caller's coverage and privacy owner.
	---@param frame table Decoded opened frame.
	function receiver.open(frame)
		assert(state == "new", "Physical receiver cannot reopen")
		state = "failed"
		assert(type(frame) == "table" and frame.version == 1 and frame.kind == "opened"
			and type(frame.incarnation) == "string" and frame.incarnation ~= ""
			and type(frame.coverage) == "string", "Invalid physical opening envelope")
		decimal(frame.lease, true)
		local owner = { incarnation = frame.incarnation, lease = frame.lease, coverage = frame.coverage }
		local capture = dependencies.admit(frame)
		assert(type(capture) == "string" and capture ~= "", "Physical coverage was not admitted")
		assert(state == "failed", "Physical admission was revoked")
		owner.capture = capture
		ownership = owner
		state = "active"
	end

	--- Validates the entire batch before publishing any physical press.
	--- A callback failure fences this owner rather than replaying partial publication.
	---@param frame table Decoded batch from the admitted producer session.
	---@return string sequence Last fully committed sequence, suitable for acknowledgement.
	function receiver.deliver(frame)
		assert(state == "active", "Physical receiver is not active")
		local owner = ownership
		state = "delivering"
		local ok, err = pcall(function()
			assert(type(frame) == "table" and frame.version == 1 and frame.kind == "batch"
				and frame.incarnation == owner.incarnation and frame.lease == owner.lease
				and frame.coverage == owner.coverage, "Physical capture ownership changed or ended")
			assert(type(frame.records) == "table" and #frame.records <= limit, "Invalid physical batch")
			local length = #frame.records
			for key in pairs(frame.records) do
				assert(type(key) == "number" and key % 1 == 0 and key >= 1 and key <= length,
					"Physical batch must be a dense array")
			end
			local next_sequence, pending = sequence, {}
			for index = 1, length do
				local row = frame.records[index]
				assert(type(row) == "table", "Missing physical record")
				decimal(row.sequence, true)
				assert(row.sequence == successor(next_sequence), "Physical sequence gap or replay")
				next_sequence = row.sequence
				decimal(row.device, true)
				decimal(row.timestamp, false)
				assert(type(row.has_page) == "boolean" and type(row.has_usage) == "boolean"
					and type(row.page) == "number" and type(row.usage) == "number"
					and row.page % 1 == 0 and row.usage % 1 == 0, "Invalid physical usage")
				if row.has_page and row.has_usage and row.page == 7 and row.usage >= 1 and row.usage <= 3 then
					assert(row.value == "0", "Active physical keyboard error")
				end
				if row.has_page and row.has_usage and row.page == 7 and row.usage >= 4 and row.usage <= 255 then
					assert(row.value == "0" or row.value == "1", "Unqualified physical key value")
					if row.value == "1" then
						local keycode = dependencies.keycode(row.usage)
						assert(type(keycode) == "number" and keycode >= 0 and keycode % 1 == 0,
							"Unsupported physical key usage")
						local context = dependencies.context(row.timestamp, row.device)
						assert(type(context) == "table" and type(context.allowed) == "boolean",
							"Physical event context is unavailable")
						if context.allowed then
							assert(type(context.app) == "string" and context.app ~= ""
								and type(context.timestamp) == "string" and context.timestamp ~= "",
								"Physical event context is incomplete")
							pending[#pending + 1] = { capture = owner.capture, device = row.device,
								keycode = keycode, app = context.app, timestamp = context.timestamp }
						end
					end
				end
			end
			for _, press in ipairs(pending) do
				assert(state == "delivering" and ownership == owner, "Physical delivery was revoked")
				dependencies.emit(press)
			end
			assert(state == "delivering" and ownership == owner, "Physical delivery was revoked")
			sequence = next_sequence
		end)
		if not ok then
			state, ownership = "failed", nil
			error(err, 0)
		end
		state = "active"
		return sequence
	end

	return receiver
end

return M
