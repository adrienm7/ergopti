--- ui/healthcheck/core.lua

--- ==============================================================================
--- MODULE: Healthcheck Core
--- DESCRIPTION:
--- The version 2 diagnostics snapshot (_shared/modules/diagnostics/schema.json)
--- and the window that shows it. The window loads the shared page
--- (_shared/ui/healthcheck/); the page renders the snapshot, keeps the preview
--- of what is shared and asks for every action by message.
---
--- FEATURES & RATIONALE:
--- 1. One hs.webview.usercontent controller per window, named "healthcheck"
---    as host_bridge.js posts it. The copy button used to be JS injected into
---    the page and a 200 ms timer polling a flag, because WKWebView refuses a
---    custom URL scheme; every other macOS web UI already used a message
---    handler, which needs no timer at all.
--- 2. Every message is validated by healthcheck.actions against the schema's
---    allowlist: the host opens only the paths it collected, by field id.
--- 3. The page asks for the first snapshot with "ready"; the probes start then
---    (ui.healthcheck.probes) and push their answers into that window only.
--- 4. The module contract check stays: a developer section of the page. Its
---    `wired` flag is a build-time fact kept honest by
---    tests/meta/test_adapter_wiring_reachability.lua.
--- ==============================================================================

local M = {}

local hs       = hs
local Logger   = require("infra.logger")
local H        = require("ui.healthcheck.helpers")
local Paths    = require("infra.paths")
local Snapshot = require("healthcheck.snapshot")
local Actions  = require("healthcheck.actions")
local TimerScheduler = require("adapters.timer_scheduler")

local LOG = "healthcheck"

M.DRIVER = "macos"

-- The message handler name host_bridge.js posts to
local BRIDGE = "healthcheck"

-- The default build pin and this reviewed native contract are locked together
-- by the native event-tap contract tests. Hammerspoon 1.1.1 consumes
-- both CoreGraphics disable signals in Objective-C, attempts to re-enable the
-- tap, and returns before the registered Lua callback. The build version can be
-- overridden, so diagnostics must compare the live runtime before claiming that
-- this reviewed behavior applies.
local EVENT_TAP_REVIEWED_VERSION = "1.1.1"

-- Module load timestamp — used to approximate driver uptime.
local _load_time = os.time()

-- The documents of the diagnostics window, loaded once
local _config = nil

-- The menu state the last opening handed over, for the features section
local _menu_state = nil

-- Reference to the currently open webview window (singleton — one at a time),
-- its generation and its page session.
local _window = nil
local _window_generation = 0
local _session = nil
local _continuation_timers = {}
local _closing_window = nil
local _focus_owner = nil

--- Returns an isolated description of the live eventtap telemetry contract.
--- @param runtime_version string|nil Hammerspoon version reported at runtime.
--- @return table Contract status safe to expose in a diagnostic snapshot.
function M.event_tap_telemetry(runtime_version)
	local runtime = type(runtime_version) == "string" and runtime_version ~= ""
		and runtime_version or "unknown"
	local reviewed = runtime == EVENT_TAP_REVIEWED_VERSION
	local summary
	if reviewed then
		summary = string.format(
			"unavailable — reviewed Hammerspoon %s consumes tap-disable signals and attempts native re-enable before Lua callbacks",
			EVENT_TAP_REVIEWED_VERSION)
	else
		summary = string.format(
			"unavailable — unreviewed runtime Hammerspoon %s; native contract reviewed only for %s",
			runtime, EVENT_TAP_REVIEWED_VERSION)
	end
	return {
		available                    = false,
		runtime_hammerspoon_version = runtime,
		reviewed_hammerspoon_version = EVENT_TAP_REVIEWED_VERSION,
		native_contract_reviewed     = reviewed,
		summary                      = summary,
	}
end

--- Stops a page session's probes and releases its message controller.
--- @param session table|nil
local function retire_session(session)
	if not session then return end
	if _session == session then _session = nil end
	if session.probes then
		session.probes.cancel()
		session.probes = nil
	end
	local controller = session.controller
	session.controller = nil
	if controller then
		local ok, result = pcall(function() return controller:setCallback(nil) end)
		if not ok then
			Logger.error(LOG, "The diagnostics message handler could not be released: %s.", tostring(result))
		end
	end
end

--- Cancels every delayed window continuation independently.
--- @return boolean settled True only when all exact handles were released.
local function stop_continuations()
	local snapshot = {}
	for handle in pairs(_continuation_timers) do snapshot[#snapshot + 1] = handle end
	local settled = true
	for _, handle in ipairs(snapshot) do
		local ok, cancelled = xpcall(function()
			return TimerScheduler.cancel(handle)
		end, debug.traceback)
		if ok and cancelled == true then
			_continuation_timers[handle] = nil
		else
			settled = false
			Logger.error(LOG, "Healthcheck continuation cleanup failed; exact handle retained: %s.",
				tostring(ok and cancelled or cancelled))
		end
	end
	return settled
end

--- Deletes the published exact window before invalidating its logical owner.
--- @param webview table Exact published WebView.
--- @param reason string Diagnostic close reason.
--- @return boolean settled True only when the window and its runtime settled.
local function close_owned_window(webview, reason)
	if _window ~= webview then return true end
	_focus_owner = nil
	if type(webview.delete) ~= "function" then
		Logger.error(LOG, "Healthcheck %s refused; owned WebView has no delete method.", reason)
		return false
	end
	_closing_window = webview
	local ok, result = xpcall(function() return webview:delete() end, debug.traceback)
	if _closing_window == webview then _closing_window = nil end
	if not ok or result == false then
		Logger.error(LOG, "Healthcheck %s did not commit; exact WebView retained: %s.",
			reason, tostring(result))
		return false
	end
	if _window == webview then _window = nil end
	_window_generation = _window_generation + 1
	retire_session(_session)
	local continuations_stopped = stop_continuations()
	if not continuations_stopped then
		Logger.error(LOG, "Healthcheck %s retained timer cleanup debt.", reason)
	end
	return continuations_stopped
end

--- Schedules one exact window-generation continuation.
--- @param delay number Delay in seconds.
--- @param generation integer Window generation.
--- @param webview table Exact webview owner.
--- @param callback function Continuation body.
--- @param label string Diagnostic label.
--- @return boolean committed True only when the timer was armed.
local function schedule_continuation(delay, generation, webview, callback, label)
	local handle
	local timer_committed = false
	local ok, candidate, committed = xpcall(function()
		return TimerScheduler.after(delay, function()
			if timer_committed ~= true then return end
			if handle and handle.timer ~= nil then
				-- One-shot delivery is already fenced by TimerScheduler. Retain the
				-- cleanup capability without turning a committed focus action into a no-op.
				Logger.error(LOG, "%s retained timer cleanup debt.", label)
			else
				if handle then _continuation_timers[handle] = nil end
			end
			if generation ~= _window_generation or _window ~= webview then return end
			callback()
		end)
	end, debug.traceback)
	handle = candidate
	if type(handle) == "table" then _continuation_timers[handle] = true end
	if not ok or type(handle) ~= "table" or committed ~= true then
		if type(handle) == "table" then
			local cancel_ok, cancelled = xpcall(function()
				return TimerScheduler.cancel(handle)
			end, debug.traceback)
			if cancel_ok and cancelled == true then _continuation_timers[handle] = nil end
		end
		Logger.error(LOG, "%s timer was not committed: %s.", label,
			tostring(ok and committed or candidate))
		return false
	end
	timer_committed = true
	return true
end





--- ==========================================
--- ==========================================
--- ======= 1/ Adapter & Port Registry =======
--- ==========================================
--- ==========================================

-- Each entry: { id = "require.path", contract = { "method1", "method2", … }, wired = bool }
-- Contract methods are the minimal public surface that must be present for the
-- adapter to be considered operational.
--
-- `wired` records whether at least one non-test, non-healthcheck production file
-- actually calls require() on this adapter (audit F-HIGH-10). A contract-healthy
-- adapter that is NOT wired can load fine and expose every method yet still be
-- completely unreachable from any real feature — the migration onto the port/
-- adapter architecture is incomplete for it. Keeping this flag in lock-step with
-- reality is enforced by tests/meta/test_adapter_wiring_reachability.lua, which
-- greps production sources for a require("adapters.<id>") call site and fails if
-- the flag disagrees with what it finds.
local ADAPTER_SPECS = {
	-- Reachable interfaces only; native execution and consent are checked separately.
	{
		id       = "adapters.apple_shortcuts",
		contract = { "valid_identifier", "validate_reply", "new" },
		wired    = true,
	},
	{
		id       = "adapters.apple_shortcuts_native",
		contract = { "available", "create", "is_chosen_program", "revalidate_program" },
		wired    = true,
	},
	{
		id       = "adapters.system_switcher_sampler",
		contract = { "new" },
		wired    = true,
	},
	{
		id       = "adapters.system_switcher_input",
		contract = { "new" },
		wired    = true,
	},
	{
		id       = "adapters.system_switcher_runtime",
		contract = { "descriptor" },
		wired    = true,
	},
	{
		id       = "adapters.managed_ollama_hint",
		contract = { "get", "cancel" },
		-- Structural dispatch wiring; source and image admission stay independent.
		wired    = true,
	},
	{
		id       = "adapters.native_python_probe",
		contract = { "get", "cancel", "onSettled" },
		wired    = true,
	},
	{
		id       = "adapters.native_bootstrap_pty",
		contract = { "prepare" },
		wired    = true,
	},
	{
		id       = "adapters.physical_shortcut_hook",
		contract = { "new" },
		-- Structural require reachability; runtime native delivery stays unavailable.
		wired    = true,
	},
	{
		id       = "adapters.program_providers",
		contract = { "create" },
		wired    = true,
	},
	{
		id       = "adapters.owned_program_runner",
		contract = { "available", "spawn" },
		wired    = true,
	},
	{
		id       = "adapters.keyboard_source_probe",
		contract = { "current_source_id", "request" },
		wired    = true,
	},
	{
		id       = "adapters.webview_result",
		contract = { "is_error" },
		wired    = true,
	},
	{
		id       = "adapters.accessibility_permission",
		contract = { "is_trusted", "request_prompt" },
		wired    = true,
	},
	{
		id       = "adapters.screen_capture",
		contract = { "permission_state", "request_permission", "open_permission_settings",
			"clipboard_change_count", "clipboard_has_image", "copy_image_file_to_clipboard" },
		wired    = true,
	},
	{
		id       = "adapters.tcc_grant",
		contract = { "bundle_id", "reset" },
		wired    = true,
	},
	{
		id       = "adapters.app_launcher",
		contract = { "launch", "launchWithArgs", "isRunning" },
		wired    = true,
	},
	{
		id       = "adapters.boot_fatal",
		contract = { "report" },
		wired    = true,
	},
	{
		id       = "adapters.clipboard",
		contract = { "read", "write" },
		wired    = true,
	},
	{
		id       = "adapters.boot_journal",
		contract = { "append", "write_now", "set_user_log_ready", "describe_path" },
		wired    = true,
	},
	{
		id       = "adapters.crypto",
		contract = { "sha256" },
		wired    = true,
	},
	{
		id       = "adapters.event_provenance",
		contract = { "classify", "classify_with_fence", "is_owned" },
		wired    = true,
	},
	{
		id       = "adapters.file_system",
		contract = { "read", "write", "exists", "prepare_parent_for_create" },
		wired    = true,
	},
	{
		id       = "adapters.graphics_renderer",
		contract = { "createWindow", "destroyWindow", "drawBitmap", "show", "hide" },
		wired    = true,
	},
	{
		id       = "adapters.system_info",
		contract = { "os_version", "runtime_version", "arch", "monitor_count",
			"main_screen_scale", "keyboard_layout", "elevated", "home" },
		wired    = true,
	},
	{
		id       = "adapters.hotkey_registrar",
		contract = { "bind", "unbind", "setEnabled" },
		wired    = true,
	},
	{
		id       = "adapters.python_interpreter",
		contract = { "resolve", "inspect", "native_arch", "parse_header" },
		wired    = true,
	},
	{
		id       = "adapters.http_client",
		contract = { "get", "post" },
		wired    = true,
	},
	{
		id       = "adapters.json_codec",
		contract = { "encode", "decode" },
		wired    = true,
	},
	{
		id       = "adapters.key_state",
		contract = { "isDown", "isUp" },
		wired    = true,
	},
	{
		id       = "adapters.keyboard_hook",
		contract = { "start", "stop" },
		wired    = true,
	},
	{
		id       = "adapters.log_transport",
		contract = { "start", "enqueue", "drain", "stop", "status" },
		wired    = true,
	},
	{
		id       = "adapters.modifier_injector",
		contract = { "arm", "disarm", "is_armed" },
		wired    = true,
	},
	{
		id       = "adapters.mouse_control",
		contract = { "setPos", "getPos" },
		wired    = true,
	},
	{
		id       = "adapters.network_info",
		contract = { "getSsidHash", "getSignalStrength", "isInternetReachable", "isVpnActive" },
		wired    = true,
	},
	{
		id       = "adapters.application_notifier",
		contract = { "send", "new" },
		wired    = true,
	},
	{
		id       = "adapters.notifier",
		contract = { "send" },
		wired    = true,
	},
	{
		id       = "adapters.input_source_broker",
		contract = { "subscribe", "unsubscribe", "is_subscribed" },
		wired    = true,
	},
	{
		id       = "adapters.process_lifecycle",
		contract = { "start", "stop" },
		wired    = true,
	},
	{
		id       = "adapters.secure_field_detector",
		contract = { "isSecureField", "isSecureApp", "refresh" },
		wired    = true,
	},
	{
		id       = "adapters.one_shot_shift",
		contract = { "new" },
		wired    = true,
	},
	{
		id       = "adapters.shell_runner",
		contract = { "exec", "spawn" },
		wired    = true,
	},
	{
		id       = "adapters.storage",
		contract = { "get", "set" },
		wired    = true,
	},
	{
		id       = "adapters.synthetic_input",
		contract = {
			"begin", "emit_key_stroke", "claim_tag", "claim_physical_fence",
			"current_action_epoch", "register_action_listener", "enter_callback",
			"leave_callback", "keyboard_characters",
		},
		wired    = true,
	},
	{
		id       = "adapters.managed_ollama_pull",
		contract = {
			"handles", "prepare", "prepare_owned", "mark_start_attempted",
			"rollback", "retire", "prepare_cleanup", "finish_cleanup",
		},
		wired    = true,
	},
	{
		id       = "adapters.task_environment",
		contract = { "sanitize" },
		wired    = true,
	},
	{
		id       = "adapters.task_lifecycle",
		contract = { "guard_callback", "create", "native", "start" },
		wired    = true,
	},
	{
		id       = "adapters.text_sender",
		contract = { "send" },
		wired    = true,
	},
	{
		id       = "adapters.timer_scheduler",
		contract = { "after", "every" },
		wired    = true,
	},
	{
		id       = "adapters.toml_cache",
		contract = { "init", "load", "store", "stats" },
		wired    = true,
	},
	{
		id       = "adapters.tooltip_renderer",
		contract = { "show", "hide" },
		wired    = true,
	},
	{
		id       = "adapters.tray_menu",
		contract = { "setIcon", "setMenu", "setTooltip", "destroy" },
		wired    = true,
	},
	{
		id       = "adapters.update_launcher",
		contract = { "request_check" },
		wired    = true,
	},
	{
		id       = "adapters.wake_watcher",
		contract = { "new" },
		wired    = true,
	},
	{
		id       = "adapters.window_info",
		contract = { "getFocused", "getAll" },
		wired    = true,
	},
	{
		id       = "adapters.window_manager",
		contract = { "activate", "exists", "kill", "getList" },
		wired    = true,
	},
}





--- ===============================
--- ===============================
--- ======= 2/ The Snapshot =======
--- ===============================
--- ===============================

--- The schema, the issue forms, the redaction rules and the repository, loaded
--- once: they are files of the shared tree, not settings.
--- @return table { schema, templates, redaction, repository }
function M.config()
	if not _config then _config = Snapshot.load_config(Paths.shared) end
	return _config
end

--- The name of the logger's active level.
--- @return string|nil
local function level_name()
	for name, value in pairs(Logger.LEVELS or {}) do
		if value == Logger.current_level then return name end
	end
	return nil
end

--- The module contract check: every adapter loads and exposes its contract.
--- @return table ok Adapter ids that passed.
--- @return table failed Adapter ids that did not, with the reason.
local function check_modules()
	local ok_list, failed = {}, {}
	for _, spec in ipairs(ADAPTER_SPECS) do
		local loaded, mod = pcall(require, spec.id)
		if not loaded then
			failed[#failed + 1] = spec.id .. " (load failed)"
			Logger.warn(LOG, "Adapter '%s' could not be loaded: %s.", spec.id, tostring(mod))
		else
			local complete = true
			for _, method in ipairs(spec.contract) do
				if type(mod[method]) ~= "function" then
					complete = false
					Logger.warn(LOG, "Adapter '%s' missing contract method '%s'.", spec.id, method)
				end
			end
			if complete then ok_list[#ok_list + 1] = spec.id
			else failed[#failed + 1] = spec.id .. " (contract incomplete)" end
		end
	end
	return ok_list, failed
end

--- The warnings and errors: the logger's session counters, its last error and
--- the newest entries of today's errors file (the ring before it exists).
--- @return table
local function collect_issues()
	local recent, source = {}, "unavailable"
	local ok, err = pcall(function()
		local limits = Snapshot.load_recent_issue_limits(Paths.shared("modules/diagnostics/recent_issues.json"))
		recent, source = Snapshot.collect_recent_issues(Logger.today_errors_path(), Logger.ring_buffer_snapshot() or {},
			limits)
	end)
	if not ok then Logger.error(LOG, "Recent issues could not be collected: %s.", tostring(err)) end
	local issues = Logger.session_issues()
	return {
		warn_count    = issues.warn_count,
		err_count     = issues.err_count,
		last_error    = issues.last_error,
		recent_source = source,
		recent        = recent,
	}
end

--- The developer section: the module check, the log level and the ring.
--- @return table
local function collect_developer()
	local ok_list, failed = check_modules()
	return {
		modules_ok          = ok_list,
		modules_failed      = failed,
		modules_disabled    = {},
		log_level           = level_name(),
		ring_lines          = #(Logger.ring_buffer_snapshot() or {}),
		event_tap_telemetry = M.event_tap_telemetry(require("adapters.system_info").runtime_version()).summary,
	}
end

--- Collects the synchronous (phase A) snapshot: memory, Hammerspoon queries
--- and small files only; the probes fill the rest.
--- @param opts table|nil { detailed = boolean }
--- @return table The version 2 snapshot.
function M.run(opts)
	opts = type(opts) == "table" and opts or {}
	local detailed = opts.detailed == true
	Logger.start(LOG, "Collecting the diagnostics…")
	-- The budget is the collection's: the shared documents load once per
	-- session, before the clock starts
	local schema = M.config().schema
	local started = hs.timer.absoluteTime()
	local permission_ids = {}
	for id in pairs(schema.permissions[M.DRIVER] or {}) do permission_ids[#permission_ids + 1] = id end
	table.sort(permission_ids)

	-- Each collector is isolated: a report exists to be read when things are
	-- broken, so one collector raising costs its own section, never the window
	local function section(name, collector)
		local ok, value = pcall(collector)
		if not ok then
			Logger.error(LOG, "Diagnostics collector '%s' raised: %s — section left empty.", name, tostring(value))
			return {}
		end
		return value
	end

	local sections = {
		paths       = section("paths", function() return H.collect_paths(schema.report.subdir) end),
		versions    = section("versions", H.collect_versions),
		hardware    = section("hardware", H.collect_hardware),
		system      = section("system", function() return H.collect_system(detailed, os.time() - _load_time) end),
		input       = section("input", H.collect_input),
		features    = section("features", function() return H.collect_features(_menu_state) end),
		unavailable = section("platform_coverage", H.collect_unavailable),
		ai          = section("ai", H.collect_ai),
		network     = section("network", H.collect_network),
		permissions = section("permissions", function() return H.collect_permissions(permission_ids) end),
		peripherals = section("peripherals", function() return H.collect_peripherals(detailed) end),
		issues      = section("issues", collect_issues),
		developer   = section("developer", collect_developer),
	}
	local snapshot = {
		schema_version = schema.schema_version,
		driver         = M.DRIVER,
		generated_at   = Snapshot.utc_now(),
		detailed       = detailed,
		sections       = sections,
		probes         = Snapshot.pending_probes(schema, M.DRIVER),
	}

	local elapsed = (hs.timer.absoluteTime() - started) / 1e6
	sections.developer.phase_a_ms = elapsed
	-- Not a warning: the next snapshot would count it among the session's
	-- problems. The report's developer section carries the duration.
	if elapsed > schema.phase_a_budget_ms then
		Logger.info(LOG, "The synchronous diagnostics took %.1f ms, over the %d ms budget.", elapsed,
			schema.phase_a_budget_ms)
	end
	local undeclared = Snapshot.check_fields(snapshot, schema)
	if #undeclared > 0 then
		Logger.error(LOG, "The diagnostics snapshot carries fields the schema does not declare: %s.",
			table.concat(undeclared, ", "))
	end
	Logger.success(LOG, "Diagnostics collected in %.1f ms.", elapsed)
	return snapshot
end





--- =============================
--- =============================
--- ======= 3/ The Window =======
--- =============================
--- =============================

--- Sends a message into the session's page.
--- @param session table
--- @param message table
--- @return boolean submitted
local function send(session, message)
	if _session ~= session or _window ~= session.webview then return false end
	local ok_json, json = pcall(hs.json.encode, message)
	if not ok_json or type(json) ~= "string" then
		Logger.error(LOG, "A diagnostics message could not be encoded: %s.", tostring(json))
		return false
	end
	local WebviewResult = require("adapters.webview_result")
	local ok, err = pcall(function()
		session.webview:evaluateJavaScript("if(window.receiveDiagnostics)window.receiveDiagnostics(" .. json .. ")",
			function(_, script_error)
				if WebviewResult.is_error(script_error) then
					Logger.error(LOG, "The diagnostics page refused a '%s' message.", tostring(message.type))
				end
			end)
	end)
	if not ok then
		Logger.error(LOG, "The diagnostics page could not be reached: %s.", tostring(err))
		return false
	end
	return true
end

--- Starts the probes of the session's snapshot; each answer is kept in the
--- snapshot and pushed into the page.
--- @param session table
local function start_probes(session)
	if session.probes then session.probes.cancel() end
	session.probes = require("ui.healthcheck.probes").start(M.config().schema, session.snapshot,
		function(id, result, sections)
			if _session ~= session then return end
			session.snapshot.probes[id] = result
			for section_id, values in pairs(sections or {}) do
				local target = session.snapshot.sections[section_id]
				for key, value in pairs(values) do target[key] = value end
			end
			send(session, { type = "probe", id = id, result = result, sections = sections })
		end)
end

--- The page's first message: its configuration and the first snapshot.
--- @param session table
--- @return table
local function init_message(session)
	local documents = M.config()
	return {
		type = "init",
		config = {
			schema    = documents.schema,
			redaction = documents.redaction,
			context   = require("ui.healthcheck.report").redaction_context(),
			mode      = session.mode,
		},
		snapshot = session.snapshot,
	}
end

--- Handles one validated action of the session's page.
--- @param session table
--- @param action table From healthcheck.actions.validate.
--- @param documents table M.config().
local function perform_action(session, action, documents)
	if action.action == "close" then
		close_owned_window(session.webview, "page close")
	elseif action.action == "refresh" then
		session.detailed = action.detailed
		session.snapshot = M.run({ detailed = action.detailed })
		send(session, { type = "snapshot", snapshot = session.snapshot })
		start_probes(session)
	else
		local Report = require("ui.healthcheck.report")
		local result = Report.perform(action, session.snapshot.sections.paths, documents, Report.redaction_context())
		result.type = "action"
		result.action = action.action
		send(session, result)
	end
end

--- Handles one message of the session's page.
--- @param session table
--- @param message table The usercontent message ({ body = … }).
local function on_page_message(session, message)
	if _session ~= session or _window ~= session.webview or _closing_window == session.webview then return end
	local body = type(message) == "table" and message.body or nil
	if body == "ready" then
		Logger.info(LOG, "Diagnostics page ready.")
		local ok, err = xpcall(function()
			send(session, init_message(session))
			start_probes(session)
		end, debug.traceback)
		if not ok then Logger.error(LOG, "The diagnostics page could not be initialised: %s", tostring(err)) end
		return
	end
	local documents = M.config()
	local action, reason = Actions.validate(body,
		{ schema = documents.schema, templates = documents.templates, driver = M.DRIVER })
	if not action then
		Logger.warn(LOG, "Refused a diagnostics page action (%s).", tostring(reason))
		return
	end
	Logger.info(LOG, "Diagnostics page action: %s.", action.action)
	-- A message handler that raises is only printed to the console: the error
	-- is logged here and the page is told its button did nothing
	local ok, err = xpcall(perform_action, debug.traceback, session, action, documents)
	if not ok then
		Logger.error(LOG, "The diagnostics action '%s' failed: %s", action.action, tostring(err))
		send(session, { type = "action", action = action.action, ok = false })
	end
end

--- Hands the page the user's locale strings: i18n.js cannot fetch them from
--- an inline page.
--- @param webview table
local function inject_strings(webview)
	local ok_strings, strings = pcall(function() return require("infra.locale").catalogue() end)
	if not ok_strings or type(strings) ~= "table" then
		Logger.error(LOG, "The diagnostics page's strings could not be read: %s.", tostring(strings))
		return
	end
	local ok_json, json = pcall(hs.json.encode, strings)
	if not ok_json then
		Logger.error(LOG, "The diagnostics page's strings could not be encoded: %s.", tostring(json))
		return
	end
	local ok, err = pcall(function()
		webview:evaluateJavaScript("if(window.i18n_apply){window.i18n_apply(" .. json .. ");}")
	end)
	if not ok then Logger.error(LOG, "The diagnostics page's strings were refused: %s.", tostring(err)) end
end

--- Opens the diagnostics window. Replaces any existing window (singleton).
--- @param opts table|nil { mode = "report"|nil, state = menu state|nil }
--- @return boolean opened
function M.show_window(opts)
	opts = type(opts) == "table" and opts or {}
	Logger.start(LOG, "Opening the diagnostics window…")
	if type(opts.state) == "table" then _menu_state = opts.state end

	if _window then
		Logger.debug(LOG, "Closing existing healthcheck window before reopening.")
		if not close_owned_window(_window, "reopen") then return false end
	elseif not stop_continuations() then
		Logger.error(LOG, "Healthcheck startup refused: prior timer cleanup remains pending.")
		return false
	end

	local ok_snap, snapshot = pcall(M.run)
	if not ok_snap or type(snapshot) ~= "table" then
		Logger.error(LOG, "The diagnostics could not be collected: %s.", tostring(snapshot))
		return false
	end

	local i18n = require("infra.i18n")
	local ui_builder = require("ui.ui_builder")
	local title = ui_builder.window_title(i18n.get("menu.debug.healthcheck"))
	local shared_ui_dir = (Paths.shared("ui/healthcheck") or "") .. "/"
	local ok_html, html = pcall(ui_builder.build_injected_html, shared_ui_dir)
	if not ok_html or type(html) ~= "string" then
		Logger.error(LOG, "The diagnostics page could not be built: %s.", tostring(html))
		return false
	end

	-- Geometry comes from _shared/ui/apps.manifest.json, as on every driver
	local geo = ui_builder.get_app_geometry("healthcheck")
	if not geo then
		Logger.error(LOG, "No geometry for 'healthcheck' in apps.manifest.json — cannot open the window.")
		return false
	end
	local ok_scr, screen = pcall(function() return hs.screen.mainScreen() end)
	local sf = (ok_scr and screen and type(screen.frame) == "function" and screen:frame())
		or { x = 0, y = 0, w = 1440, h = 900 }
	local frame = {
		x = math.floor(sf.x + (sf.w - geo.width) / 2),
		y = math.floor(sf.y + (sf.h - geo.height) / 2),
		w = geo.width,
		h = geo.height,
	}

	local ok_ucc, controller = pcall(hs.webview.usercontent.new, BRIDGE)
	if not ok_ucc or not controller then
		Logger.error(LOG, "The diagnostics message handler could not be created: %s.", tostring(controller))
		return false
	end
	local ok_wv, wv = pcall(hs.webview.new, frame, { developerExtrasEnabled = false }, controller)
	if not ok_wv or not wv then
		Logger.error(LOG, "hs.webview.new() failed: %s.", tostring(wv))
		return false
	end
	_window_generation = _window_generation + 1
	local generation = _window_generation
	_window = wv
	local focus_owner = {}
	_focus_owner = focus_owner
	local session = {
		generation = generation,
		webview    = wv,
		controller = controller,
		snapshot   = snapshot,
		detailed   = false,
		mode       = opts.mode,
	}
	_session = session
	local function abandon_open_window(label, detail)
		Logger.error(LOG, "%s: %s.", label, tostring(detail))
		close_owned_window(wv, "open-failure rollback")
		return false
	end

	local ok_cb, cb_err = pcall(function()
		controller:setCallback(function(message) on_page_message(session, message) end)
	end)
	if not ok_cb then return abandon_open_window("The diagnostics message handler was refused", cb_err) end

	-- The same chrome as every other Ergopti window (title bar, drop shadow,
	-- normal level), from the one function that defines it.
	local masks = hs.webview.windowMasks
	for _, step in ipairs(ui_builder.window_chrome_steps(wv, {
		style_masks = (masks["titled"] or 1) + (masks["closable"] or 2) + (masks["miniaturizable"] or 4)
			+ (masks["resizable"] or 8),
	})) do
		local ok_step, step_err = pcall(step.apply)
		if not ok_step then Logger.warn(LOG, "%s() failed: %s.", step.name, tostring(step_err)) end
	end
	pcall(function() wv:windowTitle(title) end)
	pcall(function() wv:allowTextEntry(true) end)
	pcall(function() wv:allowNewWindows(false) end)
	pcall(function() wv:allowGestures(false) end)

	local ok_wcb, wcb_err = pcall(function()
		wv:windowCallback(function(action)
			if generation ~= _window_generation or _window ~= wv then return end
			if _closing_window == wv then return end
			Logger.debug(LOG, "Window callback: action='%s'.", tostring(action))
			if action == "closing" or action == "closed" then
				_window = nil
				_window_generation = _window_generation + 1
				retire_session(session)
				if not stop_continuations() then
					Logger.error(LOG, "Healthcheck close retained timer cleanup debt.")
				end
			end
		end)
	end)
	if not ok_wcb then Logger.warn(LOG, "windowCallback() failed: %s.", tostring(wcb_err)) end

	local ok_ncb, ncb_err = pcall(function()
		wv:navigationCallback(function(action)
			if generation ~= _window_generation or _window ~= wv then return end
			if action == "didFinishNavigation" then inject_strings(wv) end
		end)
	end)
	if not ok_ncb then Logger.warn(LOG, "navigationCallback() failed: %s.", tostring(ncb_err)) end

	local ok_h, h_result = xpcall(function() return wv:html(html) end, debug.traceback)
	if ok_h ~= true or h_result == nil or h_result == false then
		return abandon_open_window("wv:html() failed", h_result)
	end

	local ok_sh, show_result = xpcall(function() return wv:show() end, debug.traceback)
	if ok_sh ~= true or show_result == nil or show_result == false then
		return abandon_open_window("wv:show() failed — window will not appear", show_result)
	end

	-- Raised and focused once, like every window: never given a level that
	-- keeps it above the windows the user opens afterwards.
	ui_builder.force_focus(wv, true, { is_current = function()
		return _focus_owner == focus_owner and _window == wv and _window_generation == generation
	end })

	Logger.success(LOG, "Diagnostics window opened.")
	return true
end

return M
