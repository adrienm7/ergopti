--- modules/llm/opaque_network_admission.lua

--- ==============================================================================
--- MODULE: Owned Opaque Network Admission Phase
--- DESCRIPTION:
--- Receives only the trusted wrapper's pre-child stderr phase. ACCEPTED closes
--- admission permanently: subsequent child stderr cannot diagnose proxy failure.
--- Exact current, committed task ownership is checked by each receiving caller.
--- ==============================================================================

local M = {}

local PREFIX = "__ERGOPTI_OPAQUE_ADMISSION_V1__:"
M.accepted_line = PREFIX .. "accepted"
M.refusal_prefix = PREFIX .. "refused:"
M.refusal_exit_code = 78 -- EX_CONFIG, shared with the shell admission protocol.
local MAX_FRAME_BYTES = 256
local _contract

--- Creates one bounded receiver for one exact physical wrapper task.
--- @return table phase
function M.new()
	local state, buffer, receipt = "pending", "", nil
	local finalized = false
	local phase = {}
	function phase.push(stderr)
		if finalized or state == "accepted" or state == "invalid" then return false end
		assert(type(stderr) == "string", "admission receives only stderr bytes")
		buffer = buffer .. stderr
		while true do
			local newline = buffer:find("\n", 1, true)
			if not newline then
				if #buffer > MAX_FRAME_BYTES then state, buffer, receipt = "invalid", "", nil end
				return state ~= "invalid"
			end
			if newline - 1 > MAX_FRAME_BYTES then state, buffer, receipt = "invalid", "", nil; return false end
			local line = buffer:sub(1, newline - 1)
			buffer = buffer:sub(newline + 1)
			if line == M.accepted_line then
				if state ~= "pending" then state, receipt = "invalid", nil; return false end
				state, buffer, receipt = "accepted", "", nil
				return true
			elseif line:sub(1, #M.refusal_prefix) == M.refusal_prefix then
				if state ~= "pending" then state, receipt = "invalid", nil; return false end
				local facts = line:sub(#M.refusal_prefix + 1)
				if facts ~= "verified:unavailable" and facts ~= "unavailable:unavailable" then
					state, receipt = "invalid", nil; return false
				end
				receipt = { stage = "proxy_resolve", proxy_resolution_status = "unavailable",
					failure_provenance = facts == "verified:unavailable" and "verified" or "unavailable" }
				state = "refused"
			elseif line:sub(1, #PREFIX) == PREFIX then
				state, receipt = "invalid", nil; return false
			end
		end
	end
	function phase.finish(code)
		if finalized then return nil end
		finalized = true
		if code ~= M.refusal_exit_code or state ~= "refused" or buffer ~= "" then return nil end
		return receipt
	end
	return phase
end

--- Classifies a real admission receipt with the central existing policy.
--- @param receipt table Existing managed-network fields.
--- @param capabilities table Actual current caller capabilities.
--- @return table report
function M.report(receipt, capabilities)
	if not _contract then
		local path = require("infra.paths").shared("modules/network/managed_network.json")
		assert(type(path) == "string", "the shared managed network policy path is unavailable")
		local bytes = assert(require("adapters.file_system").read(path), "the shared managed network policy is unreadable")
		_contract = require("network.failure").new(require("json").decode(bytes))
	end
	return _contract.classify(receipt, capabilities)
end

return M
