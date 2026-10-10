--- _shared/lua/core/llm/managed_ollama_cleanup_receipt.lua

--- ==============================================================================
--- MODULE: Managed Ollama Explicit Cleanup Receipt
--- DESCRIPTION:
--- Receives a fresh cleanup worker independently of the immutable original pull
--- result. A pending pull never becomes a successful model installation here.
--- ==============================================================================

local M = {}
M.maximum_bytes = 4096
local FIELDS = {
	"version", "nonce", "original_nonce", "original_worker_status", "operation",
	"authority_sha256", "window_sha256", "state", "worker_status",
	"request_reaped", "daemon_operation_retired", "source_admitted", "listener_bound",
}

local function hex(value, length)
	return type(value) == "string" and #value == length and value:match("^[0-9a-f]+$") ~= nil
end

local function nonce(value)
	return type(value) == "string" and #value == 36 and value:match("^[A-Za-z0-9%-]+$") ~= nil
end

--- Reads one exact fresh result without granting retirement to a pending worker.
--- @param raw string Private cleanup receipt bytes.
--- @param decode function Canonical JSON decoder.
--- @param expected table Exact original authority and fresh worker bindings.
--- @param callback_status number Actual cleanup completion status.
--- @return string|nil state Valid retired or pending cleanup observation.
function M.receive(raw, decode, expected, callback_status)
	if type(raw) ~= "string" or #raw > M.maximum_bytes or raw:find("\\", 1, true)
		or type(decode) ~= "function" or type(expected) ~= "table"
		or not nonce(expected.nonce) or not nonce(expected.original_nonce)
		or expected.nonce == expected.original_nonce or not hex(expected.operation, 32)
		or not hex(expected.authority_sha256, 64) or not hex(expected.window_sha256, 64)
		or (callback_status ~= 0 and callback_status ~= 78 and callback_status ~= 130) then return nil end
	local allowed = {}
	for _, field in ipairs(FIELDS) do
		allowed[field] = true
		local _, count = raw:gsub('"' .. field .. '"%s*:', "")
		if count ~= 1 then return nil end
	end
	local ok, proof = pcall(decode, raw)
	if not ok or type(proof) ~= "table" then return nil end
	local count = 0
	for field in pairs(proof) do
		if not allowed[field] then return nil end
		count = count + 1
	end
	if count ~= #FIELDS or proof.version ~= 1 or proof.original_worker_status ~= 78
		or proof.worker_status ~= callback_status or proof.request_reaped ~= true
		or proof.source_admitted ~= true or proof.listener_bound ~= true then return nil end
	for _, field in ipairs({ "nonce", "original_nonce", "operation", "authority_sha256", "window_sha256" }) do
		if proof[field] ~= expected[field] then return nil end
	end
	if proof.state == "retired" and proof.daemon_operation_retired == true and callback_status ~= 78 then
		return "retired"
	end
	if proof.state == "pending" and proof.daemon_operation_retired == false and callback_status == 78 then
		return "pending"
	end
	return nil
end


--- Receives the immutable original pending result without changing its verdict.
--- @param raw string Private original worker receipt bytes.
--- @param decode function Canonical JSON decoder.
--- @param original_nonce string Exact original caller identity.
--- @return table|nil proof Source-bound pending operation, never a retirement ACK.
function M.original_pending(raw, decode, original_nonce)
	local fields = { "version", "nonce", "state", "worker_status", "source_admitted", "listener_bound",
		"request_reaped", "daemon_operation_retired", "operation", "source_commit", "binary_sha256", "asset_sha256" }
	if type(raw) ~= "string" or #raw > M.maximum_bytes or raw:find("\\", 1, true)
		or type(decode) ~= "function" or not nonce(original_nonce) then return nil end
	local allowed = {}
	for _, field in ipairs(fields) do
		allowed[field] = true
		local _, count = raw:gsub('"' .. field .. '"%s*:', "")
		if count ~= 1 then return nil end
	end
	local ok, proof = pcall(decode, raw)
	if not ok or type(proof) ~= "table" then return nil end
	local count = 0
	for field in pairs(proof) do
		if not allowed[field] then return nil end
		count = count + 1
	end
	if count ~= #fields or proof.version ~= 1 or proof.nonce ~= original_nonce or proof.state ~= "pending"
		or proof.worker_status ~= 78 or proof.source_admitted ~= true or proof.listener_bound ~= true
		or proof.request_reaped ~= true or proof.daemon_operation_retired ~= false
		or not hex(proof.operation, 32) or not hex(proof.source_commit, 40)
		or not hex(proof.binary_sha256, 64) or not hex(proof.asset_sha256, 64) then return nil end
	return proof
end


local function exact_fields(value, fields)
	if type(value) ~= "table" then return false end
	local allowed = {}
	for _, field in ipairs(fields) do allowed[field] = true end
	local count = 0
	for field in pairs(value) do
		if not allowed[field] then return false end
		count = count + 1
	end
	return count == #fields
end

local function decimal(value)
	return type(value) == "string" and (#value <= 20)
		and (value == "0" or value:match("^[1-9][0-9]*$") ~= nil)
end

--- Receives only the token-free handoff sealed into the original reserved inode.
--- @param raw string Exact anchor bytes.
--- @param decode function Canonical JSON decoder.
--- @param original_nonce string Original caller nonce.
--- @param operation string Original pending operation.
--- @param anchor_path string Original reserved pathname.
--- @return table|nil anchor Exact private authority/window references and hashes.
function M.anchor(raw, decode, original_nonce, operation, anchor_path)
	if type(raw) ~= "string" or #raw > M.maximum_bytes or raw:find("\\", 1, true)
		or type(decode) ~= "function" or not nonce(original_nonce) or not hex(operation, 32)
		or type(anchor_path) ~= "string" or anchor_path:sub(1, 1) ~= "/" then return nil end
	for _, field in ipairs({ "version", "nonce", "operation", "directory", "authority", "window" }) do
		local _, count = raw:gsub('"' .. field .. '"%s*:', "")
		if count ~= 1 then return nil end
	end
	for field, expected in pairs({ path = 3, device = 3, inode = 3, sha256 = 2 }) do
		local _, count = raw:gsub('"' .. field .. '"%s*:', "")
		if count ~= expected then return nil end
	end
	local ok, value = pcall(decode, raw)
	if not ok or not exact_fields(value, { "version", "nonce", "operation", "directory", "authority", "window" })
		or value.version ~= 1 or value.nonce ~= original_nonce or value.operation ~= operation
		or not exact_fields(value.directory, { "path", "device", "inode" }) then return nil end
	local directory = value.directory
	if directory.path ~= anchor_path .. ".operation" or not decimal(directory.device)
		or not decimal(directory.inode) or directory.inode == "0" then return nil end
	for _, name in ipairs({ "authority", "window" }) do
		local file = value[name]
		if not exact_fields(file, { "path", "device", "inode", "sha256" })
			or file.path ~= directory.path .. "/" .. name .. ".json" or not decimal(file.device)
			or not decimal(file.inode) or file.inode == "0" or not hex(file.sha256, 64) then return nil end
	end
	return value
end

return M
