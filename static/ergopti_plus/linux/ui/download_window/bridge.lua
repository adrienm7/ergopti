--- ui/download_window/bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Download Window
--- DESCRIPTION:
--- Owns the Linux session behind the shared download-progress page. Producers
--- publish progress by session ID; page cancel/retry messages call only the
--- callbacks owned by that exact session.
--- ==============================================================================

local M = {}
M.bridge_name = "dl_bridge"

local Json = require("json")
local Logger = require("logger.shim")

local APP_NAME = "download_window"
local LOG = "bridge.download_window"

local _serial = 0
local _session = nil

local function manager()
	local ok, module = pcall(require, "ui.webview_manager")
	return ok and type(module) == "table" and module or nil
end

local function translated(key)
	local ok, i18n = pcall(require, "infra.i18n")
	return ok and type(i18n.get) == "function" and i18n.get(key) or key
end

local function literal(value)
	if value == nil then return "null" end
	local ok, encoded = pcall(Json.encode, value)
	return ok and type(encoded) == "string" and encoded or "null"
end

local function evaluate(code)
	local host = manager()
	return host and type(host.eval_js) == "function"
		and host.eval_js(APP_NAME, code) == true
end

local function push_initial(session)
	if _session ~= session then return false end
	local statements = {
		"if(window.resetUI){resetUI();",
		"setKind('ollama_model',null,null);",
		"setModel(" .. literal(session.label) .. ");",
		"var terminalButton=document.getElementById('btn-term');",
		"if(terminalButton)terminalButton.style.display='none';",
		"setDetail(" .. literal(session.detail) .. ");",
		"update(" .. tostring(session.progress) .. ",null,null,null,null);",
	}
	if session.terminal then
		statements[#statements + 1] = "done(" .. tostring(session.succeeded == true) .. ","
			.. literal(session.final_message) .. ",null);"
	end
	statements[#statements + 1] = "}"
	return evaluate(table.concat(statements))
end

--- Opens one owned progress session.
--- @param opts table { label, on_cancel, on_retry }
--- @return number|nil session_id
function M.show(opts)
	if type(opts) ~= "table" or type(opts.label) ~= "string" or opts.label == "" then
		Logger.error(LOG, "Download window requires a model label.")
		return nil
	end
	local host = manager()
	if not host or type(host.show) ~= "function" or type(host.hide) ~= "function" then
		Logger.error(LOG, "Download window cannot open: webview manager is unavailable.")
		return nil
	end
	if _session and _session.terminal ~= true then
		Logger.warn(LOG, "A download session already owns the progress window.")
		if type(host.bring_to_front) == "function" then host.bring_to_front(APP_NAME) end
		return nil
	end
	if _session then host.hide(APP_NAME) end

	_serial = _serial + 1
	local session = {
		id = _serial,
		label = opts.label,
		detail = translated("download_window.starting"),
		progress = 0,
		on_cancel = opts.on_cancel,
		on_retry = opts.on_retry,
		terminal = false,
		ready = false,
		succeeded = nil,
		final_message = nil,
	}
	_session = session
	if host.show(APP_NAME) ~= true then
		_session = nil
		Logger.error(LOG, "Download progress native window could not be opened.")
		return nil
	end
	return session.id
end

--- Publishes bounded progress to the active session.
--- @param session_id number
--- @param percentage number|nil
--- @param detail string|nil
--- @param log_line string|nil
--- @return boolean
function M.update(session_id, percentage, detail, log_line)
	local session = _session
	if not session or session.id ~= session_id or session.terminal then return false end
	if type(percentage) == "number" then
		session.progress = math.max(0, math.min(99, math.floor(percentage)))
	end
	if type(detail) == "string" and detail ~= "" then session.detail = detail end
	if not session.ready then return true end
	local code = "update(" .. tostring(session.progress) .. ",null,null,null,null);"
		.. "setDetail(" .. literal(session.detail) .. ");"
	if type(log_line) == "string" and log_line ~= "" then
		code = code .. "addLog(" .. literal(log_line) .. ");"
	end
	return evaluate(code)
end

--- Settles the active session exactly once.
--- @param session_id number
--- @param succeeded boolean
--- @param message string|nil
--- @return boolean
function M.complete(session_id, succeeded, message)
	local session = _session
	if not session or session.id ~= session_id or session.terminal then return false end
	session.terminal = true
	local final_message = type(message) == "string" and message or (succeeded
		and translated("download_window.done_success")
		or translated("download_window.done_failed"))
	session.succeeded = succeeded == true
	session.final_message = final_message
	if not session.ready then return true end
	return evaluate("done(" .. tostring(session.succeeded) .. ","
		.. literal(final_message) .. ",null)")
end

--- Reopens or focuses the page owned by an existing background session.
--- @param session_id number
--- @return boolean
function M.focus(session_id)
	local session = _session
	if not session or session.id ~= session_id then return false end
	local host = manager()
	if not host or type(host.show) ~= "function" then return false end
	if type(host.is_visible) == "function" and host.is_visible(APP_NAME) == true then
		if type(host.bring_to_front) == "function" then host.bring_to_front(APP_NAME) end
		return true
	end
	session.ready = false
	return host.show(APP_NAME) == true
end

--- Handles ready/cancel/retry from the shared page.
--- @param payload any
--- @return table|nil
function M.on_message(payload)
	local session = _session
	if not session then return nil end
	if payload == "ready" then
		session.ready = true
		return { pushed = push_initial(session), session_id = session.id }
	end
	if payload == "cancel" and not session.terminal then
		local ok, accepted = pcall(session.on_cancel)
		if not ok or accepted ~= true then return { cancelled = false } end
		M.complete(session.id, false, translated("ollama.download_cancelled"))
		return { cancelled = true }
	end
	if payload == "retry" and session.terminal and type(session.on_retry) == "function" then
		session.terminal = false
		session.progress = 0
		session.detail = translated("download_window.starting")
		session.succeeded = nil
		session.final_message = nil
		local ok, accepted = pcall(session.on_retry)
		if not ok or accepted ~= true then
			session.terminal = true
			return { retried = false }
		end
		push_initial(session)
		return { retried = true }
	end
	if payload == "expand" then return { expanded = true } end
	Logger.debug(LOG, "Unknown action: %s", tostring(payload))
	return nil
end

function M.session_id()
	return _session and _session.id or nil
end

function M._reset()
	_session = nil
	_serial = 0
end

return M
