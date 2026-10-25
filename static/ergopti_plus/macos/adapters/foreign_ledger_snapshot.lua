--- adapters/foreign_ledger_snapshot.lua

--- ==============================================================================
--- MODULE: Foreign Ledger Snapshot Reader
--- DESCRIPTION:
--- Verifies durable prefix receipts and frames one committed foreign SQL image
--- through the same owned file handle. Native hashing and scanning advance in
--- bounded cooperative slices; source metadata never authorizes byte continuity.
--- ==============================================================================

local M = {}
local hs = hs
local PacedJob = require("infra.paced_job")

--- Maximum source bytes scanned or hashed by one verification step.
M.BYTES_PER_TURN = 64 * 1024

--- Create one scanner with bounded lexical carry between native reads.
--- @return table scanner
local function new_scanner()
	return { pending = "", processed = 0, committed = 0, quoted = false, comment = false }
end

--- Scan only new bytes, retaining enough lookahead for a complete COMMIT token.
--- @param scanner table Scanner state.
--- @param bytes string Newly read bytes.
--- @param final boolean Whether this is the captured end of the source.
local function scan(scanner, bytes, final)
	local text = scanner.pending .. bytes
	local limit = final and #text or math.max(0, #text - 8)
	local at = 1
	while at <= limit do
		local char = text:sub(at, at)
		if scanner.comment then
			if char == "\n" then scanner.comment = false end
		elseif scanner.quoted then
			if char == "'" then
				if text:sub(at + 1, at + 1) == "'" then at = at + 1
				else scanner.quoted = false end
			end
		elseif char == "-" and text:sub(at + 1, at + 1) == "-" then
			scanner.comment = true
			at = at + 1
		elseif char == "'" then scanner.quoted = true
		elseif char == "\n" and text:sub(at + 1, at + 8) == "COMMIT;\n" then
			scanner.committed = scanner.processed + at + 8
			at = at + 8
		end
		at = at + 1
	end
	scanner.processed = scanner.processed + at - 1
	scanner.pending = text:sub(at)
end

--- Finish one native context and reject malformed digest receipts.
--- @param context userdata|table Native SHA-256 context.
--- @return string digest Lowercase SHA-256 hex.
local function finish_digest(context)
	assert(context:finish(), "hash finish refused")
	local digest = context:value()
	assert(type(digest) == "string" and #digest == 64 and digest:match("^[0-9a-fA-F]+$"),
		"invalid hash receipt")
	return digest:lower()
end

--- Allocate a fresh incremental native SHA-256 context.
--- @return userdata|table context
local function new_digest()
	return assert(hs.hash.new("SHA256"), "hash allocation refused")
end

--- Settle an owned native stream without mistaking an error for readable bytes.
--- Lua marks a FILE closed before native fclose runs. That closed-file receipt
--- settles resource ownership even when the read transaction must be refused.
--- @param reader table Snapshot reader.
--- @return boolean settled Whether no live stream remains owned.
--- @return boolean accepted Whether native close committed without an error.
local function close_stream(reader)
	local handle = reader.handle
	if not handle then return true, true end
	local ok, result = pcall(handle.close, handle)
	local type_ok, native_type = pcall(io.type, handle)
	local accepted = ok and result == true
	if accepted or (type_ok and native_type == "closed file") then
		reader.handle = nil
		return true, accepted
	end
	return false, false
end

--- Revoke a verification job before closing its exact native stream.
--- Cancellation retains terminal timer debt independently of the file receipt.
--- @param reader table Snapshot reader.
--- @return boolean settled Whether every owned native capability settled.
function M.close(reader)
	reader.active = false
	reader.status, reader.receipt = "cancelled", nil
	reader.chunks, reader.digest, reader.prefix = {}, nil, nil
	local settled = true
	if reader.job then
		local ok, cancelled = pcall(reader.job.cancel)
		if ok and cancelled == true then reader.job = nil
		else settled = false end
	end
	if not close_stream(reader) then settled = false end
	return settled
end

--- Open one source generation. Allocation failures retain no unowned stream.
--- @param path string Foreign ledger path.
--- @param size integer Captured source EOF.
--- @param offset integer Previously committed offset.
--- @param digest string|nil Durable digest of that exact prefix.
--- @return table|nil reader
--- @return string|nil failure Fixed failure category.
function M.open(path, size, offset, digest)
	local reader = { size = size, expected_offset = offset, expected_digest = digest,
		at = 0, step = "scan", scanner = new_scanner(), chunks = {}, status = "new", active = false }
	local stage = "state"
	local ok = pcall(function()
		assert(type(size) == "number" and size >= 0 and size < math.huge and size % 1 == 0,
			"invalid source size")
		assert(type(offset) == "number" and offset >= 0 and offset < math.huge and offset % 1 == 0,
			"invalid source offset")
		assert(digest == nil or (type(digest) == "string" and #digest == 64
			and digest:match("^[0-9a-f]+$") ~= nil), "invalid prefix digest")
		stage = "open"
		reader.handle = assert(io.open(path, "rb"), "open refused")
		stage = "seek"
		assert(reader.handle:seek("set", 0) == 0, "seek refused")
		reader.trusted = offset > 0 and offset <= size and digest ~= nil
		stage = "hash"
		if reader.trusted then reader.prefix = new_digest() end
	end)
	if not ok then
		close_stream(reader)
		return reader.handle and reader or nil, stage
	end
	return reader
end

--- Feed only the previously committed prefix into its independent verifier.
--- @param reader table Snapshot reader.
--- @param bytes string Bytes beginning at reader.at.
local function verify_prefix(reader, bytes)
	if not reader.prefix then return end
	local count = math.min(#bytes, reader.expected_offset - reader.at)
	if count > 0 then assert(reader.prefix:append(bytes:sub(1, count)), "hash append refused") end
	if reader.at + #bytes >= reader.expected_offset then
		reader.matches = finish_digest(reader.prefix) == reader.expected_digest
		reader.prefix = nil
	end
end

--- Advance verification without exceeding one step's native byte budget.
--- @param reader table Exact active source reader.
--- @return string status pending, ready or failed.
--- @return table|string|nil receipt Verified committed SQL or fixed failure category.
function M.advance(reader)
	local stage = "read"
	local ok, status, receipt = pcall(function()
		local budget = M.BYTES_PER_TURN
		while budget > 0 do
			local target = reader.step == "scan" and reader.size or reader.committed
			local count = math.min(budget, target - reader.at)
			if count > 0 then
				stage = "read"
				local bytes = reader.handle:read(count)
				assert(type(bytes) == "string" and #bytes == count, "short source read")
				stage = "hash"
				verify_prefix(reader, bytes)
				if reader.step == "hash" then
					assert(reader.digest:append(bytes), "hash append refused")
					if reader.at + count > reader.offset then
						reader.chunks[#reader.chunks + 1] = bytes:sub(math.max(1, reader.offset - reader.at + 1))
					end
				end
				stage = "framing"
				scan(reader.scanner, bytes, reader.at + count == target)
				reader.at = reader.at + count
				budget = budget - count
			end
			if reader.at == target then
				if reader.step == "scan" then
					reader.committed = reader.scanner.committed
					reader.offset = reader.matches and reader.expected_offset or 0
					if reader.committed == 0 or reader.committed == reader.offset then
						stage = "close"
						local _, accepted = close_stream(reader)
						assert(accepted, "source close refused")
						return "ready", { chunk = "", uncommitted = reader.committed == 0 }
					end
					stage = "seek"
					assert(reader.handle:seek("set", 0) == 0, "seek refused")
					stage = "hash"
					reader.digest = new_digest()
					if reader.matches then reader.prefix = new_digest() end
					reader.at, reader.step, reader.scanner = 0, "hash", new_scanner()
				else
					stage = "framing"
					assert(reader.scanner.committed == reader.committed, "source framing changed")
					stage = "hash"
					assert(reader.offset == 0 or reader.matches == true, "source prefix changed")
					local digest = finish_digest(reader.digest)
					stage = "close"
					local _, accepted = close_stream(reader)
					assert(accepted, "source close refused")
					local chunk = table.concat(reader.chunks)
					reader.chunks, reader.digest, reader.prefix = {}, nil, nil
					return "ready", { chunk = chunk, offset = reader.offset,
						digest = digest, applied_to = reader.committed }
				end
			end
		end
		return "pending"
	end)
	if ok then return status, receipt end
	if stage ~= "close" then close_stream(reader) end
	return "failed", stage
end

--- Pump verification on bounded runloop slices instead of waiting for ingest.
--- The completed SQL receipt remains inert until the next normal ingest tick.
--- @param reader table Newly opened reader already published by its owner.
--- @return boolean started Whether the cooperative job was armed.
function M.start(reader)
	if reader.status ~= "new" or reader.job or not reader.handle then return false end
	reader.active, reader.status = true, "pending"
	local job
	local ok, created = pcall(PacedJob.start, {
		label = "Foreign ledger prefix verification",
		body = function(pacer)
			while reader.active do
				local status, receipt = M.advance(reader)
				if status ~= "pending" then return { status = status, receipt = receipt } end
				pacer.pause()
			end
			return { status = "cancelled" }
		end,
		on_done = function(completed, result)
			if not reader.active or reader.job ~= job then return end
			if completed then reader.status, reader.receipt = result.status, result.receipt
			else reader.status, reader.receipt = "failed", "verification" end
		end,
	})
	job = ok and created or nil
	reader.job = job
	if not job then
		reader.active, reader.status, reader.receipt = false, "failed", "schedule"
		close_stream(reader)
		return false
	end
	return true
end

--- Admit a completed receipt only after its exact cooperative job is settled.
--- @param reader table Owned reader.
--- @return string status pending, ready, failed or cancelled.
--- @return table|string|nil receipt Verified SQL or fixed refusal category.
function M.poll(reader)
	if reader.status == "pending" then return "pending" end
	if reader.job then
		local ok, settled = pcall(reader.job.cancel)
		if not ok or settled ~= true then return "pending" end
		reader.job = nil
	end
	reader.active = false
	return reader.status, reader.receipt
end

return M
