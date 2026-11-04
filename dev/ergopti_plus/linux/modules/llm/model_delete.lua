--- modules/llm/model_delete.lua

--- ==============================================================================
--- MODULE: Ollama Model Delete
--- DESCRIPTION:
--- Owns one asynchronous Ollama DELETE /api/delete request: the Linux side of the
--- « Delete this model from cache » row Windows and macOS draw in each model's
--- submenu. The request is sent only while its caller's admission holds, and its
--- outcome is published once, after the transport physically settled.
---
--- FEATURES & RATIONALE:
--- 1. Owned transport: the DELETE goes through the managed HTTP client, so a
---    company proxy, cancellation and process retirement follow the same rules
---    as every other Ollama request; no curl argument is composed here.
--- 2. One removal at a time: a second click while one runs is refused and logged
---    rather than queued, so two dialogs can never race on the same daemon.
--- 3. A stale caller is never answered: a pause, a reload or a backend change
---    revokes the admission, and a retired request publishes nothing.
--- ==============================================================================

local M = {}

local HttpBridge = require("infra.llm_bridge")
local HttpClient = require("adapters.http_client")
local Json = require("json")
local Logger = require("logger.shim")
local Timings = require("infra.timings")

local LOG = "modules.llm.model_delete"
local OWNER = "ollama_model_delete"
local DELETE_TIMEOUT_MS = Timings.ms("llm", "ollama_delete_timeout_ms")

-- The removal in flight, kept until its transport physically settled.
local _active = nil




-- ==================================
-- ==================================
-- ======= 1/ Request Guards ========
-- ==================================
-- ==================================

--- Whether a request may still act: no cancel retired it and its caller admits it.
--- @param request table
--- @return boolean
local function current(request)
	if _active ~= request or request.cancelled then return false end
	if request.admission == nil then return true end
	local ok, allowed = pcall(request.admission)
	return ok and allowed == true and _active == request and not request.cancelled
end

--- Whether the transport retired its process, pipes and deadline.
--- @param request table
--- @return boolean
local function settled(request)
	if request.creating or request.unknown then return false end
	if not request.operation then return true end
	local ok, value = pcall(request.settled, request.operation)
	return ok and value == true
end

--- The reason Ollama gave for a refused removal, or the transport's own.
--- @param result table|nil Buffered result envelope.
--- @return string
local function failure_reason(result)
	if type(result) ~= "table" then return "no response from Ollama" end
	if type(result.body) == "string" and result.body ~= "" then
		local ok, decoded = pcall(Json.decode, result.body)
		if ok and type(decoded) == "table" and type(decoded.error) == "string" and decoded.error ~= "" then
			return decoded.error
		end
	end
	if type(result.error) == "string" and result.error ~= "" then return result.error end
	return "HTTP " .. tostring(result.status)
end

--- Publishes the outcome once, after both the result and the settlement arrived.
--- @param request table
local function finish(request)
	if request.terminal or not settled(request) then return end
	local allowed = current(request)
	if allowed and request.result == nil then return end
	request.terminal = true
	if _active == request then _active = nil end
	if not allowed then
		Logger.info(LOG, "Deletion of the Ollama model '%s' retired before its result was published.", request.tag)
		return
	end
	local succeeded = type(request.result) == "table" and request.result.ok == true
	local reason = not succeeded and failure_reason(request.result) or nil
	if succeeded then
		Logger.info(LOG, "Ollama model '%s' deleted.", request.tag)
	else
		Logger.warn(LOG, "Ollama model '%s' was not deleted: %s.", request.tag, reason)
	end
	local ok, err = pcall(request.on_done, succeeded, request.tag, reason)
	if not ok then Logger.error(LOG, "Model-deletion completion callback raised: %s", tostring(err)) end
end




-- ==============================
-- ==============================
-- ======= 2/ Public API ========
-- ==============================
-- ==============================

--- Starts the removal of one installed model.
--- @param base_url string Ollama origin, without a path.
--- @param tag string Ollama-native model identity.
--- @param on_done function Receives (succeeded, tag, reason) once the transport settled.
--- @param admission function|nil Caller state, rechecked before sending and before publishing.
--- @return boolean dispatched
function M.start(base_url, tag, on_done, admission)
	if _active then
		Logger.warn(LOG, "Deletion of '%s' refused: the deletion of '%s' is still running.", tostring(tag), _active.tag)
		return false
	end
	if not HttpBridge.valid_ollama_tag(tag) or type(on_done) ~= "function"
		or (admission ~= nil and type(admission) ~= "function") then
		Logger.error(LOG, "Model deletion refused: invalid model tag or callbacks.")
		return false
	end
	local url = HttpBridge.ollama_endpoint(base_url, "delete")
	-- `name` is the field every Ollama release accepts; the pull sends the same.
	local encoded, body = pcall(Json.encode, { name = tag })
	if not url or not encoded or type(body) ~= "string" then
		Logger.error(LOG, "Model deletion refused: the Ollama origin or the request body is invalid.")
		return false
	end
	local request = { tag = tag, on_done = on_done, admission = admission, creating = true, terminal = false }
	_active = request
	if not current(request) then
		_active = nil
		return false
	end
	local called, operation = pcall(HttpClient.delete_owned, url, { ["Content-Type"] = "application/json" }, body, {
		owner = OWNER, timeout_ms = DELETE_TIMEOUT_MS,
		authorized = function() return current(request) end,
	}, function(result)
		request.result = result
		finish(request)
	end)
	request.creating = false
	if not called or type(operation) ~= "table" or type(operation.cancel) ~= "function"
		or type(operation.is_settled) ~= "function" or type(operation.on_settled) ~= "function"
		or type(operation.started) ~= "boolean" then
		-- Unknown native state keeps the slot: a second DELETE must not overlap it.
		request.unknown = true
		Logger.error(LOG, "Model deletion transport state is unknown — its slot stays reserved: %s.", tostring(operation))
		return false
	end
	request.operation, request.settled, request.retire = operation, operation.is_settled, operation.cancel
	if operation.started ~= true then
		request.terminal = true
		if _active == request then _active = nil end
		Logger.warn(LOG, "Deletion of the Ollama model '%s' was refused before it was sent.", tag)
		return false
	end
	Logger.info(LOG, "Deletion of the Ollama model '%s' started.", tag)
	operation:on_settled(function() finish(request) end)
	return true
end

--- Retires the removal in flight; its result is never published.
--- @return boolean settled True once no DELETE transport remains.
function M.cancel()
	local request = _active
	if not request then return true end
	request.cancelled = true
	if request.creating or request.unknown then return false end
	if request.operation then
		local called = pcall(request.retire, request.operation)
		if not called or not settled(request) then return false end
	end
	request.terminal = true
	if _active == request then _active = nil end
	Logger.info(LOG, "Deletion of the Ollama model '%s' cancelled.", request.tag)
	return true
end

--- Whether a removal owns a live transport.
--- @return boolean
function M.is_active()
	return _active ~= nil
end

return M
