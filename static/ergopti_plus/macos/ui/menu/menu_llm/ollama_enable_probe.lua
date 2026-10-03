--- ui/menu/menu_llm/ollama_enable_probe.lua

--- ==============================================================================
--- MODULE: Ollama Enable Probe Owner
--- DESCRIPTION:
--- Owns read-only version requests until their exact native cleanup settles.
--- ==============================================================================

local HttpClient = require("adapters.http_client")
local Admission = require("llm.enable_admission")
local M = {}





-- ====================================
-- ====================================
-- ======= 1/ Request Ownership =======
-- ====================================
-- ====================================

--- Creates a private HTTP owner without starting an Ollama service.
--- @return table owner Request, cancellation and scope-admission capabilities.
function M.new()
	local client = HttpClient.new({ follow_redirects = false, cache_policy = "ignoreLocalCache" })
	local generation = 0
	local busy = false
	local pending = false
	local owner = {}

	--- Revokes callbacks before joining the exact task and timeout capabilities.
	--- @return boolean settled
	function owner.cancel()
		generation = generation + 1
		pending = false
		local ok, settled = xpcall(client.cancel, debug.traceback)
		if ok == true and settled == true then busy = false return true end
		busy = true
		client.onSettled(function() busy = false end)
		return false
	end

	--- @return boolean idle
	function owner.scope_idle() return busy == false end

	--- @return boolean active
	function owner.is_pending() return pending == true end

	--- Requests the complete version receipt and waits for native settlement.
	--- @param origin string Exact configured Ollama origin.
	--- @param callback function Receives the unmodified HTTP receipt.
	--- @return boolean accepted
	function owner.request(origin, callback)
		if busy or type(origin) ~= "string" or origin == ""
			or type(callback) ~= "function" then return false end
		generation = generation + 1
		local mine = generation
		busy, pending = true, true
		local acquiring = true
		local accepted = false
		local receipt, terminal = nil, false
		local function deliver()
			if mine ~= generation or not pending or acquiring or not accepted
				or not terminal then return end
			pending = false
			client.onSettled(function()
				if mine ~= generation then return end
				busy = false
				callback(receipt)
			end)
		end
		local ok, result = xpcall(function()
			return client.get(origin .. Admission.VERSION_PATH, {}, function(value)
				if mine ~= generation or terminal then return end
				terminal, receipt = true, value
				deliver()
			end)
		end, debug.traceback)
		acquiring = false
		accepted = ok == true and result == true
		if not accepted then owner.cancel() return false end
		deliver()
		return true
	end

	return owner
end

return M
