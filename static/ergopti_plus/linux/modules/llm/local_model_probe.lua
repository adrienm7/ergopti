--- modules/llm/local_model_probe.lua

--- ==============================================================================
--- MODULE: Local Model Presence Probe
--- DESCRIPTION:
--- Lists Ollama models asynchronously through the inference request's HTTP
--- owner. Cancelling or superseding that owner also withdraws its preflight.
--- ==============================================================================

local M = {}

-- The cooperative constructor captures one engine owner, not a later compatible export.
local ResponseEngine = require("modules.llm.prediction_engine")
local ResponseCapture, ResponseCurrent = ResponseEngine.capture_runtime_response, ResponseEngine.runtime_response_current
assert(type(ResponseCapture) == "function" and type(ResponseCurrent) == "function",
	"original runtime response owner unavailable")
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
--- @param runtime_receipt table|nil Original opaque producer receipt, or a fresh direct probe capture.
--- @return boolean dispatched
function M.verify(base_url, model, owner, on_done, runtime_receipt)
	local engine = ResponseEngine
	local capture, current = ResponseCapture, ResponseCurrent
	if type(capture) ~= "function" or type(current) ~= "function" then return false end
	local receipt = runtime_receipt
	if receipt == nil then receipt = capture() end
	local function admitted()
		if package.loaded["modules.llm.prediction_engine"] ~= engine
			or engine.capture_runtime_response ~= capture or engine.runtime_response_current ~= current then return false end
		local accepted = current(receipt, base_url) == true
		return accepted and package.loaded["modules.llm.prediction_engine"] == engine
			and engine.capture_runtime_response == capture and engine.runtime_response_current == current
	end
	if not admitted() then return false end
	local name = Policy.normalize(model)
	local url = Bridge.ollama_endpoint(base_url, "tags")
	if not admitted() then return false end
	if not name or not url then
		on_done(nil, "invalid local model or origin")
		return false
	end
	return HttpClient.get(url, {}, {
		owner = owner, timeout_ms = Timings.ms("llm", "local_server_probe_timeout_ms"),
		authorized = admitted,
	}, function(result)
		if not admitted() then return end
		local names, reason = Policy.list_receipt(result)
		if not admitted() then return end
		if not names then on_done(nil, reason) return end
		on_done(names[name] == true)
	end) == true
end

return M
