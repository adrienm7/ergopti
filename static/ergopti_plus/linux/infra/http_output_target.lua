--- infra/http_output_target.lua

--- Private, one-attempt stdout sink. No descriptor/path is exposed to curl.
--- Output lease owns filesystem writes; the sole core owns input/process ACKs.
local M = {}
local function byte_count(value)
	return type(value) == "number" and value >= 0 and value % 1 == 0 and value <= 9007199254740991
end
local targets = {}
local completions = setmetatable({}, { __mode = "k" })

local function copy_receipt(receipt)
	if type(receipt) ~= "table" then return nil end
	local result = {}
	for key, value in next, receipt do
		if type(value) ~= "table" then result[key] = value end
	end
	return result
end

--- Registers one exact native output attempt, never a public page payload.
function M.create(lease, ticket)
	if type(lease) ~= "table" or ticket == nil then return nil end
	for _, name in ipairs({ "bind_input", "write", "write_pending", "resume_admit", "eof", "cancel", "failure", "bytes", "on_settled" }) do
		if type(lease[name]) ~= "function" then return nil end
	end
	local target = {}
	local record = { lease = lease, ticket = ticket, bind = lease.bind_input, write = lease.write,
		cancel = lease.cancel, failure = lease.failure, bytes = lease.bytes,
		eof = lease.eof, write_pending = lease.write_pending,
		resume_admit = lease.resume_admit, begin_continuation = rawget(lease, "begin_continuation"),
		seal = rawget(lease, "seal_sha256"), claimed = false }
	targets[target] = record
	local registered, ack = pcall(lease.on_settled, lease, function()
		if targets[target] == record then targets[target] = nil end
	end)
	if not registered or ack ~= true or targets[target] ~= record then return nil end
	return target
end

--- Side-effect-free preflight; exact lease admission occurs before child spawn.
function M.valid(target)
	local record = targets[target]
	return record ~= nil and not record.claimed
end

--- Returns an actual typed private filesystem failure, never stderr inference.
function M.failure(target)
	local record = targets[target]
	if not record then return nil end
	local ok, failure = pcall(record.failure, record.lease, record.ticket)
	if not ok or type(failure) ~= "table" then return nil end
	local copy = {}
	for key, value in pairs(failure) do if type(value) ~= "table" then copy[key] = value end end
	return copy
end

--- Validates the exact private ticket received by the native input owner.
function M.owns(target, ticket, producer)
	local record = targets[target]
	return record ~= nil and record.claimed and rawequal(record.ticket, ticket) and rawequal(record.producer, producer)
end

--- Native resume port calls this AFTER its own external source capabilities.
--- It then refences exact request/reader privately before uv.read_start.
function M.resume_admit(target, producer, final_native_admit)
	local record = targets[target]
	if not record or not record.claimed or not rawequal(record.producer, producer) or record.stopped or record.pending then return false end
	local ok, permission = pcall(record.resume_admit, record.lease, record.ticket, final_native_admit)
	return ok and permission == true and targets[target] == record and rawequal(record.producer, producer)
		and not record.stopped and record.pending == nil
end

--- Consumes only the actual retired native output receipt for a successor.
--- The canonical managed policy owns the redirect/relay decision; this owner
--- proves exact result identity, native EOF/physical ACK and parent writer debt.
--- @return table|nil new_target Private one-attempt capability, never a Boolean.
function M.next(target, producer, result, disposition, final_native_admit)
	local record = targets[target]
	if not record or not record.claimed or not rawequal(record.producer, producer)
		or record.continuing or type(record.report) ~= "function" or type(record.begin_continuation) ~= "function"
		or (disposition ~= "relay" and disposition ~= "redirect") or type(final_native_admit) ~= "function" then return nil end
	record.continuing = true -- Reserve before any native/lease probe can reenter.
	local reported, observed = pcall(record.report, record.input, record.ticket, producer, result)
	if not reported or type(observed) ~= "table" or targets[target] ~= record
		or not rawequal(record.producer, producer) or not rawequal(observed.result, result)
		or observed.reader_eof ~= true or observed.physical_settled ~= true or observed.cancelled ~= false
		or not byte_count(observed.received_bytes) then return nil end
	local counted, bytes = pcall(record.bytes, record.lease, record.ticket)
	local inspected, pending = pcall(record.write_pending, record.lease, record.ticket)
	local failure_checked, failed = pcall(record.failure, record.lease, record.ticket)
	if not counted or not byte_count(bytes)
		or bytes ~= observed.received_bytes or not inspected or pending ~= false
		or not failure_checked or failed ~= nil or targets[target] ~= record then return nil end
	if disposition == "relay" and (bytes ~= 0 or observed.received_bytes ~= 0 or result.ok ~= false) then return nil end
	if disposition == "redirect" and type(result.redirect_receipt) ~= "table" then return nil end
	local called, ticket = pcall(record.begin_continuation, record.lease, record.ticket, producer, disposition, final_native_admit)
	if not called or ticket == nil or targets[target] ~= record then return nil end
	return M.create(record.lease, ticket)
end

--- Captures the final native result without exporting a ticket or descriptor.
--- A managed owned callback receives this private capability as its second arg.
function M.complete(target, producer, result)
	local record = targets[target]
	if not record or record.completing or record.completed or not record.claimed
		or not rawequal(record.producer, producer) or type(record.report) ~= "function"
		or type(record.seal) ~= "function" or type(result) ~= "table" or result.ok ~= true then return nil end
	record.completing = true
	local called, observed = pcall(record.report, record.input, record.ticket, producer, result)
	local counted, bytes = pcall(record.bytes, record.lease, record.ticket)
	local inspected, pending = pcall(record.write_pending, record.lease, record.ticket)
	local failure_checked, failed = pcall(record.failure, record.lease, record.ticket)
	if not called or type(observed) ~= "table" or not rawequal(observed.result, result)
		or observed.reader_eof ~= true or observed.physical_settled ~= true or observed.cancelled ~= false
		or not counted or not byte_count(bytes) or bytes == 0 or not byte_count(observed.received_bytes)
		or bytes ~= observed.received_bytes or not inspected or pending ~= false
		or not failure_checked or failed ~= nil or targets[target] ~= record
		or not rawequal(record.producer, producer) then return nil end
	local token = {}
	completions[token] = { target = target, record = record, consumed = false }
	record.completed = true
	return token
end

--- Starts same-FD sealing through the captured exact lease and final ticket.
--- Native callers retain this token privately; a page never receives it.
local function seal(token, expected, deadline, callback)
	local completion = completions[token]
	if not completion or completion.consumed or targets[completion.target] ~= completion.record then return nil end
	local record = completion.record
	completion.consumed = true
	local called, operation = pcall(record.seal, record.lease, record.ticket, expected, deadline, callback)
	return called and operation or nil
end

--- Backward-compatible standalone sealing; native artifact adoption uses
--- the original privately captured seal_owned function below instead.
function M.seal(token, expected, deadline, callback)
	return seal(token, expected, deadline, callback)
end

--- Refuses another artifact's completion before consuming or acquiring reads.
--- A caller cannot export a ticket, descriptor or native artifact stage port.
function M.seal_owned(token, expected, deadline, lease, callback)
	local completion = completions[token]
	if not completion or not rawequal(completion.record.lease, lease) then return nil end
	return seal(token, expected, deadline, callback)
end

--- Binds one exact producer/input owner and bounded parent write backpressure.
--- Input additionally supplies pause/resume/live/write_ack methods, all scoped
--- to the same immutable native request. Native close methods come from its
--- actual read-handle callback; no scheduled close is treated as retirement.
function M.attach(target, producer, input)
	local record = targets[target]
	if not record or record.claimed or type(input) ~= "table" then return nil end
	for _, name in ipairs({ "pause", "resume", "live", "write_ack" }) do
		if type(input[name]) ~= "function" then return nil end
	end
	local pause, resume, live, write_ack = input.pause, input.resume, input.live, input.write_ack
	record.claimed, record.producer, record.input = true, producer, input
	record.report = rawget(input, "continuation_receipt")
	record.pending, record.stopped = nil, false
	local sink, pending, stopped, write_failure = {}, nil, false, nil
	local function current()
		if stopped or targets[target] ~= record then return false end
		local ok, active = pcall(live, input)
		return ok and active == true and not stopped and targets[target] == record
	end
	function sink:has_pending_write() return pending ~= nil end
	-- Exact final write failure survives lease/target registry retirement.
	-- Native completion owns this captured sink; it must retain the receipt
	-- before considering success, even if the producer already physically exited.
	function sink:failure() return copy_receipt(write_failure) end
	function sink:stop(cancel_output)
		stopped, record.stopped = true, true
		if cancel_output then pcall(record.cancel, record.lease) end
	end
	function sink:eof()
		stopped, record.stopped = true, true -- No future source bytes after this actual input EOF.
		-- Actual core read EOF, separate from reader close ACK.
		local ok, accepted = pcall(record.eof, record.lease, record.ticket)
		return ok and accepted == true
	end
	function sink:consume(chunk)
		if pending or type(chunk) ~= "string" or #chunk == 0 or #chunk > 65536 or not current() then return false end
		local work = {}
		pending, record.pending = work, work -- Reserve before reentrant native stop/read capability.
		local called, accepted = pcall(pause, input)
		if not called or accepted ~= true or pending ~= work or not current() then
			if pending == work then pending, record.pending = nil, nil end
			self:stop(true)
			return false
		end
		local dispatched, admitted = pcall(record.write, record.lease, record.ticket, chunk, function(permit, failure)
			if pending ~= work then return end
			write_failure = copy_receipt(failure) or write_failure
			pending, record.pending = nil, nil -- Actual filesystem ACK; permission is separate.
			if permit == true and not failure and current() then
				-- The external native live getter can consume the original
				-- budget. Re-admit the exact lease after that boundary.
				local checked, permission = pcall(record.resume_admit, record.lease, record.ticket)
				if checked and permission == true and not stopped and targets[target] == record then
					local resumed, ack = pcall(resume, input)
					if not resumed or ack ~= true then sink:stop(true) end
				else sink:stop(true) end
			elseif failure then
				sink:stop(true)
			end
			-- Reconsider native completion after the exact write ledger retires.
			pcall(write_ack, input, copy_receipt(write_failure))
		end)
		if not dispatched then
			-- Native write submission could already exist: retain unknown debt.
			self:stop(true)
			return false
		end
		if admitted ~= true then
			-- Refusal before dispatch differs from ambiguous retained write
			-- debt. Only the exact private lease ledger may prove no pending IO.
			local observed, writing = pcall(record.write_pending, record.lease, record.ticket)
			if observed and writing == false and pending == work then
				pending, record.pending = nil, nil
				-- No IO was retained. Reconsider exact native cleanup without
				-- manufacturing a physical write acknowledgement.
				pcall(write_ack, input)
			end
			self:stop(true)
			return false
		end
		return true
	end
	local called, accepted = pcall(record.bind, record.lease, record.ticket, producer, input)
	if not called or accepted ~= true then sink:stop(true); return nil end
	return sink
end

return M
