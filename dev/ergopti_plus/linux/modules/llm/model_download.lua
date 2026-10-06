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
local WindowSessionId, RetireWindow, CompleteWindow = DownloadWindow.session_id, DownloadWindow.retire, DownloadWindow.complete

local LOG = "modules.llm.model_download"
local OWNER = "ollama_model_pull"
local MODEL_PULL_TIMEOUT_MS = 24 * 60 * 60 * 1000

local _active = nil
-- Retain the exact creator/transport after logical progress has completed.
local _retained = nil
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

--- Observes actual physical retirement, never a legacy cancellation signal.
--- @param request table
--- @return boolean
local function settled(request)
	if request.creating or request.acquiring or request.unknown then return false end
	if not request.operation then return true end
	local ok, value = pcall(request.settled, request.operation)
	return ok and value == true
end

--- Ends every source callback with exact private request/attempt guards.
--- @param request table
--- @param attempt integer|nil
--- @return boolean
local function current(request, attempt)
	local allowed = true
	if request.admission ~= nil then
		if type(request.admission) ~= "function" then return false end
		local ok, value = pcall(request.admission)
		allowed = ok and value == true
	end
	return allowed and _retained == request and not request.cancelled
		and (attempt == nil or request.attempt == attempt)
end

local function finish(request, attempt, succeeded, message, failure_receipt)
	if not current(request, attempt) then
		if _active == request and _retained == request and request.attempt == attempt and not request.terminal then
			request.cancelled, request.shutting_down = true, true
			M.cancel(request)
		end
		return
	end
	if _active ~= request or request.terminal then return end
	request.terminal = true
	_active = nil
	_retry_request = not succeeded and request or nil
	DownloadWindow.complete(request.session_id, succeeded, message, failure_receipt)
	if current(request, attempt) and type(request.on_done) == "function" then
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
	if not current(request, request.attempt) or _active ~= request then return end
	DownloadWindow.update(request.session_id, percentage,
		translated("ollama.downloading"), type(message.status) == "string" and message.status or nil)
end

local function consume_chunk(request, chunk, flush)
	request.pending = request.pending .. (type(chunk) == "string" and chunk or "")
	while true do
		if request.cancelled or _active ~= request then return end
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
	if not settled(request) or request.cancelled or _retained ~= request then return false end
	request.acquiring = true
	request.operation, request.retire, request.settled = nil, nil, nil
	_attempt_serial = _attempt_serial + 1
	local attempt = _attempt_serial
	request.attempt = attempt
	_active, _retained = request, request
	local url = HttpBridge.ollama_endpoint(request.base_url, "pull")
	local ok_body, body = pcall(Json.encode, { name = request.tag, stream = true })
	if not url or not ok_body or type(body) ~= "string" then
		request.acquiring = false
		finish(request, attempt, false, translated("menu.llm.download_failed"))
		return false
	end
	if not current(request, attempt) or _active ~= request or request.terminal then
		request.acquiring = false
		request.cancelled, request.shutting_down = true, true
		M.cancel(request)
		return false
	end
	local called, operation = pcall(HttpClient.post_stream_owned,
		url, { ["Content-Type"] = "application/json" }, body, {
			owner = OWNER, timeout_ms = MODEL_PULL_TIMEOUT_MS,
			authorized = function()
				return current(request, attempt) and _active == request and not request.terminal
			end,
		}, function(chunk)
			if not current(request, attempt) or _active ~= request or request.terminal then return end
			consume_chunk(request, chunk, false)
		end, function(result)
			if not current(request, attempt) or _active ~= request or request.terminal then return end
			consume_chunk(request, "", true)
			local succeeded = type(result) == "table" and result.ok == true
				and request.saw_success == true and request.remote_error == nil
			finish(request, attempt, succeeded, succeeded and translated("download_window.done_success")
				or translated("menu.llm.download_failed"),
				type(result) == "table" and result.ok ~= true and result.failure_receipt or nil)
		end)
	request.acquiring = false
	if not called or type(operation) ~= "table" or type(operation.cancel) ~= "function"
		or type(operation.is_settled) ~= "function" or type(operation.on_settled) ~= "function"
		or type(operation.started) ~= "boolean" then
		request.cancelled, request.unknown = true, true
		return false
	end
	request.operation, request.retire, request.settled = operation, operation.cancel, operation.is_settled
	local notify = operation.on_settled
	notify(operation, function()
		if _retained ~= request or request.attempt ~= attempt or request.cancelling then return end
		local allowed = current(request, attempt)
		if _retained ~= request or request.attempt ~= attempt then return end
		if not allowed or request.cancelled then
			request.cancelled, request.shutting_down = true, true
			M.cancel(request)
		end
	end)
	if request.cancelled then M.cancel(request); return false end
	if operation.started ~= true then
		if current(request, attempt) then
			finish(request, attempt, false, translated("menu.llm.download_failed"))
		end
		return false
	end
	Logger.info(LOG, "Ollama model pull started for '%s'.", request.tag)
	return true
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
		if _active.creating or _active.acquiring or _active.cancelled then return false end
		if _active.tag == tag then return DownloadWindow.focus(_active.session_id) end
		return false
	end
	if _retained and not settled(_retained) then return false end
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
		terminal = false, creating = true,
	}
	_active, _retained, _retry_request = request, request, nil
	local shown, session = pcall(DownloadWindow.show, {
		kind = "ollama_model",
		label = label,
		on_cancel = function() return M.cancel(request) end,
		on_retry = function() return M.retry(request) end,
		is_current = function()
			local session_id = DownloadWindow.session_id()
			return current(request) and (_active == request or _retry_request == request)
				and request.session_id == session_id
		end,
		classify_failure = function() return not request.cancelled and current(request) end,
		can_retry = function()
			if _active or _retry_request ~= request or request.cancelled
				or request.session_id ~= DownloadWindow.session_id() then return false end
			return current(request) and _active == nil and _retry_request == request
		end,
	})
	request.creating = false
	if not shown then request.cancelled, request.unknown = true, true; return false end
	request.session_id = session
	if request.cancelled then M.shutdown(); return false end
	if not session then
		if _active == request then _active = nil end
		if _retained == request then _retained = nil end
		return false
	end
	return dispatch(request)
end

--- Cancels the exact owned curl process group.
--- @return boolean
function M.cancel(expected)
	local request = _active or _retained or _retry_request
	if expected ~= nil and request ~= expected then return false end
	if not request then return true end
	request.cancelled = true
	if request.creating or request.acquiring or request.unknown or request.ui_completing or request.cancelling then return false end
	if request.operation then
		-- A synchronous settlement belongs to this executing cancel claim; the
		-- caller still owns immediate cancellation presentation until it returns.
		request.cancelling = true
		local called = pcall(request.retire, request.operation)
		request.cancelling = false
		if not called or not settled(request) then return false end
	end
	if request.shutting_down and request.session_id and not request.ui_retired then
		local observed, session_id = pcall(WindowSessionId)
		if not observed or (session_id ~= nil and (type(session_id) ~= "number"
			or session_id <= 0 or session_id % 1 ~= 0)) then return false end
		if _retained ~= request and _active ~= request and _retry_request ~= request then return false end
		if session_id == request.session_id and not request.terminal and not request.ui_cancelled then
			-- Cancellation presentation is cleanup of this known namespace, never
			-- a stale server result, retry receipt or model-selection callback.
			request.ui_completing = true
			local named, message = pcall(translated, "ollama.download_cancelled")
			local same, live = pcall(WindowSessionId)
			if not named or not same or (_retained ~= request and _active ~= request and _retry_request ~= request)
				or live ~= request.session_id then request.ui_completing = false; return false end
			local called, completed = pcall(CompleteWindow, request.session_id, false, message)
			local read, now = pcall(WindowSessionId)
			request.ui_completing = false
			if not read or (now ~= nil and (type(now) ~= "number" or now <= 0 or now % 1 ~= 0))
				or (_retained ~= request and _active ~= request and _retry_request ~= request) then return false end
			if now == request.session_id and (not called or completed ~= true) then return false end
			request.ui_cancelled = true
			session_id = now
		end
		if session_id == request.session_id then
			request.ui_completing = true
			local ok, retired = pcall(RetireWindow, request.session_id)
			local read, now = pcall(WindowSessionId)
			request.ui_completing = false
			if not read or (now ~= nil and (type(now) ~= "number" or now <= 0 or now % 1 ~= 0))
				or (_retained ~= request and _active ~= request and _retry_request ~= request) then return false end
			if now == request.session_id and (not ok or retired ~= true) then return false end
		end
		-- A successfully observed absent/new serial proves this old namespace gone.
		-- Never send retirement to a different session or treat read failure as absence.
		request.ui_retired = true
	end
	if not settled(request) then return false end
	request.terminal = true
	if _active == request then _active = nil end
	if _retry_request == request then _retry_request = nil end
	if _retained == request then _retained = nil end
	Logger.info(LOG, "Ollama model pull cancelled for '%s'.", request.tag)
	return _active == nil and _retained == nil and _retry_request == nil
end

--- Re-dispatches the last failed request in the same progress session.
--- @return boolean
function M.retry(expected)
	if _active or (_retained and not settled(_retained)) then return false end
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
	local request = _active or _retained or _retry_request
	if request then request.shutting_down = true end
	if M.cancel() ~= true then return false end
	return _active == nil and _retained == nil and _retry_request == nil
end

return M
