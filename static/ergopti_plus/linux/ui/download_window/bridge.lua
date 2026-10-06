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
local _failure_serial = 0
local _contract = nil

-- The page's kinds (_shared/ui/download_window/script.js) a Linux producer
-- uses: its heading and layout
local KINDS = { ollama_model = true, app_update = true }

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

local function document_current(session)
	if _session ~= session or session.retired or not session.document_owner then return false end
	local host = manager()
	if host ~= session.host or type(host.document_owner_current) ~= "function" then return false end
	local ok, current = pcall(host.document_owner_current, session.document_owner)
	return ok and current == true and _session == session and not session.retired
		and manager() == host
end

--- Observes only the captured current presentation, never operation consent.
local function presentation_current(session, document_owner)
	if _session ~= session or session.retired or not document_owner
		or session.presentation_owner ~= document_owner then return false end
	local host = manager()
	if host ~= session.host or type(host.document_owner_current) ~= "function" then return false end
	local ok, current = pcall(host.document_owner_current, document_owner)
	return ok and current == true and _session == session and not session.retired
		and session.presentation_owner == document_owner and manager() == host
end

local function evaluate(code, session)
	session = session or _session
	if not session then return false end
	local host, document_owner = session.host, session.presentation_owner
	if not presentation_current(session, document_owner) or type(host.eval_owned_js) ~= "function" then return false end
	local ok, accepted = pcall(host.eval_owned_js, APP_NAME, document_owner, code)
	return ok and accepted == true and presentation_current(session, document_owner)
end

--- Loads the one canonical policy through the driver's native file owner.
local function contract()
	if not _contract then
		local path = require("infra.paths").shared("modules/network/managed_network.json")
		local file = assert(io.open(path, "rb"), "managed network policy unavailable")
		local ok, source = pcall(file.read, file, "*a")
		local closed = file:close()
		assert(ok and closed, "managed network policy read or close refused")
		_contract = require("network.failure").new(Json.decode(source))
	end
	return _contract
end

local function admits(callback)
	if type(callback) ~= "function" then return false end
	local ok, allowed = pcall(callback)
	return ok and allowed == true
end

local function owner_current(session)
	if _session ~= session or session.retired or session.cancelled then return false end
	if not document_current(session) or not session.pause_owner or type(session.pause_owner.is_paused) ~= "function"
		or session.pause_owner.is_paused ~= session.pause_probe then return false end
	local ok, paused = pcall(session.pause_probe)
	if not ok or paused ~= false then return false end
	local allowed = session.is_current == nil or admits(session.is_current)
	if not allowed or not document_current(session) then return false end
	ok, paused = pcall(session.pause_probe)
	return ok and paused == false and _session == session and not session.retired and not session.cancelled
		and session.pause_owner.is_paused == session.pause_probe
		and type(session.host.document_owner_retained) == "function"
		and session.host.document_owner_retained(session.document_owner) == true
end

--- Admits cleanup of this exact original operation from a fresh live page.
--- The original operation document and its retry/diagnostic consent stay intact.
local function cleanup_current(session, document_owner, pause_owner, pause_probe, callback)
	if _session ~= session or session.retired or session.terminal or session.cancelled
		or session.on_cancel ~= callback or type(callback) ~= "function"
		or session.presentation_pause_owner ~= pause_owner or session.presentation_pause_probe ~= pause_probe
		or type(pause_owner) ~= "table" or type(pause_probe) ~= "function"
		or pause_owner.is_paused ~= pause_probe then return false end
	if not presentation_current(session, document_owner) then return false end
	local ok, paused = pcall(pause_probe)
	if not ok or paused ~= false or not presentation_current(session, document_owner) then return false end
	ok, paused = pcall(pause_probe)
	return ok and paused == false and _session == session and not session.retired
		and not session.terminal and not session.cancelled and session.on_cancel == callback
		and session.presentation_owner == document_owner
		and session.presentation_pause_owner == pause_owner and session.presentation_pause_probe == pause_probe
		and pause_owner.is_paused == pause_probe
		and type(session.host.document_owner_retained) == "function"
		and session.host.document_owner_retained(document_owner) == true
end

--- Holds one cleanup intent across native document/pause/callback reentry.
local function cancel_from_presentation(session, document_owner, state)
	if session.cancelling then return { cancelled = false } end
	local callback = session.on_cancel
	local pause_owner, pause_probe = session.presentation_pause_owner, session.presentation_pause_probe
	session.cancelling = true
	-- The native message frame must retain the exact admitted pause owner.
	-- Reject foreign state under the intent before any native or pause probe.
	if not rawequal(state, pause_owner) then session.cancelling = false; return nil end
	-- Preserve native-document refusal before pause/cleanup admission, while
	-- holding the intent across this first external current-document probe.
	local observed, admitted = pcall(presentation_current, session, document_owner)
	if not observed or admitted ~= true then session.cancelling = false; return nil end
	local guarded, allowed = pcall(cleanup_current, session, document_owner, pause_owner, pause_probe, callback)
	if not guarded or allowed ~= true then session.cancelling = false; return { cancelled = false } end
	local ok, accepted = pcall(callback)
	local current, retained = pcall(cleanup_current, session, document_owner, pause_owner, pause_probe, callback)
	if not ok or accepted ~= true or not current or retained ~= true then
		session.cancelling = false
		return { cancelled = false }
	end
	local completed, visible = pcall(function()
		session.cancelled = true
		M.complete(session.id, false, translated("ollama.download_cancelled"))
		return presentation_current(session, document_owner)
	end)
	session.cancelling = false -- Finally, including presentation/translation refusal.
	return { cancelled = completed and visible == true }
end

--- Capabilities come from bound native effects, never the page's retained rows.
local function capabilities(session)
	local current = owner_current(session)
	return {
		owner_alive = current,
		retry_available = current and type(session.on_retry) == "function"
			and (session.can_retry == nil or admits(session.can_retry)),
		proxy_settings_available = current and type(session.on_proxy_settings) == "function"
			and admits(session.can_open_proxy_settings),
		download_folder_available = current and type(session.on_download_folder) == "function"
			and admits(session.can_open_download_folder),
		download_folder_owned = current and admits(session.download_folder_owned),
		diagnostics_available = current and type(session.on_diagnostics) == "function"
			and admits(session.can_open_diagnostics),
	}
end

local function invalidate_failure(session)
	_failure_serial = _failure_serial + 1
	session.failure_epoch = _failure_serial
	session.failure_report = nil
	evaluate("if(window.clearNetworkFailure)window.clearNetworkFailure();", session)
end

local function failure_code(session)
	if not session.failure_report then
		return session.terminal and session.succeeded ~= true
			and "var retry=document.getElementById('btn-retry');if(retry)retry.style.display='none';" or ""
	end
	return "if(!window.showNetworkFailure||window.showNetworkFailure("
		.. literal(session.failure_report) .. "," .. tostring(session.id) .. ","
		.. tostring(session.failure_epoch) .. ")!==true){"
		.. "var retry=document.getElementById('btn-retry');if(retry)retry.style.display='none';"
		.. "console.error('Managed download failure rendering refused');}"
end

local function push_initial(session)
	if _session ~= session then return false end
	if session.failure_report then
		-- A page readiness replay owns a fresh presentation, rather than reviving
		-- the epoch retired by the page's reset. Capability checks can reenter.
		local previous = session.failure_epoch
		local report = contract().classify(session.failure_receipt, capabilities(session))
		if _session ~= session or session.retired or not session.terminal
			or session.succeeded == true or session.failure_epoch ~= previous then return false end
		_failure_serial = _failure_serial + 1
		session.failure_epoch = _failure_serial
		session.failure_report = report
	end
	local statements = {
		"if(window.clearNetworkFailure)window.clearNetworkFailure();if(window.resetUI){resetUI();",
		"setKind(" .. literal(session.kind) .. ",null,null," .. tostring(session.id) .. ");",
		"setModel(" .. literal(session.label) .. ");",
		"var terminalButton=document.getElementById('btn-term');",
		"if(terminalButton)terminalButton.style.display='none';",
		"setDetail(" .. literal(session.detail) .. ");",
		"update(" .. tostring(session.progress) .. ",null,null,null,null);",
	}
	if session.terminal then
		statements[#statements + 1] = "done(" .. tostring(session.succeeded == true) .. ","
			.. literal(session.final_message) .. ",null);" .. failure_code(session)
	end
	statements[#statements + 1] = "}"
	return evaluate(table.concat(statements), session)
end

--- Opens one owned progress session.
--- @param opts table Kind, label, bound callbacks and fresh native capability predicates.
--- @return number|nil session_id
function M.show(opts)
	if type(opts) ~= "table" or type(opts.label) ~= "string" or opts.label == "" then
		Logger.error(LOG, "Download window requires a model label.")
		return nil
	end
	if not KINDS[opts.kind] then
		Logger.error(LOG, "Download window refused the unknown kind '%s'.", tostring(opts.kind))
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
	if _session then invalidate_failure(_session); _session.retired = true; host.hide(APP_NAME) end
	contract()

	_serial = _serial + 1
	local session = {
		id = _serial,
		host = host,
		kind = opts.kind,
		label = opts.label,
		detail = translated("download_window.starting"),
		progress = 0,
		on_cancel = opts.on_cancel,
		on_retry = opts.on_retry,
		is_current = opts.is_current,
		can_retry = opts.can_retry,
		classify_failure = opts.classify_failure,
		on_proxy_settings = opts.on_proxy_settings,
		can_open_proxy_settings = opts.can_open_proxy_settings,
		on_download_folder = opts.on_download_folder,
		can_open_download_folder = opts.can_open_download_folder,
		download_folder_owned = opts.download_folder_owned,
		on_diagnostics = opts.on_diagnostics,
		can_open_diagnostics = opts.can_open_diagnostics,
		failure_epoch = 0,
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
	session.page_epoch = type(host.current_epoch) == "function" and host.current_epoch(APP_NAME) or nil
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
	if not session or session.id ~= session_id or session.terminal or session.retired then return false end
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
	return evaluate(code, session)
end

--- Settles the active session exactly once.
--- @param session_id number
--- @param succeeded boolean
--- @param message string|nil
--- @param failure_receipt table|nil Actual typed native receipt, retained privately.
--- @return boolean
function M.complete(session_id, succeeded, message, failure_receipt)
	local session = _session
	if not session or session.id ~= session_id or session.terminal or session.retired then return false end
	session.terminal = true
	local final_message = type(message) == "string" and message or (succeeded
		and translated("download_window.done_success")
		or translated("download_window.done_failed"))
	session.succeeded = succeeded == true
	session.final_message = final_message
	if not session.succeeded and not session.cancelled
		and (session.classify_failure == nil or admits(session.classify_failure)) then
		_failure_serial = _failure_serial + 1
		session.failure_epoch = _failure_serial
		-- Keep native metadata private. Only the shared contract's safe report is sent.
		session.failure_receipt = type(failure_receipt) == "table" and failure_receipt or {}
		session.failure_report = contract().classify(session.failure_receipt, capabilities(session))
	end
	if _session ~= session or session.retired then return false end
	if not session.ready then return true end
	return evaluate("done(" .. tostring(session.succeeded) .. ","
		.. literal(final_message) .. ",null);" .. failure_code(session), session)
end

--- Reopens or focuses the page owned by an existing background session.
--- @param session_id number
--- @return boolean
function M.focus(session_id)
	local session = _session
	if not session or session.id ~= session_id or session.retired then return false end
	local host = manager()
	if not host or type(host.show) ~= "function" then return false end
	if type(host.is_visible) == "function" and host.is_visible(APP_NAME) == true then
		if type(host.bring_to_front) == "function" then host.bring_to_front(APP_NAME) end
		session.page_epoch = type(host.current_epoch) == "function" and host.current_epoch(APP_NAME) or nil
		return true
	end
	session.ready = false
	if host.show(APP_NAME) ~= true then return false end
	session.page_epoch = type(host.current_epoch) == "function" and host.current_epoch(APP_NAME) or nil
	return true
end

--- Releases readiness only for the native page that actually closed.
--- Background download ownership and explicit cancellation remain independent.
--- @param page_epoch number The epoch captured by the native close callback.
--- @return boolean True when this session owned the closed page.
function M.on_window_closed(page_epoch)
	local session = _session
	if not session or page_epoch == nil or session.page_epoch ~= page_epoch then return false end
	session.ready = false
	session.page_epoch = nil
	return true
end

--- Retires a native operation's retained actions without signalling another owner.
--- @param session_id number
--- @return boolean
function M.retire(session_id)
	local session = _session
	if not session or session.id ~= session_id then return false end
	invalidate_failure(session)
	session.retired = true
	session.terminal = true
	return true
end

--- Handles only session-bound page controls and epoch-bound failure actions.
--- @param payload any
--- @return table|nil
function M.on_message(payload, state, context)
	local session = _session
	if not session or session.retired then return nil end
	local host = manager()
	local document_owner = type(context) == "table" and context.document_owner or nil
	if not document_owner or host ~= session.host or type(host.document_owner_current) ~= "function" then return nil end
	-- Cleanup intent is claimed before the first external document observation.
	if type(payload) == "table" and rawget(payload, "action") == "cancel" then
		if rawget(payload, "session") ~= session.id then return { cancelled = false } end
		return cancel_from_presentation(session, document_owner, state)
	end
	local observed, current = pcall(host.document_owner_current, document_owner)
	if not observed or current ~= true or _session ~= session or session.retired then return nil end
	if payload == "ready" then
		local pause_probe = type(state) == "table" and state.is_paused or nil
		if type(pause_probe) ~= "function" then return nil end
		local previous = session.presentation_owner
		if previous == document_owner and (session.presentation_pause_owner ~= state
			or session.presentation_pause_probe ~= pause_probe) then return nil end
		if previous and previous ~= document_owner then
			local checked, still_current = pcall(host.document_owner_current, previous)
			if not checked or still_current ~= false then return nil end
		end
		-- Bind original consent only once. A reopened document owns display and
		-- explicit cleanup intent; it cannot revive retry or diagnostic effects.
		if not session.document_owner then
			session.document_owner = document_owner
			session.pause_owner, session.pause_probe = state, pause_probe
		end
		session.presentation_owner = document_owner
		session.presentation_pause_owner, session.presentation_pause_probe = state, pause_probe
		if not presentation_current(session, document_owner) then return nil end
		session.ready = true
		return { pushed = push_initial(session), session_id = session.id,
			failure_epoch = session.failure_epoch }
	end
	if session.presentation_owner ~= document_owner or not presentation_current(session, document_owner) then return nil end
	if type(payload) ~= "table" or payload.session ~= session.id then
		return { cancelled = false, retried = false, accepted = false }
	end
	-- Every effect other than cleanup retains the original operation consent.
	if session.document_owner ~= document_owner or not document_current(session) then
		return { cancelled = false, retried = false, accepted = false }
	end
	if payload.action == "failure_action" then
		if payload.epoch ~= session.failure_epoch or not session.terminal
			or session.succeeded == true or not session.failure_report or not owner_current(session) then
			return { accepted = false, retried = false }
		end
		local allowed = false
		for _, action in ipairs(contract().actions(session.failure_report.cause, capabilities(session))) do
			if action.id == payload.id then allowed = true end
		end
		if not allowed or not owner_current(session) or payload.epoch ~= session.failure_epoch then
			return { accepted = false, retried = false }
		end
		if payload.id == "retry" then
			local old_message = session.final_message
			invalidate_failure(session)
			session.terminal = false
			session.progress = 0
			session.detail = translated("download_window.starting")
			session.succeeded = nil
			session.final_message = nil
			-- Reset before calling: a synchronous refusal may publish a new terminal.
			if session.ready then push_initial(session) end
			local ok, accepted = pcall(session.on_retry)
			if not ok or accepted ~= true then
				if not session.terminal then M.complete(session.id, false, old_message, session.failure_receipt) end
				return { accepted = false, retried = false }
			end
			return { accepted = true, retried = true }
		end
		local callback = ({ proxy_settings = session.on_proxy_settings,
			download_folder = session.on_download_folder, diagnostics = session.on_diagnostics })[payload.id]
		local ok, accepted = pcall(callback)
		return { accepted = ok and accepted == true }
	end
	if payload.action == "expand" then return { expanded = true } end
	Logger.debug(LOG, "Unknown download action refused.")
	return nil
end

function M.session_id()
	return _session and _session.id or nil
end

function M._reset()
	_session = nil
	_serial = 0
	_failure_serial = 0
end

return M
