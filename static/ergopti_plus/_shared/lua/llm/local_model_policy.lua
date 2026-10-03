--- _shared/lua/llm/local_model_policy.lua

--- ==============================================================================
--- MODULE: Local Model Presence Policy
--- DESCRIPTION:
--- Pure Ollama model-name matching and missing-model classification. Native
--- drivers own HTTP requests, cancellation, consent and model downloads.
--- ==============================================================================

local M = {}
M.MODEL_MISSING = "model_missing"





-- ==================================
-- ==================================
-- ======= 1/ Presence Policy =======
-- ==================================
-- ==================================

--- Normalizes the name as Ollama matches it, including its implicit latest tag.
--- @param name any
--- @return string|nil
function M.normalize(name)
	if type(name) ~= "string" or name == "" then return nil end
	local lowered = name:lower()
	if not lowered:match("[^/]*$"):find(":", 1, true) then lowered = lowered .. ":latest" end
	return lowered
end

--- Collects both fields Ollama uses for installed model names.
--- @param models table Decoded models array, already admitted by the adapter.
--- @return table Set of normalized names.
function M.names(models)
	local names = {}
	for _, entry in ipairs(models) do
		if type(entry) == "table" then
			for _, field in ipairs({ "name", "model" }) do
				local name = M.normalize(entry[field])
				if name then names[name] = true end
			end
		end
	end
	return names
end

--- Reads only Ollama's explicit model-not-found response, never a generic 404.
--- @param status any
--- @param error_text string
--- @return string|nil
function M.missing_model(status, error_text)
	if status ~= 404 or type(error_text) ~= "string" then return nil end
	return error_text:match("^model ['\"]([^'\"]+)['\"] not found")
end

--- Classifies a completed model-list receipt, preserving unknown versus empty.
--- @param result any Native HTTP result with ok, status and body.
--- @return table|nil names
--- @return string|nil reason
function M.list_receipt(result)
	if type(result) ~= "table" or result.ok ~= true or result.status ~= 200 then
		return nil, "model_list_unavailable"
	end
	local Json = require("json")
	local root = type(result.body) == "string" and Json.decode_lossless(result.body) or nil
	if type(root) ~= "table" or not Json.is_array(root.models) then
		return nil, "unreadable_model_list"
	end
	for _, entry in ipairs(root.models) do
		if type(entry) ~= "table" or (M.normalize(entry.name) == nil and M.normalize(entry.model) == nil) then
			return nil, "unreadable_model_list"
		end
	end
	return M.names(root.models)
end

--- Represents an admitted missing-model failure for native request callbacks.
--- @param model string
--- @param base_url string
--- @return table
function M.failure(model, base_url)
	return { reason = M.MODEL_MISSING, model = model, base_url = base_url }
end

--- Classifies a model removed between the presence receipt and inference.
--- @param result any Native HTTP result.
--- @param base_url string
--- @return table|nil
function M.response_failure(result, base_url)
	if type(result) ~= "table" then return nil end
	local body = result.error_body or result.body
	local root = type(body) == "string" and require("json").decode(body) or nil
	local model = M.missing_model(result.status, type(root) == "table" and root.error or nil)
	return model and M.failure(model, base_url) or nil
end

--- Whether a native failure names a missing local model.
--- @param failure any
--- @return boolean
function M.is_missing(failure)
	return type(failure) == "table" and failure.reason == M.MODEL_MISSING
		and M.normalize(failure.model) ~= nil and type(failure.base_url) == "string"
end

--- Admits one automatic notice per normalized model, recording only delivery.
--- @param notified table Set owned by the native offer lifecycle.
--- @param model string
--- @return boolean
function M.should_notify(notified, model)
	local name = M.normalize(model)
	return name ~= nil and notified[name] ~= true
end

return M
