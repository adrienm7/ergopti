--- ui/error_dialog/init.lua

--- ==============================================================================
--- MODULE: Error Window (macOS)
--- DESCRIPTION:
--- Opens the shared error window (_shared/ui/error_dialog/) when a logged ERROR
--- passes the shared policy (_shared/modules/diagnostics/error_policy.json):
--- what went wrong, where it is logged, and the buttons to report it on
--- GitHub, copy the report, open the errors file or close the window.
---
--- FEATURES & RATIONALE:
--- 1. The logger hands every emitted ERROR here after its native ACK, from the
---    transport pump (infra/logger.lua), never from the event tap that may
---    have logged it; the window itself opens present_delay_ms later on a
---    timer. It replaces the system notification every ERROR used to raise.
--- 2. diagnostics.error_policy decides: one window per error signature per
---    session, at most max_dialogs per window_sec, errors logged while a
---    window is open are counted in it, nothing while the Debug menu's "Show a
---    window for every error" is unticked.
--- 3. The window is presented like every Ergopti window (ui_builder.force_focus):
---    raised and focused when it opens, never given a level (maintainer rule,
---    2026-09-29). AppKit keeps a window of the inactive Hammerspoon app behind
---    the user's key window, so show() alone left the error invisible. It
---    allows text entry because a Hammerspoon webview becomes key only then:
---    with it off, a click never brought the buried window back in front.
--- 4. The report is diagnostics.error_report's, built from the diagnostics
---    snapshot and redacted before the page sees it; copy, report and open go
---    through the diagnostics window's own actions (ui.healthcheck.report),
---    which redact again before anything leaves the machine.
--- 5. One window at a time, owned by a generation: a late message or callback
---    of a closed window is inert.
--- ==============================================================================

local M = {}
local _scope_busy = false
local _scope_owner, _scope_generation, _scope_receipts = nil, 0, setmetatable({}, { __mode = "k" })

local hs             = hs
local Logger         = require("infra.logger")
local Paths          = require("infra.paths")
local Policy         = require("diagnostics.error_policy")
local ErrorReport    = require("diagnostics.error_report")
local Redact         = require("diagnostics.redact")
local TimerScheduler = require("adapters.timer_scheduler")
local Storage        = require("adapters.storage")

local LOG = "error_dialog"

-- The message handler name host_bridge.js posts to, and the apps.manifest id
local BRIDGE = "error_dialog"

-- The Debug menu setting, as the features manifest declares it
local SETTING = "script.show_error_dialog"

-- The page's actions and what the host does for each
local PAGE_ACTIONS = { report = true, copy = true, open_log = true, close = true }

-- The validated policy and the session's decisions; nil until init()
local _policy = nil
local _decisions = nil

-- Whether the window may open, as the Debug menu shows it
local _enabled = nil

-- True from the moment a window is decided until it closes (or fails to open):
-- the policy folds every error logged in between into it
local _busy = false

-- Identity of the deferred request; disabling invalidates it before native work.
local _scheduled = nil

-- Errors folded into the pending or open window
local _folded = 0

-- The open window's session: { generation, webview, controller, record, report, paths }
local _session = nil
local _generation = 0

-- Seconds on a monotonic clock, replaceable by tests
M.clock = function() return TimerScheduler.now_ns() / 1e9 end





-- =================================
-- =================================
-- ======= 1/ Initialisation =======
-- =================================
-- =================================

--- Reads and validates the shared policy.
--- @return table
local function load_policy()
	local path = Paths.shared("modules/diagnostics/error_policy.json")
	local fh, err = io.open(path, "rb")
	if not fh then error("the error policy cannot be read: " .. tostring(err)) end
	local raw = fh:read("*a")
	fh:close()
	return Policy.validate(require("json").decode(raw))
end

--- Loads the policy and the Debug menu setting. Called once, from init.lua,
--- before the logger's error handler is registered.
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
	local stored = Storage.get(SETTING, nil)
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
	if Storage.set(SETTING, enabled) ~= true then
		Logger.error(LOG, "The error window setting could not be saved; it is unchanged.")
		return false
	end
	_enabled = enabled
	if not enabled and _scheduled ~= nil then
		_scheduled = nil
		_busy = false
		_folded = 0
	end
	Logger.debug(LOG, "Error window %s.", enabled and "enabled" or "disabled")
	return true
end





-- ==============================
-- ==============================
-- ======= 2/ The Window ========
-- ==============================
-- ==============================

--- Sends a message into the session's page.
--- @param session table
--- @param message table
--- @return boolean submitted
local function send(session, message)
	if _session ~= session then return false end
	local ok_json, json = pcall(hs.json.encode, message)
	if not ok_json or type(json) ~= "string" then
		Logger.error(LOG, "An error window message could not be encoded: %s.", tostring(json))
		return false
	end
	local ok, err = pcall(function()
		session.webview:evaluateJavaScript("if(window.receiveErrorDialog)window.receiveErrorDialog(" .. json .. ")")
	end)
	if not ok then
		Logger.error(LOG, "The error window could not be reached: %s.", tostring(err))
		return false
	end
	return true
end

--- Forgets the session and frees the policy for the next window.
--- @param session table
local function retire(session)
	if _session ~= session then return end
	_session = nil
	_busy = false
	_folded = 0
	_generation = _generation + 1
	local controller = session.controller
	session.controller = nil
	if controller then
		local ok, err = pcall(function() return controller:setCallback(nil) end)
		if not ok then Logger.error(LOG, "The error window's message handler could not be released: %s.", tostring(err)) end
	end
end

--- Closes the session's window.
--- @param session table
local function close(session)
	if _session ~= session then return end
	local webview = session.webview
	retire(session)
	local ok, err = pcall(function() webview:delete() end)
	if not ok then Logger.error(LOG, "The error window could not be closed: %s.", tostring(err)) end
	Logger.info(LOG, "Error window closed.")
end

--- The page's first message: the error and its report, already redacted.
--- @param session table
--- @return table
local function init_message(session)
	local redaction = session.redaction
	local function redact(text) return Redact.apply(text, redaction.rules, redaction.context) end
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

--- Performs one action of the page.
--- @param session table
--- @param name string
local function perform(session, name)
	if name == "close" then return close(session) end
	local Report = require("ui.healthcheck.report")
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
	local result = Report.perform(action, session.paths, session.documents, session.redaction.context, nil, session.snapshot)
	send(session, { type = "action", action = name, ok = result.ok == true, missing = result.missing == true })
end

--- Handles one message of the session's page.
--- @param session table
--- @param message table The usercontent message ({ body = … }).
local function on_page_message(session, message)
	if _session ~= session then return end
	local body = type(message) == "table" and message.body or nil
	if body == "ready" then
		send(session, init_message(session))
		return
	end
	local name = type(body) == "table" and body.action or nil
	if type(name) ~= "string" or not PAGE_ACTIONS[name] then
		Logger.warn(LOG, "Refused an error window message that is not one of its actions.")
		return
	end
	Logger.info(LOG, "Error window action: %s.", name)
	local ok, err = xpcall(perform, debug.traceback, session, name)
	if not ok then
		Logger.error(LOG, "The error window action '%s' failed: %s", name, tostring(err))
		send(session, { type = "action", action = name, ok = false })
	end
end

--- The report of one error, from the diagnostics snapshot.
--- @param record table { kind, module, message, time, log_path?, open_id? }
--- @return table session fields { report, snapshot, paths, documents, redaction, log_path, open_id }
local function build_report(record)
	local Core = require("ui.healthcheck.core")
	local HealthReport = require("ui.healthcheck.report")
	local documents = Core.config()
	local snapshot = Core.run()
	local sections = snapshot.sections
	local versions, system, issues = sections.versions or {}, sections.system or {}, sections.issues or {}
	local generated = tostring(snapshot.generated_at)
	local identity = {
		version       = tostring(versions.ergopti_version or "unknown"),
		commit        = tostring(versions.commit or ""),
		os            = tostring(system.os or "unknown"),
		driver        = Core.DRIVER,
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
	local open_id, log_path = "errors_today", paths.errors_today
	if record.kind == "crash" then
		open_id, log_path = "crash_report", record.log_path
		paths.crash_report = record.log_path
	end
	if type(log_path) ~= "string" or log_path == "" then error("the file this error is logged in is unknown") end
	return {
		report    = report,
		snapshot  = snapshot,
		paths     = paths,
		documents = documents,
		redaction = { rules = documents.redaction, context = HealthReport.redaction_context() },
		log_path  = log_path,
		open_id   = open_id,
	}
end

--- Opens the window for one error and presents it (raised and focused once).
--- @param record table { kind, module, message, time }
--- @return boolean opened
local function open_window(record)
	Logger.start(LOG, "Opening the error window…")
	local ok_report, fields = pcall(build_report, record)
	if not ok_report then
		Logger.error(LOG, "The error report could not be built: %s.", tostring(fields))
		return false
	end
	local ui_builder = require("ui.ui_builder")
	local ok_html, html = pcall(ui_builder.build_injected_html, (Paths.shared("ui/error_dialog") or "") .. "/")
	if not ok_html or type(html) ~= "string" then
		Logger.error(LOG, "The error window page could not be built: %s.", tostring(html))
		return false
	end
	local geo = ui_builder.get_app_geometry("error_dialog")
	if not geo then
		Logger.error(LOG, "No geometry for 'error_dialog' in apps.manifest.json; the window cannot open.")
		return false
	end
	local screen = hs.screen.mainScreen()
	if not screen or type(screen.frame) ~= "function" then error("the main screen is unavailable") end
	local sf = screen:frame()
	local frame = {
		x = math.floor(sf.x + (sf.w - geo.width) / 2),
		y = math.floor(sf.y + (sf.h - geo.height) / 2),
		w = geo.width,
		h = geo.height,
	}
	local ok_ucc, controller = pcall(hs.webview.usercontent.new, BRIDGE)
	if not ok_ucc or not controller then
		Logger.error(LOG, "The error window message handler could not be created: %s.", tostring(controller))
		return false
	end
	local ok_wv, webview = pcall(hs.webview.new, frame, { developerExtrasEnabled = false }, controller)
	if not ok_wv or not webview then
		Logger.error(LOG, "The error window could not be created: %s.", tostring(webview))
		return false
	end

	_generation = _generation + 1
	local session = {
		generation = _generation,
		webview    = webview,
		controller = controller,
		record     = record,
	}
	for key, value in pairs(fields) do session[key] = value end
	_session = session

	local ok_cb, cb_err = pcall(function()
		controller:setCallback(function(message) on_page_message(session, message) end)
	end)
	if not ok_cb then
		Logger.error(LOG, "The error window message handler was refused: %s.", tostring(cb_err))
		close(session)
		return false
	end
	local masks = hs.webview.windowMasks
	for _, step in ipairs(ui_builder.window_chrome_steps(webview, {
		style_masks = (masks["titled"] or 1) + (masks["closable"] or 2) + (masks["resizable"] or 8),
	})) do
		local ok_step, step_err = pcall(step.apply)
		if not ok_step then Logger.warn(LOG, "%s() failed: %s.", step.name, tostring(step_err)) end
	end
	local i18n = require("infra.i18n")
	pcall(function() webview:windowTitle(ui_builder.window_title(i18n.get("common.error_title"))) end)
	pcall(function() webview:allowTextEntry(true) end)
	pcall(function() webview:allowNewWindows(false) end)
	pcall(function() webview:allowGestures(false) end)
	pcall(function()
		webview:windowCallback(function(action)
			if _session ~= session then return end
			if action == "closing" or action == "closed" then retire(session) end
		end)
	end)
	pcall(function()
		webview:navigationCallback(function(action)
			if _session ~= session or action ~= "didFinishNavigation" then return end
			local ok_strings, strings = pcall(function() return require("infra.locale").catalogue() end)
			local ok_enc, json = pcall(hs.json.encode, ok_strings and strings or {})
			if not ok_strings or not ok_enc then
				Logger.error(LOG, "The error window's strings could not be prepared.")
				return
			end
			pcall(function() webview:evaluateJavaScript("if(window.i18n_apply){window.i18n_apply(" .. json .. ");}") end)
		end)
	end)
	local ok_html_load, html_err = xpcall(function() return webview:html(html) end, debug.traceback)
	if not ok_html_load or html_err == nil or html_err == false then
		Logger.error(LOG, "The error window page could not be loaded: %s.", tostring(html_err))
		close(session)
		return false
	end
	local ok_show, show_err = xpcall(function() return webview:show() end, debug.traceback)
	if not ok_show or show_err == nil or show_err == false then
		Logger.error(LOG, "The error window could not be shown: %s.", tostring(show_err))
		close(session)
		return false
	end
	-- show() only orders the window front inside Hammerspoon, which is not the
	-- active app while the user types elsewhere, so AppKit keeps it behind the
	-- user's key window. Present it through the shared helper: raised and
	-- focused once, at the normal level, so the next window the user opens
	-- covers it. The helper logs its own failure; the window stays open.
	ui_builder.force_focus(webview, true, { is_current = function() return _session == session end })
	Logger.success(LOG, "Error window opened.")
	return true
end

--- Opens the window for a decided error, off the logging call's stack.
--- @param record table
local function schedule(record)
	_scheduled = record
	local _, committed = TimerScheduler.after(_policy.present_delay_ms / 1000, function()
		if _scheduled ~= record then return end
		_scheduled = nil
		local ok, opened = xpcall(open_window, debug.traceback, record)
		if ok and opened then return end
		if not ok then
			Logger.error(LOG, "The error window could not open: %s", tostring(opened))
			if _session then close(_session) end
		end
		-- A window that could not open frees the policy for the next error
		_busy = false
		_folded = 0
	end)
	if committed ~= true then
		_scheduled = nil
		_busy = false
		Logger.error(LOG, "The error window could not be scheduled.")
	end
end





-- ================================
-- ================================
-- ======= 3/ Logged Errors =======
-- ================================
-- ================================

--- Decides what a logged ERROR does. Called by the logger's error handler
--- after the line's native ACK.
--- @param module_name string
--- @param template string The message before its arguments.
--- @param message string The formatted message.
--- @return boolean handled Always true: an error the policy keeps quiet is
---   still logged, which is the handler's whole contract.
function M.on_error(module_name, template, message)
	if _scope_owner ~= nil or _scope_busy then return false end
	if _policy == nil then return true end
	local verdict = Policy.decide(_decisions, _policy, {
		module = module_name, template = template, at = M.clock(), enabled = M.is_enabled(), open = _busy,
	})
	if verdict == "folded" then
		_folded = _folded + 1
		if _session then send(_session, { type = "more", count = _folded }) end
	elseif verdict == "show" then
		_busy = true
		schedule({ kind = "error", module = tostring(module_name), message = tostring(message),
			time = os.date("%Y-%m-%d %H:%M:%S") })
	end
	return true
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
	local shared = require("healthcheck.share").document(fields.snapshot, fields.documents.schema,
		require("infra.i18n").get(fields.documents.schema.share_policy.notice_key))
	local result = require("ui.healthcheck.report").perform(
		{ action = "report", text = shared.text, fields = shared.fields },
		fields.paths, fields.documents, fields.redaction.context, nil, fields.snapshot)
	return result.ok == true
end

--- Test seam: forgets the policy, the decisions and the window.
function M._reset()
	if _scope_owner ~= nil or _scope_busy then return false end
	_scope_generation = _scope_generation + 1
	if _session then retire(_session) end
	_scheduled = nil
	_policy, _decisions, _enabled, _busy, _folded = nil, nil, nil, false, 0
end

local function scope_ready()
	return (_enabled == nil or type(_enabled) == "boolean") and _busy == false
		and _scheduled == nil and _session == nil and _folded == 0
end

--- Reads only the declared error state this module owns; no persistence occurs here.
local function scope_state()
	return { module = package.loaded["ui.error_dialog"], enabled = _enabled, busy = _busy, scheduled = _scheduled,
		folded = _folded, session = _session }
end

local function scope_equal(left, right)
	return rawequal(left.module, right.module) and left.enabled == right.enabled and left.busy == right.busy and left.scheduled == right.scheduled and left.folded == right.folded and left.session == right.session
end

--- Acquires the declared runtime field for one primary transaction token.
--- @param owner table Exact token; pending() describes primary compensation only.
--- @return boolean acquired
local function scope_acquire_impl(owner)
	if type(owner) ~= "table" or type(owner.pending) ~= "function" or _scope_owner ~= nil
		or not rawequal(package.loaded["ui.error_dialog"], M) then return false end
	if not scope_ready() or not rawequal(package.loaded["ui.error_dialog"], M) then return false end
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
	if not rawequal(_scope_owner, owner) or not rawequal(package.loaded["ui.error_dialog"], M) then return nil end
	local generation = _scope_generation
	local receipt, before = {}, scope_state()
	if not rawequal(_scope_owner, owner) or not rawequal(package.loaded["ui.error_dialog"], M) or _scope_generation ~= generation then return nil end
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
		or not rawequal(package.loaded["ui.error_dialog"], M) then return false end
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
		and rawequal(package.loaded["ui.error_dialog"], M) and data.generation == _scope_generation
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
	if not rawequal(current.module, M) or not rawequal(package.loaded["ui.error_dialog"], M) or not (rawequal(current.module, data.before.module) and current.busy == data.before.busy and current.scheduled == data.before.scheduled and current.folded == data.before.folded and current.session == data.before.session
		and (current.enabled == data.before.enabled or current.enabled == data.expected.enabled)) then return false end
	if not data.attempted or data.restored then return scope_equal(current, data.before) end
	local called = pcall(function()
		_enabled = data.before.enabled
	end)
	local observed = scope_state()
	if not called or not scope_equal(observed, data.before) or not rawequal(_scope_owner, owner)
		or not rawequal(package.loaded["ui.error_dialog"], M) or data.generation ~= _scope_generation then return false end
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
