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
local _scope_busy = false
local _scope_owner, _scope_generation, _scope_receipts = nil, 0, setmetatable({}, { __mode = "k" })
M.bridge_name = "error_dialog"

local Logger      = require("logger.shim")
local Policy      = require("diagnostics.error_policy")
local ErrorReport = require("diagnostics.error_report")
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

-- Seconds on a monotonic clock, replaceable by tests
M.clock = function() return require("infra.monotonic").now_ms() / 1000 end

-- Runs a callback later on the daemon's loop, replaceable by tests
M.defer = function(fn, delay_ms) return require("adapters.event_loop").defer(fn, delay_ms) end





-- =================================
-- =================================
-- ======= 1/ Initialisation =======
-- =================================
-- =================================

--- Reads and validates the shared policy.
--- @return table
local function load_policy()
	local path = require("infra.paths").shared("modules/diagnostics/error_policy.json")
	local fh, err = io.open(path, "rb")
	if not fh then error("the error policy cannot be read: " .. tostring(err)) end
	local raw = fh:read("*a")
	fh:close()
	return Policy.validate(require("json").decode(raw))
end

--- Loads the policy and the Debug menu setting. Called once by the daemon,
--- before the logger's error observer is installed.
--- @return boolean initialised
function M.init()
	if _scope_owner ~= nil or _scope_busy then return false end
	_scope_generation = _scope_generation + 1
	if _policy ~= nil then
		Logger.error(LOG, "The error window was initialised twice; the second call is refused.")
		return false
	end
	Logger.start(LOG, "Initialising the error window…")
	local ok, policy = pcall(load_policy)
	if not ok then
		Logger.error(LOG, "The error window cannot start: %s.", tostring(policy))
		return false
	end
	_policy = policy
	_decisions = Policy.new_state()
	_enabled = M.is_enabled()
	Logger.success(LOG, "Error window ready (%s).", _enabled and "enabled" or "disabled")
	return true
end

--- Whether the Debug menu's "Show a window for every error" is ticked.
--- @return boolean
function M.is_enabled()
	if _enabled ~= nil then return _enabled end
	local stored = require("adapters.storage").get(SETTING, nil)
	if type(stored) == "boolean" then return stored end
	local default = require("infra.manifest_reader").default_for(SETTING)
	if type(default) ~= "boolean" then
		error("the features manifest declares no boolean default for " .. SETTING)
	end
	return default
end

--- Ticks or unticks "Show a window for every error", durably.
--- @param enabled boolean
--- @return boolean saved
function M.set_enabled(enabled)
	if _scope_owner ~= nil or _scope_busy then return false end
	_scope_generation = _scope_generation + 1
	if type(enabled) ~= "boolean" then
		Logger.error(LOG, "set_enabled() needs a boolean, got %s.", type(enabled))
		return false
	end
	if require("adapters.storage").set(SETTING, enabled) ~= true then
		Logger.error(LOG, "The error window setting could not be saved; it is unchanged.")
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
--- @return table { report, paths, documents, context, log_path, open_id }
local function build_report(record)
	local Health = require("ui.healthcheck.bridge")
	local HealthReport = require("ui.healthcheck.report")
	local documents = Health.config()
	local snapshot = Health.build_snapshot(require("ui.webview_manager").get_daemon_state(), false)
	local sections = snapshot.sections
	local versions, system, issues = sections.versions or {}, sections.system or {}, sections.issues or {}
	local generated = tostring(snapshot.generated_at)
	local identity = {
		version       = tostring(versions.ergopti_version or "unknown"),
		commit        = tostring(versions.commit or ""),
		os            = tostring(system.os or "unknown"),
		driver        = Health.DRIVER,
		generated_utc = generated,
		warn_count    = tonumber(issues.warn_count) or 0,
		err_count     = tonumber(issues.err_count) or 0,
	}
	-- The recent warnings and errors of today's errors file, as many as the
	-- diagnostics window shows (_shared/modules/diagnostics/recent_issues.json)
	local recent = {}
	for _, entry in ipairs(issues.recent or {}) do recent[#recent + 1] = tostring(entry) end
	local report = ErrorReport.compose({
		kind = record.kind, module = record.module, message = record.message, time = record.time,
		recent = recent,
	}, identity)
	local paths = {}
	for id, path in pairs(sections.paths or {}) do paths[id] = path end
	local open_id = "errors_today"
	if record.kind == "crash" then
		open_id = "crash_report"
		paths.crash_report = record.log_path
	end
	if type(paths[open_id]) ~= "string" or paths[open_id] == "" then
		error("the file this error is logged in is unknown")
	end
	return {
		report    = report,
		paths     = paths,
		documents = documents,
		context   = HealthReport.redaction_context(),
		log_path  = paths[open_id],
		open_id   = open_id,
	}
end

--- Reports one failure on GitHub exactly as this window's Report button does,
--- for a window that shows a failure of its own (the update-check window): the
--- same diagnostics report, redacted, the same prefilled issue form.
--- @param record table { kind = "error", module, message, time }
--- @return boolean reported
function M.report(record)
	if _scope_owner ~= nil or _scope_busy then return false end
	local ok_report, fields = pcall(build_report, record)
	if not ok_report then
		Logger.error(LOG, "The report of '%s' could not be built: %s.", tostring(record and record.module),
			tostring(fields))
		return false
	end
	local result = require("ui.healthcheck.report").perform(
		{ action = "report", text = fields.report.text, fields = fields.report.fields },
		fields.paths, fields.documents, fields.context)
	return result.ok == true
end

--- The page's first message: the error and its report, already redacted.
--- @param session table
--- @return table
local function init_message(session)
	local rules = session.documents.redaction
	local function redact(text) return Redact.apply(text, rules, session.context) end
	return {
		type     = "init",
		kind     = session.record.kind,
		module   = redact(session.record.module),
		message  = redact(session.record.message),
		log_path = redact(session.log_path),
		text     = redact(session.report.text),
		more     = _folded,
	}
end





-- ==============================
-- ==============================
-- ======= 3/ The Window ========
-- ==============================
-- ==============================

--- Frees the policy for the next window.
local function settle()
	_scheduled = nil
	_busy = false
	_folded = 0
	_pending = nil
	_session = nil
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
local function push(message)
	local ok, json = pcall(require("json").encode, message)
	if not ok then
		Logger.error(LOG, "An error window message could not be encoded: %s.", tostring(json))
		return false
	end
	return require("ui.webview_manager").eval_js(APP, "if(window.receiveErrorDialog)window.receiveErrorDialog(" .. json .. ")")
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
	if name == "copy" then
		action = { action = "copy", text = session.report.text }
	elseif name == "report" then
		action = { action = "report", text = session.report.text, fields = session.report.fields }
	else
		action = { action = "open_path", id = session.open_id }
	end
	local result = require("ui.healthcheck.report").perform(action, session.paths, session.documents, session.context)
	return { type = "action", action = name, ok = result.ok == true, missing = result.missing == true }
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
		_session = fields
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
	if _scope_owner ~= nil or _scope_busy then return false end
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
		schedule({ kind = "error", module = tostring(module_name), message = tostring(message),
			time = os.date("%Y-%m-%d %H:%M:%S") })
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
	if _scope_owner ~= nil or _scope_busy then return false end
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
	if _scope_owner ~= nil or _scope_busy then return false end
	_scope_generation = _scope_generation + 1
	_policy, _decisions, _enabled = nil, nil, nil
	settle()
end

local function scope_ready()
	return (_enabled == nil or type(_enabled) == "boolean") and _busy == false
		and _scheduled == nil and _session == nil and _folded == 0 and _pending == nil
end

--- Reads only the declared error state this module owns; no persistence occurs here.
local function scope_state()
	return { module = package.loaded["ui.error_dialog.bridge"], enabled = _enabled, busy = _busy, scheduled = _scheduled,
		folded = _folded, session = _session, pending = _pending }
end

local function scope_equal(left, right)
	return rawequal(left.module, right.module) and left.enabled == right.enabled and left.busy == right.busy and left.scheduled == right.scheduled and left.folded == right.folded and left.session == right.session and left.pending == right.pending
end

--- Acquires the declared runtime field for one primary transaction token.
--- @param owner table Exact token; pending() describes primary compensation only.
--- @return boolean acquired
local function scope_acquire_impl(owner)
	if type(owner) ~= "table" or type(owner.pending) ~= "function" or _scope_owner ~= nil
		or not rawequal(package.loaded["ui.error_dialog.bridge"], M) then return false end
	if not scope_ready() or not rawequal(package.loaded["ui.error_dialog.bridge"], M) then return false end
	_scope_owner = owner
	return true
end

function M.scope_acquire(owner)
	if _scope_busy then return false end
	_scope_busy = true
	local called, acquired = pcall(scope_acquire_impl, owner)
	_scope_busy = false
	return called and acquired == true
end

--- Releases the admission gate while retaining opaque inverse receipts.
--- @param owner table Exact token.
--- @return boolean released
function M.scope_release(owner)
	if _scope_busy or not rawequal(_scope_owner, owner) or owner.pending() ~= false then return false end
	_scope_owner = nil
	return true
end

--- Captures an opaque, source-bound runtime inverse under the native claim.
--- @param owner table Exact token.
--- @return table|nil receipt
local function scope_capture_impl(owner)
	if not rawequal(_scope_owner, owner) or not rawequal(package.loaded["ui.error_dialog.bridge"], M) then return nil end
	local generation = _scope_generation
	local receipt, before = {}, scope_state()
	if not rawequal(_scope_owner, owner) or not rawequal(package.loaded["ui.error_dialog.bridge"], M) or _scope_generation ~= generation then return nil end
	_scope_receipts[receipt] = { owner = owner, before = before, expected = before, generation = _scope_generation }
	return receipt
end

function M.scope_capture(owner)
	if _scope_busy then return nil end
	_scope_busy = true
	local called, result = pcall(scope_capture_impl, owner)
	_scope_busy = false
	if not called then return nil end
	return result
end

--- Applies one canonical value after proving the captured runtime still owns it.
--- @param owner table Exact token.
--- @param receipt table Native opaque receipt.
--- @param value boolean Declared error-window preference.
--- @return boolean applied
local function scope_apply_impl(owner, receipt, value)
	local data = _scope_receipts[receipt]
	if not rawequal(_scope_owner, owner) or not data or not rawequal(data.owner, owner) or data.forgotten or data.attempted
		or data.generation ~= _scope_generation or not scope_equal(scope_state(), data.expected)
		or not rawequal(package.loaded["ui.error_dialog.bridge"], M) then return false end
	if type(value) ~= "boolean" then return false end
	local next_value = {}
	for key, child in pairs(data.before) do next_value[key] = child end
	next_value.enabled = value
	_scope_generation = _scope_generation + 1
	data.generation, data.expected, data.attempted = _scope_generation, next_value, true
	local called = pcall(function()
		_enabled = next_value.enabled
	end)
	local observed = scope_state()
	return called and scope_equal(observed, next_value) and rawequal(_scope_owner, owner)
		and rawequal(package.loaded["ui.error_dialog.bridge"], M) and data.generation == _scope_generation
end

function M.scope_apply(owner, receipt, value)
	if _scope_busy then return false end
	_scope_busy = true
	local called, result = pcall(scope_apply_impl, owner, receipt, value)
	_scope_busy = false
	if not called then return false end
	return result
end

--- Restores only this receipt's acknowledged or interrupted scalar publication.
--- @param owner table Exact token.
--- @param receipt table Native opaque receipt.
--- @return boolean restored
local function scope_restore_impl(owner, receipt)
	local data = _scope_receipts[receipt]
	if not rawequal(_scope_owner, owner) or not data or not rawequal(data.owner, owner) or data.forgotten or data.generation ~= _scope_generation then return false end
	local current = scope_state()
	if not rawequal(current.module, M) or not rawequal(package.loaded["ui.error_dialog.bridge"], M) or not (rawequal(current.module, data.before.module) and current.busy == data.before.busy and current.scheduled == data.before.scheduled and current.folded == data.before.folded and current.session == data.before.session and current.pending == data.before.pending
		and (current.enabled == data.before.enabled or current.enabled == data.expected.enabled)) then return false end
	if not data.attempted or data.restored then return scope_equal(current, data.before) end
	local called = pcall(function()
		_enabled = data.before.enabled
	end)
	local observed = scope_state()
	if not called or not scope_equal(observed, data.before) or not rawequal(_scope_owner, owner)
		or not rawequal(package.loaded["ui.error_dialog.bridge"], M) or data.generation ~= _scope_generation then return false end
	_scope_generation = _scope_generation + 1
	data.generation, data.expected, data.restored = _scope_generation, data.before, true
	return true
end

function M.scope_restore(owner, receipt)
	if _scope_busy then return false end
	_scope_busy = true
	local called, result = pcall(scope_restore_impl, owner, receipt)
	_scope_busy = false
	if not called then return false end
	return result
end

--- Forgets only a finalized inverse, without changing live native state.
--- @param owner table Exact primary token.
--- @param receipt table Native opaque receipt.
--- @return boolean forgotten
function M.scope_forget(owner, receipt)
	local data = _scope_receipts[receipt]
	if _scope_busy or rawequal(_scope_owner, owner) or not data or not rawequal(data.owner, owner) or owner.pending() ~= false then return false end
	if data.forgotten then return true end
	data.before, data.expected, data.generation = nil, nil, nil
	data.forgotten = true
	return true
end

return M
