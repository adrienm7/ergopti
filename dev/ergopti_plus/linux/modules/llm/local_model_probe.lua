--- modules/llm/local_model_probe.lua

--- ==============================================================================
--- MODULE: Local Model Presence Probe
--- DESCRIPTION:
--- Lists Ollama models asynchronously through the inference request's HTTP
--- owner. Cancelling or superseding that owner also withdraws its preflight.
--- ==============================================================================

local M = {}
local Policy = require("llm.local_model_policy")
local HttpClient = require("adapters.http_client")
local Timings = require("infra.timings")
local Bridge = require("infra.llm_bridge")





-- ==============================
-- ==============================
-- ======= 1/ Owned Probe =======
-- ==============================
-- ==============================

--- Verifies a model without equating a failed listing with an empty one.
--- @param base_url string
--- @param model string
--- @param owner string|nil The existing inference HTTP owner.
--- @param on_done function Receives true or false, or nil and a failure reason.
--- @return boolean dispatched
function M.verify(base_url, model, owner, on_done)
	local name = Policy.normalize(model)
	local url = Bridge.ollama_endpoint(base_url, "tags")
	if not name or not url then
		on_done(nil, "invalid local model or origin")
		return false
	end
	return HttpClient.get(url, {}, {
		owner = owner, timeout_ms = Timings.ms("llm", "local_server_probe_timeout_ms"),
	}, function(result)
		local names, reason = Policy.list_receipt(result)
		if not names then on_done(nil, reason) return end
		on_done(names[name] == true)
	end) == true
end

return M
