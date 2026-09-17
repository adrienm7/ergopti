--- modules/keylogger/physical_delivery.lua

--- Delivers decoded physical batches under an explicitly admitted capture owner.
--- Transport framing, native coverage admission and timestamp context belong to callers.
local M = {}
local Wire = require("modules.keylogger.physical_wire")
local Baseline = require("modules.keylogger.physical_baseline")
local decimal, successor = Wire.decimal, Wire.successor

--- Creates a single-use receiver; a stopped or failed owner cannot be reopened.
--- The keycode callback receives usage and the exact decimal device identity.
---@param dependencies table admit, context, keycode and emit callbacks; batch_limit.
---@return table receiver
function M.new(dependencies)
	for _, name in ipairs({ "admit", "context", "keycode", "emit" }) do
		assert(type(dependencies[name]) == "function", "Missing physical delivery callback: " .. name)
	end
	local limit = dependencies.batch_limit
	assert(type(limit) == "number" and limit >= 1 and limit % 1 == 0, "Invalid physical batch limit")
	local state, ownership, sequence = "new", nil, "0"
	local initial
	local receiver = {}

	--- Returns whether this receiver still owns delivery.
	---@return boolean
	function receiver.active() return state == "baselining" or state == "active" or state == "delivering" end

	--- Revokes delivery before any successor capture can begin.
	function receiver.stop() state, ownership, initial = "stopped", nil, nil end

	--- Admits a producer envelope through the caller's coverage and privacy owner.
	---@param frame table Decoded opened frame.
	function receiver.open(frame)
		assert(state == "new", "Physical receiver cannot reopen")
		state = "failed"
		assert(type(frame) == "table" and frame.version == 1 and frame.kind == "opened"
			and type(frame.incarnation) == "string" and frame.incarnation ~= ""
			and type(frame.coverage) == "string", "Invalid physical opening envelope")
		decimal(frame.lease, true)
		initial = Baseline.new(frame.baseline)
		local owner = { incarnation = frame.incarnation, lease = frame.lease, coverage = frame.coverage }
		local capture = dependencies.admit(frame)
		assert(type(capture) == "string" and capture ~= "", "Physical coverage was not admitted")
		assert(state == "failed", "Physical admission was revoked")
		owner.capture = capture
		ownership = owner
		state = "baselining"
	end

	--- Receives initial-state pages before raw delivery can publish any credit.
	---@param frame table Baseline page or completion marker.
	---@return string|nil cursor Page cursor to acknowledge; completion needs no receipt.
	function receiver.baseline(frame)
		local ok, result = pcall(function()
			assert(state == "baselining", "Physical baseline is not pending")
			assert(type(frame) == "table" and frame.version == 1
				and frame.incarnation == ownership.incarnation and frame.lease == ownership.lease
				and frame.coverage == ownership.coverage, "Physical capture ownership changed or ended")
			local cursor = initial.accept(frame)
			if initial.ready() then state = "active" end
			return cursor
		end)
		if not ok then state, ownership, initial = "failed", nil, nil; error(result, 0) end
		return result
	end

	--- Validates the entire batch before publishing any physical press.
	--- A callback failure fences this owner rather than replaying partial publication.
	---@param frame table Decoded batch from the admitted producer session.
	---@return string sequence Last fully committed sequence, suitable for acknowledgement.
	function receiver.deliver(frame)
		if state ~= "active" then
			state, ownership, initial = "failed", nil, nil
			error("Physical receiver is not active")
		end
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
				local physical_press = initial.press(row)
				if row.has_page and row.has_usage and row.page == 7 and row.usage >= 4 and row.usage <= 255 then
					if physical_press then
						local keycode = dependencies.keycode(row.usage, row.device)
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
			state, ownership, initial = "failed", nil, nil
			error(err, 0)
		end
		state = "active"
		return sequence
	end

	return receiver
end

return M
