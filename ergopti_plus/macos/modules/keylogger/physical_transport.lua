--- modules/keylogger/physical_transport.lua

--- Owns a physical stream until its exact task settles, including failed delivery.
local M = {}

--- Creates a single-use transport with explicit receiver and adapter ownership.
---@param dependencies table spawn, decode, encode, on_error, on_settled; receiver and frame_limit.
---@return table transport
function M.new(dependencies)
	for _, name in ipairs({ "spawn", "decode", "encode", "on_error", "on_settled" }) do
		assert(type(dependencies[name]) == "function", "Missing physical transport callback: " .. name)
	end
	local receiver, limit = dependencies.receiver, dependencies.frame_limit
	assert(type(receiver) == "table", "Missing physical receiver")
	assert(type(limit) == "number" and limit >= 1 and limit % 1 == 0, "Invalid physical frame limit")
	local state, handle, identity, failure = "new", nil, nil, nil
	local pending, dispatching = "", false
	local acquiring = false
	local transport = {}

	local function settled()
		if state == "settled" then return end
		receiver.stop()
		state, handle, pending = "settled", nil, ""
		dependencies.on_settled()
	end

	--- Revokes counting immediately; a retained task remains owned until settlement.
	---@return boolean accepted Whether termination was accepted.
	---@return string status Exact task termination status.
	function transport.stop()
		if state == "settled" then return true, "settled" end
		receiver.stop()
		state, pending = "stopping", ""
		if not handle then
			if acquiring then return false, "pending" end
			settled(); return true, "settled"
		end
		return handle.terminate()
	end

	local function fail(reason)
		if failure then return end
		failure = tostring(reason)
		transport.stop()
		dependencies.on_error(failure)
	end

	local function consume(line)
		local frame, decode_error = dependencies.decode(line)
		assert(decode_error == nil and type(frame) == "table", decode_error or "Invalid physical JSON frame")
		local sequence, baseline_page
		if not identity then
			-- Admission may invoke external code; retain the original wire identity.
			local candidate = { incarnation = frame.incarnation, lease = frame.lease }
			receiver.open(frame)
			identity, sequence = candidate, "0"
		elseif frame.kind == "baseline" or frame.kind == "baseline_ready" then
			sequence, baseline_page = receiver.baseline(frame), true
		else
			sequence = receiver.deliver(frame)
		end
		assert(state == "running" and receiver.active(), "Physical transport was revoked")
		if baseline_page and sequence == nil then return end
		assert(type(sequence) == "string", "Missing committed physical sequence")
		local acknowledgement = { version = 1, incarnation = identity.incarnation, lease = identity.lease }
		acknowledgement[baseline_page and "baseline_ack" or "ack"] = sequence
		local receipt, encode_error = dependencies.encode(acknowledgement)
		assert(encode_error == nil and type(receipt) == "string" and receipt ~= ""
			and not receipt:find("[\r\n]"), encode_error or "Invalid physical acknowledgement encoding")
		assert(state == "running" and receiver.active(), "Physical transport was revoked")
		assert(handle.set_input(receipt .. "\n") == true, "Physical acknowledgement write failed")
	end

	local function chunk(_, stdout)
		if state ~= "running" then return true end
		if dispatching then fail("Reentrant physical stream callback"); return true end
		dispatching = true
		local ok, err = pcall(function()
			assert(type(stdout) == "string", "Invalid physical stream chunk")
			local offset = 1
			while offset <= #stdout do
				local newline = stdout:find("\n", offset, true)
				local last = newline and newline - 1 or #stdout
				assert(#pending + last - offset + 1 <= limit, "Physical frame exceeds limit")
				pending = pending .. stdout:sub(offset, last)
				if not newline then return end
				local line = pending
				pending = ""
				consume(line)
				offset = newline + 1
			end
		end)
		dispatching = false
		if not ok then fail(err) end
		return true
	end

	--- Starts one supervised task; errors revoke delivery before reporting failure.
	---@param executable string Absolute capture executable path.
	---@param arguments table Capture command arguments.
	---@return boolean started
	function transport.start(executable, arguments)
		assert(state == "new", "Physical transport cannot restart")
		state = "running"
		acquiring = true
		local ok, err = pcall(function()
			handle = dependencies.spawn(executable, arguments, function(code)
				if state ~= "stopping" and state ~= "settled" then
					fail("Physical stream exited before shutdown: " .. tostring(code))
				end
			end, chunk)
			acquiring = false
			assert(type(handle) == "table", "Physical task was not created")
			assert(handle.onSettled(settled) == true, "Physical task settlement observer refused")
			assert(state == "running", "Physical task settled before start")
			assert(handle.start() == true, "Physical task start failed")
		end)
		acquiring = false
		if not ok then
			-- Retire a returned handle even if an earlier callback already reported failure.
			if failure then transport.stop() else fail(err) end
		end
		return state == "running"
	end

	--- Reports actual native settlement, not merely a requested stop.
	---@return boolean
	function transport.isSettled() return state == "settled" end

	return transport
end

return M
