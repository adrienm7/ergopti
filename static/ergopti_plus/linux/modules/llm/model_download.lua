--- modules/llm/model_download.lua

--- ==============================================================================
--- MODULE: Ollama Model Download
--- DESCRIPTION:
--- Owns one asynchronous Ollama /api/pull request, parses its NDJSON progress,
--- and publishes progress into the shared download window without blocking the
--- grabbed-keyboard event loop.
--- ==============================================================================

local M = {}

local HttpBridge = require("infra.llm_bridge")
local HttpClient = require("adapters.http_client")
local Json = require("json")
local Logger = require("logger.shim")
local DownloadWindow = require("ui.download_window.bridge")

local LOG = "modules.llm.model_download"
local OWNER = "ollama_model_pull"
local MODEL_PULL_TIMEOUT_MS = 24 * 60 * 60 * 1000

local _active = nil
local _retry_request = nil
local _attempt_serial = 0

local function translated(key)
	local ok, i18n = pcall(require, "infra.i18n")
	return ok and type(i18n.get) == "function" and i18n.get(key) or key
end

local function valid_tag(tag)
	return type(tag) == "string" and tag ~= ""
		and tag:match("^[%w%._%-%/:]+$") ~= nil
end

local function finish(request, attempt, succeeded, message, failure_receipt)
	if _active ~= request or request.terminal or request.attempt ~= attempt then return end
	request.terminal = true
	_active = nil
	_retry_request = not succeeded and request or nil
	DownloadWindow.complete(request.session_id, succeeded, message, failure_receipt)
	if type(request.on_done) == "function" then
		local ok, err = pcall(request.on_done, succeeded, request.tag)
		if not ok then Logger.error(LOG, "Model-download completion callback raised: %s", tostring(err)) end
	end
end

local function consume_line(request, line)
	if line == "" then return end
	local ok, message = pcall(Json.decode, line)
	if not ok or type(message) ~= "table" then
		Logger.warn(LOG, "Ignored malformed Ollama pull progress frame.")
		return
	end
	if type(message.error) == "string" and message.error ~= "" then
		request.remote_error = message.error
		return
	end
	if message.status == "success" then request.saw_success = true end
	local completed = tonumber(message.completed)
	local total = tonumber(message.total)
	local percentage = nil
	if completed and total and total > 0 then percentage = completed * 100 / total end
	DownloadWindow.update(request.session_id, percentage,
		translated("ollama.downloading"), type(message.status) == "string" and message.status or nil)
end

local function consume_chunk(request, chunk, flush)
	request.pending = request.pending .. (type(chunk) == "string" and chunk or "")
	while true do
		local line, rest = request.pending:match("^([^\r\n]*)\r?\n(.*)$")
		if not line then break end
		request.pending = rest
		consume_line(request, line)
	end
	if flush and request.pending ~= "" then
		consume_line(request, request.pending)
		request.pending = ""
	end
end

local function dispatch(request)
	_attempt_serial = _attempt_serial + 1
	local attempt = _attempt_serial
	request.attempt = attempt
	_active = request
	local url = HttpBridge.ollama_endpoint(request.base_url, "pull")
	local ok_body, body = pcall(Json.encode, { name = request.tag, stream = true })
	if not url or not ok_body or type(body) ~= "string" then
		finish(request, attempt, false, translated("menu.llm.download_failed"))
		return false
	end
	if type(request.admission) == "function" then
		local ok, allowed = pcall(request.admission)
		if not ok or allowed ~= true then
			finish(request, attempt, false, translated("menu.llm.download_failed"))
			return false
		end
	end
	-- Consent checks may synchronously retire or replace this native owner.
	if _active ~= request or request.terminal or request.cancelled or request.attempt ~= attempt then return false end
	local dispatched = HttpClient.postStream(url, { ["Content-Type"] = "application/json" }, body, {
		owner = OWNER,
		timeout_ms = MODEL_PULL_TIMEOUT_MS,
	}, function(chunk)
		if _active ~= request or request.terminal or request.attempt ~= attempt then return end
		consume_chunk(request, chunk, false)
	end, function(result)
		if _active ~= request or request.terminal or request.attempt ~= attempt then return end
		consume_chunk(request, "", true)
		local succeeded = type(result) == "table" and result.ok == true
			and request.saw_success == true and request.remote_error == nil
		finish(request, attempt, succeeded, succeeded and translated("download_window.done_success")
			or translated("menu.llm.download_failed"),
			type(result) == "table" and result.ok ~= true and result.failure_receipt or nil)
	end)
	if dispatched ~= true and _active == request and request.attempt == attempt then
		finish(request, attempt, false, translated("menu.llm.download_failed"))
		return false
	end
	Logger.info(LOG, "Ollama model pull started for '%s'.", request.tag)
	return dispatched == true
end

--- Starts one model pull and its progress window.
--- @param base_url string
--- @param tag string Ollama-native model identity.
--- @param label string Human-readable catalogue name.
--- @param on_done function|nil
--- @param admission function|nil Current consent, rechecked after native UI creation and on every retry.
--- @return boolean
function M.start(base_url, tag, label, on_done, admission)
	if _active then
		if _active.tag == tag then return DownloadWindow.focus(_active.session_id) end
		return false
	end
	if type(base_url) ~= "string" or base_url == "" or not valid_tag(tag)
			or type(label) ~= "string" or label == "" then
		return false
	end
	local request = {
		base_url = base_url,
		tag = tag,
		label = label,
		on_done = on_done,
		admission = admission,
		pending = "",
		remote_error = nil,
		saw_success = false,
		terminal = false,
	}
	_retry_request = nil
	request.session_id = DownloadWindow.show({
		kind = "ollama_model",
		label = label,
		on_cancel = function() return M.cancel(request) end,
		on_retry = function() return M.retry(request) end,
		is_current = function()
			return not request.cancelled and (_active == request or _retry_request == request)
				and request.session_id == DownloadWindow.session_id()
		end,
		can_retry = function()
			if _active or _retry_request ~= request or request.cancelled
				or request.session_id ~= DownloadWindow.session_id() then return false end
			if type(request.admission) ~= "function" then return true end
			local ok, allowed = pcall(request.admission)
			return ok and allowed == true
		end,
	})
	if not request.session_id then return false end
	_active = request
	return dispatch(request)
end

--- Cancels the exact owned curl process group.
--- @return boolean
function M.cancel(expected)
	local request = _active
	if expected ~= nil and request ~= expected then return false end
	if not request then return true end
	if HttpClient.cancel(OWNER) ~= true then return false end
	_attempt_serial = _attempt_serial + 1
	request.attempt = _attempt_serial
	request.terminal = true
	request.cancelled = true
	_active = nil
	_retry_request = nil
	Logger.info(LOG, "Ollama model pull cancelled for '%s'.", request.tag)
	return true
end

--- Re-dispatches the last failed request in the same progress session.
--- @return boolean
function M.retry(expected)
	if _active then return false end
	local session_id = DownloadWindow.session_id()
	if not session_id then return false end
	-- The retry callback is retained by DownloadWindow inside the old request's
	-- closure; recover that request through the explicit seam set on settlement.
	local request = _retry_request
	if not request or (expected ~= nil and request ~= expected)
		or request.cancelled or request.session_id ~= session_id then return false end
	if type(request.admission) == "function" then
		local ok, allowed = pcall(request.admission)
		if not ok or allowed ~= true then return false end
	end
	-- Admission can retire this failed request or start a different operation.
	if _active or _retry_request ~= request or request.cancelled
		or request.session_id ~= DownloadWindow.session_id() then return false end
	request.pending = ""
	request.remote_error = nil
	request.saw_success = false
	request.terminal = false
	return dispatch(request)
end

--- Reports whether a pull owns a live transport.
function M.is_active()
	return _active ~= nil
end

--- Stops transport before daemon shutdown.
function M.shutdown()
	local request = _active or _retry_request
	if M.cancel() ~= true then return false end
	_retry_request = nil
	if request then
		request.cancelled = true
		if type(DownloadWindow.retire) == "function" then DownloadWindow.retire(request.session_id) end
	end
	return true
end

return M
