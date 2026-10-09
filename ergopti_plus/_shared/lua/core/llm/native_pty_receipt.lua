--- _shared/lua/core/llm/native_pty_receipt.lua

--- ==============================================================================
--- MODULE: Native Bootstrap PTY Retirement Receipt
--- DESCRIPTION:
--- Receives the closed physical-retirement evidence of a native bootstrap
--- operation before a caller may release its exact process ownership.
--- ==============================================================================

local M = {}

local FIELDS = {
	"version", "nonce", "state", "group_retired", "guardian_reaped", "pty_eof",
	"handles_closed", "status_valid", "exit_status", "worker_status", "source_admitted",
}
local CLOSURES = { "group_retired", "guardian_reaped", "pty_eof", "handles_closed", "status_valid" }
M.maximum_bytes = 4096

local function status(value)
	return type(value) == "number" and value >= 0 and value <= 255 and value % 1 == 0
end

--- Receives only a closed scalar receipt, never a private native diagnostic.
--- @param raw string Exact native receipt bytes.
--- @param decode function Canonical JSON decoder.
--- @param nonce string Exact caller operation identity.
--- @param callback_status number Exact native task completion code.
--- @return boolean retired All native capabilities physically retired.
function M.retired(raw, decode, nonce, callback_status)
	if type(raw) ~= "string" or #raw > M.maximum_bytes or type(decode) ~= "function"
		or type(nonce) ~= "string" or nonce == "" or not nonce:match("^[%w%-]+$")
		or not status(callback_status) or raw:find("\\", 1, true) then return false end
	-- This scalar protocol has no escaped strings: fixed keys/state plus UUID.
	-- Count literal keys independently because ordinary JSON decoders lose
	-- duplicate object keys before their consumer can reject the ambiguity.
	for _, field in ipairs(FIELDS) do
		local _, count = raw:gsub('"' .. field .. '"%s*:', "")
		if count ~= 1 then return false end
	end
	local ok, receipt = pcall(decode, raw)
	if not ok or type(receipt) ~= "table" then return false end
	local count = 0
	local allowed = {}
	for _, field in ipairs(FIELDS) do allowed[field] = true end
	for field in pairs(receipt) do
		if allowed[field] ~= true then return false end
		count = count + 1
	end
	if count ~= #FIELDS or type(receipt.version) ~= "number" or receipt.version ~= 1
		or receipt.nonce ~= nonce or receipt.state ~= "retired"
		or not status(receipt.exit_status) or not status(receipt.worker_status)
		or receipt.worker_status ~= callback_status or type(receipt.source_admitted) ~= "boolean" then return false end
	for _, field in ipairs(CLOSURES) do
		if receipt[field] ~= true then return false end
	end
	if callback_status == 0 and (receipt.exit_status ~= 0 or receipt.source_admitted ~= true) then return false end
	return true
end

return M
