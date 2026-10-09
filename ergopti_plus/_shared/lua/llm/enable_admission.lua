--- _shared/lua/llm/enable_admission.lua

--- ==============================================================================
--- MODULE: Local AI Enable Admission
--- DESCRIPTION:
--- Admits an Ollama enable only from a complete native version receipt and a
--- current disabled preference. Drivers retain HTTP, pause and writer ownership.
--- ==============================================================================

local M = {}
local Json = require("json")
M.VERSION_PATH = "/api/version"





-- ===================================
-- ===================================
-- ======= 1/ Admission Policy =======
-- ===================================
-- ===================================

--- Whether enabling this backend requires a local Ollama receipt.
--- @param backend any
--- @return boolean
function M.requires_probe(backend)
	return backend == "ollama"
end

--- Reads a real GET /api/version receipt without interpreting a generic ping.
--- @param result any Native HTTP result with ok, status and a complete body.
--- @return boolean admitted
--- @return string|nil reason
function M.receipt(result)
	if type(result) ~= "table" or result.ok ~= true or result.status ~= 200 then
		return false, "ollama_unreachable"
	end
	if type(result.body) ~= "string" or result.body_truncated == true then
		return false, "unreadable_ollama_receipt"
	end
	local root = Json.decode_lossless(result.body)
	if type(root) ~= "table" or Json.is_array(root)
		or type(root.version) ~= "string" or root.version == "" then
		return false, "unreadable_ollama_receipt"
	end
	return true
end

--- Requires the native owner to supply every captured identity and live gate.
--- @param captured any Originating request snapshot.
--- @param live any Current backend, model, origin, generation and admission.
--- @return boolean
function M.current(captured, live)
	if type(captured) ~= "table" or type(live) ~= "table"
		or live.enabled ~= false or live.paused ~= false or live.blocked ~= false then
		return false
	end
	for _, key in ipairs({ "backend", "model", "origin" }) do
		if type(captured[key]) ~= "string" or type(live[key]) ~= "string"
			or captured[key] ~= live[key] then return false end
	end
	return captured.backend == "ollama" and captured.origin ~= ""
		and type(captured.generation) == "number" and captured.generation >= 0
		and captured.generation % 1 == 0 and live.generation == captured.generation
end

return M
