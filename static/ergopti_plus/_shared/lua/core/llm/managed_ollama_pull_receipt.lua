--- _shared/lua/core/llm/managed_ollama_pull_receipt.lua

--- ==============================================================================
--- MODULE: Managed Ollama Pull Retirement Receipt
--- DESCRIPTION:
--- Request-process exit never releases daemon work. Receive only exact callback,
--- private-operation and authenticated native retirement evidence.
--- ==============================================================================

local M = {}
local FIELDS = {
	"version", "nonce", "state", "worker_status", "source_admitted", "listener_bound",
	"request_reaped", "daemon_operation_retired", "operation", "source_commit", "binary_sha256", "asset_sha256",
}
M.maximum_bytes = 4096

local function status(value)
	return type(value) == "number" and value >= 0 and value <= 255 and value % 1 == 0
end

local function hexadecimal(value, length)
	return type(value) == "string" and #value == length and value:match("^[0-9a-f]+$") ~= nil
end

--- Receives a physically closed operation, including a pre-submission refusal.
--- @param raw string Exact private receipt bytes.
--- @param decode function Canonical JSON decoder.
--- @param nonce string Exact caller operation identity.
--- @param callback_status number Actual hs.task completion code.
--- @return boolean retired Both native request and daemon work are retired.
function M.retired(raw, decode, nonce, callback_status)
	if type(raw) ~= "string" or #raw > M.maximum_bytes or raw:find("\\", 1, true)
		or type(decode) ~= "function" or type(nonce) ~= "string" or #nonce ~= 36
		or not nonce:match("^[%w%-]+$") or not status(callback_status) then return false end
	local allowed = {}
	for _, field in ipairs(FIELDS) do
		allowed[field] = true
		local _, count = raw:gsub('"' .. field .. '"%s*:', "")
		if count ~= 1 then return false end
	end
	local ok, proof = pcall(decode, raw)
	if not ok or type(proof) ~= "table" then return false end
	local count = 0
	for field in pairs(proof) do
		if not allowed[field] then return false end
		count = count + 1
	end
	if count ~= #FIELDS or proof.version ~= 1 or proof.nonce ~= nonce or proof.state ~= "retired"
		or not status(proof.worker_status) or proof.worker_status ~= callback_status
		or type(proof.source_admitted) ~= "boolean" or type(proof.listener_bound) ~= "boolean"
		or proof.request_reaped ~= true or proof.daemon_operation_retired ~= true then return false end
	if proof.source_admitted then
		if not proof.listener_bound or not hexadecimal(proof.source_commit, 40)
			or not hexadecimal(proof.binary_sha256, 64) or not hexadecimal(proof.asset_sha256, 64)
			or (proof.operation ~= "" and not hexadecimal(proof.operation, 32)) then return false end
	else
		if proof.listener_bound or proof.operation ~= "" or proof.source_commit ~= ""
			or proof.binary_sha256 ~= "" or proof.asset_sha256 ~= "" then return false end
	end
	if callback_status == 0 and (not proof.source_admitted or not hexadecimal(proof.operation, 32)) then return false end
	return true
end

return M
