--- ui/error_dialog/bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Error Window (Linux)
--- DESCRIPTION:
--- Opens the shared error window (_shared/ui/error_dialog/) when a logged ERROR
--- passes the shared policy (_shared/modules/diagnostics/error_policy.json), or
--- at start-up when the daemon crashed since the last notice, and serves the
--- page's actions: report on GitHub, copy the report, open the file the error
--- is logged in, close.
--- Bridge name: "error_dialog"
--- The host-independent half (policy load, Debug switch, report, first
--- message) is _shared/lua/error_dialog/core.lua, shared with the other host.
---
--- FEATURES & RATIONALE:
--- 1. The shared logger core hands every emitted ERROR to M.on_error
---    synchronously, from wherever it was logged, including the keyboard loop.
---    It only decides and defers: the window opens present_delay_ms later on
---    the daemon's event loop, never from the logging call.
--- 2. diagnostics.error_policy decides: one window per error signature per
---    session, at most max_dialogs per window_sec, errors logged while a window
---    is open are counted in it, nothing while the Debug menu's "Show a window
---    for every error" is unticked.
--- 3. A crash stops the daemon before any window can open, and systemd starts
---    it again: the next start shows the newest crash dump once, as a crash
---    notice, and remembers it in the crash folder.
--- 4. The report is diagnostics.error_report's, built from the diagnostics
---    snapshot and redacted before the page sees it; copy, report and open go
---    through the diagnostics window's own actions (ui.healthcheck.report),
---    which redact again before anything leaves the machine.
--- 5. The window never takes the keyboard (focus_on_map off): it can appear
---    while the user is typing.
--- ==============================================================================

local M = {}
local _scope = require("scope_owner").new({ name = "ui.error_dialog.bridge", module = M })
M.bridge_name = "error_dialog"

local Logger      = require("logger.shim")
local Policy      = require("diagnostics.error_policy")
local DialogCore  = require("error_dialog.core")
local Redact      = require("diagnostics.redact")

local LOG = "bridge.error_dialog"

-- The window's app id (the _shared/ui directory) and the Debug menu setting,
-- as the features manifest declares it
local APP = "error_dialog"
local SETTING = "script.show_error_dialog"

-- The name of the file, in the crash folder, that remembers the newest crash
-- dump already announced
local CRASH_ACK_FILE = ".last_crash_notice"

-- The page's actions
local PAGE_ACTIONS = { report = true, copy = true, open_log = true, close = true }

-- The validated policy and the session's decisions; nil until init()
local _policy = nil
local _decisions = nil

-- Whether the window may open, as the Debug menu shows it; nil until read
local _enabled = nil

-- True from the moment a window is decided until it closes (or fails to
-- open): the policy folds every error logged in between into it
local _busy = false

-- Identity of the deferred request; disabling invalidates it before native work.
local _scheduled = nil

-- Errors folded into the pending or open window
local _folded = 0

-- The error the next window opens for, and the open window's session
local _pending = nil
local _session = nil
local _action_revision = 0

--- Retires this page's action before its child can call back into a successor.
local function cancel_action(session)
	_action_revision = _action_revision + 1
	local revision = _action_revision
	if not session then return revision end
	local request = session.action_request
	session.action_token, session.action_request = nil, nil
	if request then request.cancel() end
	return revision
end

-- Seconds on a monotonic clock, replaceable by tests
M.clock = function() return require("infra.monotonic").now_ms() / 1000 end

-- Runs a callback later on the daemon's loop, replaceable by tests
M.defer = function(fn, delay_ms) return require("adapters.event_loop").defer(fn, delay_ms) end





-- =================================
-- =================================
-- ======= 1/ Initialisation =======
-- =================================
-- =================================

--- Loads the policy and the Debug menu setting. Called once by the daemon,
--- before the logger's error observer is installed.
--- @return boolean initialised
function M.init()
	if not _scope.admit_change() then return false end
	return DialogCore.init(Logger, LOG, _policy ~= nil,
		function() return require("infra.paths").shared("modules/diagnostics/error_policy.json") end,
		function(policy, decisions)
			_policy, _decisions = policy, decisions
			_enabled = M.is_enabled()
			return _enabled
		end)
end

--- Whether the Debug menu's "Show a window for every error" is ticked.
--- @return boolean
function M.is_enabled()
	if _enabled ~= nil then return _enabled end
	return DialogCore.stored_enabled(require("adapters.storage"),
		function(path) return require("infra.manifest_reader").default_for(path) end, SETTING)
end

--- Ticks or unticks "Show a window for every error", durably.
--- @param enabled boolean
--- @return boolean saved
function M.set_enabled(enabled)
	if not _scope.admit_change() then return false end
	if not DialogCore.save_enabled(Logger, LOG, function() return require("adapters.storage") end, SETTING, enabled) then
		return false
	end
	_enabled = enabled
	if not enabled and _scheduled ~= nil then
		_scheduled = nil
		_busy, _folded, _pending = false, 0, nil
	end
	Logger.debug(LOG, "Error window %s.", enabled and "enabled" or "disabled")
	return true
end





-- ==============================
-- ==============================
-- ======= 2/ The Report ========
-- ==============================
-- ==============================

--- The report of one error, from the diagnostics snapshot.
--- @param record table { kind, module, message, time, log_path? }
--- @return table { report, snapshot, paths, documents, context, log_path, open_id }
local function build_report(record)
	local Health = require("ui.healthcheck.bridge")
	local HealthReport = require("ui.healthcheck.report")
	local documents = Health.config()
	local snapshot = Health.build_snapshot(require("ui.webview_manager").get_daemon_state(), false)
	local composed = DialogCore.compose(record, snapshot, Health.DRIVER)
	return {
		report    = composed.report,
		snapshot  = snapshot,
		paths     = composed.paths,
		documents = documents,
		context   = HealthReport.redaction_context(),
		log_path  = composed.log_path,
		open_id   = composed.open_id,
	}
end

--- Reports one failure on GitHub exactly as this window's Report button does,
--- for a window that shows a failure of its own (the update-check window): the
--- same diagnostics report, redacted, the same prefilled issue form.
--- @param record table { kind = "error", module, message, time }
--- @return table|nil cancellable report; completion receives its actual outcome.
function M.report(record, complete, current)
	assert(type(complete) == "function" and type(current) == "function", "Error report needs its completion owner")
	local generation = _scope.generation()
	local function owned()
		return current() == true and generation == _scope.generation() and _scope.idle()
			and package.loaded["ui.error_dialog.bridge"] == M
	end
	if not owned() then return nil end
	local ok_report, fields = pcall(build_report, record)
	if not owned() then return nil end
	if not ok_report then
		Logger.error(LOG, "The report of '%s' could not be built: %s.", tostring(record and record.module), tostring(fields))
		if owned() then complete(false) end
		return nil
	end
	local shared = require("healthcheck.share").document(fields.snapshot, fields.documents.schema,
		require("infra.i18n").get(fields.documents.schema.share_policy.notice_key))
	if not owned() then return nil end
	return require("ui.healthcheck.report").perform(
		{ action = "report", text = shared.text, fields = shared.fields },
		fields.paths, fields.documents, fields.context, nil, fields.snapshot, {
			current = owned, complete = function(result) if owned() then complete(result.ok == true, result.missing == true) end end,
		})
end

--- The page's first message: the error and its report, already redacted.
--- @param session table
--- @return table
local function init_message(session)
	local rules = session.documents.redaction
	local function redact(text) return Redact.apply(text, rules, session.context) end
	return DialogCore.init_message(session.record, session.report, session.log_path, _folded, redact)
end





-- ==============================
-- ==============================
-- ======= 3/ The Window ========
-- ==============================
-- ==============================

--- Frees the policy for the next window.
local function settle()
	local previous = _session
	_scheduled = nil
	_busy = false
	_folded = 0
	_pending = nil
	_session = nil
	cancel_action(previous)
end

--- Opens the window for the pending error.
--- @return boolean opened
local function open_window()
	Logger.start(LOG, "Opening the error window…")
	local manager = require("ui.webview_manager")
	local record = _pending
	local epoch = manager.current_epoch(APP)
	-- A window left open (its close box raced this one) is replaced; its close
	-- hook settles the policy, so the pending error is restored after it
	if epoch ~= nil and not manager.hide(APP, epoch) then
		Logger.error(LOG, "The open error window could not be replaced.")
		return false
	end
	_busy, _pending = true, record
	local opened = manager.show(APP, require("infra.i18n").get_locale())
	if not opened then
		-- Without a window (no WebKitGTK, no display) the error is announced and
		-- stays in the errors file
		local I18n = require("infra.i18n")
		require("adapters.application_notifier").send(record.message,
			{ title = I18n.get("common.error_title"), level = "error" })
		Logger.warn(LOG, "The error window could not open; the error was announced by a notification.")
		return false
	end
	Logger.success(LOG, "Error window opened.")
	return true
end

--- Schedules the window for a decided error, off the logging call's stack.
--- @param record table
local function schedule(record)
	_busy = true
	_pending = record
	_scheduled = record
	local queued = M.defer(function()
		if _scheduled ~= record then return end
		_scheduled = nil
		local ok, opened = xpcall(open_window, debug.traceback)
		if not ok then Logger.error(LOG, "The error window could not open: %s", tostring(opened)) end
		if not ok or not opened then settle() end
	end, _policy.present_delay_ms)
	if not queued then
		settle()
		Logger.error(LOG, "The error window could not be scheduled.")
	end
end

--- Pushes a message into the open window.
--- @param message table
--- @return boolean pushed
local function push(message, expected)
	local manager = require("ui.webview_manager")
	if expected and (_session ~= expected or manager.current_epoch(APP) ~= expected.epoch) then return false end
	local ok, json = pcall(require("json").encode, message)
	if not ok then
		Logger.error(LOG, "An error window message could not be encoded: %s.", tostring(json))
		return false
	end
	if expected and (_session ~= expected or manager.current_epoch(APP) ~= expected.epoch) then return false end
	return manager.eval_js(APP, "if(window.receiveErrorDialog)window.receiveErrorDialog(" .. json .. ")")
end

--- Performs one action of the page.
--- @param name string
--- @param context table|nil The routed message's context (close_owned_window).
--- @return table|nil The answer to the page.
local function perform(name, context)
	if name == "close" then
		local owned = type(context) == "table" and type(context.close_owned_window) == "function"
		settle()
		if owned then context.close_owned_window() end
		Logger.info(LOG, "Error window closed.")
		return nil
	end
	local session = _session
	local action
	local shared
	if name == "copy" or name == "report" then
		shared = require("healthcheck.share").document(session.snapshot, session.documents.schema,
			require("infra.i18n").get(session.documents.schema.share_policy.notice_key))
	end
	if name == "copy" then
		action = { action = "copy", text = shared.text }
	elseif name == "report" then
		action = { action = "report", text = shared.text, fields = shared.fields }
	else
		action = { action = "open_path", id = session.open_id }
	end
	local revision = cancel_action(session)
	if _session ~= session or revision ~= _action_revision then return nil end
	local token = { snapshot = session.snapshot, generation = _scope.generation() }
	session.action_token = token
	local inline, answer, completed = true, nil, false
	local function current()
		return _session == session and session.action_token == token and session.snapshot == token.snapshot
			and _scope.generation() == token.generation and require("ui.webview_manager").current_epoch(APP) == session.epoch
	end
	local request = require("ui.healthcheck.report").perform(action, session.paths, session.documents, session.context, nil, session.snapshot, {
		current = current,
		complete = function(result)
			if not current() or completed then return end
			completed = true
			session.action_request = nil
			local message = { type = "action", action = name, ok = result.ok == true, missing = result.missing == true }
			if inline then answer = message else push(message, session) end
		end,
	})
	inline = false
	if current() and not completed then session.action_request = request else request.cancel() end
	return answer
end

--- Handles an incoming page message.
--- @param payload any String or table from host_bridge.js.
--- @param _state table Daemon state (unused: the report is built from the snapshot).
--- @param context table|nil { app_name, epoch, close_owned_window } from the webview manager.
--- @return table|nil The answer the page receives.
function M.on_message(payload, _state, context)
	if payload == "ready" then
		if not _pending then
			Logger.warn(LOG, "The error window asked for an error while none is pending.")
			return nil
		end
		local ok, fields = pcall(build_report, _pending)
		if not ok then
			Logger.error(LOG, "The error report could not be built: %s.", tostring(fields))
			return nil
		end
		local previous = _session
		local revision = cancel_action(previous)
		if _session ~= previous or revision ~= _action_revision then return nil end
		_session = fields
		_session.epoch = type(context) == "table" and context.epoch or nil
		_session.record = _pending
		return init_message(_session)
	end
	if not _session then
		Logger.warn(LOG, "An error window message arrived for a window that is gone.")
		return nil
	end
	local name = type(payload) == "table" and payload.action or nil
	if type(name) ~= "string" or not PAGE_ACTIONS[name] then
		Logger.warn(LOG, "Refused an error window message that is not one of its actions.")
		return nil
	end
	Logger.info(LOG, "Error window action: %s.", name)
	local ok, answer = xpcall(perform, debug.traceback, name, context)
	if not ok then
		Logger.error(LOG, "The error window action '%s' failed: %s", name, tostring(answer))
		return { type = "action", action = name, ok = false }
	end
	return answer
end

--- Frees the policy when the user closes the window with its close box.
--- @param epoch number|nil
function M.on_window_closed(epoch)
	local manager = require("ui.webview_manager")
	if epoch ~= nil and manager.current_epoch(APP) ~= nil and manager.current_epoch(APP) ~= epoch then return end
	settle()
end





-- ================================
-- ================================
-- ======= 4/ Logged Errors =======
-- ================================
-- ================================

--- Decides what a logged ERROR does. Installed as the shared logger core's
--- error observer: it runs synchronously inside the logging call, so it only
--- decides and defers, and never logs.
--- @param module_name string
--- @param template string The message before its arguments.
--- @param message string The formatted message.
function M.on_error(module_name, template, message)
	if not _scope.idle() then return false end
	if _policy == nil then return end
	local verdict = Policy.decide(_decisions, _policy, {
		module = module_name, template = template, at = M.clock(), enabled = M.is_enabled(), open = _busy,
	})
	if verdict == "folded" then
		_folded = _folded + 1
		if _session then
			M.defer(function() push({ type = "more", count = _folded }) end, 0)
		end
	elseif verdict == "show" then
		schedule(DialogCore.error_record(module_name, message))
	end
end





-- =================================
-- =================================
-- ======= 5/ Crash Notice =========
-- =================================
-- =================================

--- Reads a whole small file.
--- @param path string
--- @return string|nil
local function read_file(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local content = fh:read("*a")
	fh:close()
	return content
end

--- The module and the error of a crash dump, from its header lines.
--- @param text string
--- @return string module
--- @return string message The error, then the stack when the dump has one.
function M.parse_crash_dump(text)
	local module_name = text:match("\nModule:%s*([^\n]*)") or "daemon"
	local message = text:match("\nError:%s*([^\n]*)") or ""
	local stack = text:match("\nStack:\n(.*)$")
	if stack and stack ~= "" then message = message .. "\n" .. stack:gsub("\n+$", "") end
	return module_name, message
end

--- Shows the newest crash dump once, when the daemon crashed since the last
--- notice. Called by the daemon once its loop runs.
--- @param crash_dir string The crash reporter's folder.
--- @return boolean shown
function M.notify_last_crash(crash_dir)
	if not _scope.idle() then return false end
	if _policy == nil then return false end
	-- Unticked, or a window already on its way: the dump stays unannounced and
	-- is offered again at the next start
	if not M.is_enabled() or _busy then return false end
	local Shell = require("adapters.shell_runner")
	local newest = Shell.exec_line("ls -1t " .. Shell.quote(crash_dir) .. " 2>/dev/null | grep -v '^%.' | head -n 1")
	if type(newest) ~= "string" or newest == "" then return false end
	local ack_path = crash_dir .. "/" .. CRASH_ACK_FILE
	local acknowledged = read_file(ack_path)
	if acknowledged and acknowledged:gsub("%s+$", "") == newest then return false end
	-- Remembered before the window opens: a notice that crashes the daemon
	-- again must not become a crash loop of notices
	local fh = io.open(ack_path, "wb")
	if not fh then
		Logger.error(LOG, "The crash notice cannot be remembered in %s; it is not shown.", crash_dir)
		return false
	end
	fh:write(newest, "\n")
	fh:close()
	local path = crash_dir .. "/" .. newest
	local text = read_file(path)
	if not text then
		Logger.error(LOG, "The crash dump %s cannot be read.", path)
		return false
	end
	local module_name, message = M.parse_crash_dump(text)
	Logger.info(LOG, "The daemon crashed since the last start (%s); showing the notice.", newest)
	schedule({ kind = "crash", module = module_name, message = message, time = newest, log_path = path })
	return true
end

--- Test seam: forgets the policy, the decisions and the window.
function M._reset()
	if not _scope.admit_change() then return false end
	_policy, _decisions, _enabled = nil, nil, nil
	settle()
end

local function scope_ready()
	return (_enabled == nil or type(_enabled) == "boolean") and _busy == false
		and _scheduled == nil and _session == nil and _folded == 0 and _pending == nil
end

_scope.install({
	-- Reads only the declared error state this module owns; no persistence occurs here.
	state = function()
		return { enabled = _enabled, busy = _busy, scheduled = _scheduled, folded = _folded, session = _session,
			pending = _pending }
	end,
	stable = { "busy", "scheduled", "folded", "session", "pending" },
	published = { "enabled" },
	ready = scope_ready,
	accept = function(value)
		if type(value) ~= "boolean" then return nil end
		return { enabled = value }
	end,
	publish = function(target) _enabled = target.enabled end,
})

return M
