--- ui/healthcheck/core.lua

--- ==============================================================================
--- MODULE: Healthcheck Core
--- DESCRIPTION:
--- The version 2 diagnostics snapshot (_shared/diagnostics/data/schema.json)
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
---    tests/meta/architecture/test_adapter_wiring_reachability.lua.
--- ==============================================================================

local M = {}

local hs       = hs
local Logger   = require("core.logger.engine.logger")
local H        = require("ui.healthcheck.helpers")
local Paths    = require("core.fs.engine.paths")
local Snapshot = require("diagnostics.engine.healthcheck.snapshot")
local Cleanup = require("diagnostics.engine.healthcheck.cleanup")
local Actions  = require("diagnostics.engine.healthcheck.actions")
local TimerScheduler = require("core.events.timer_scheduler")
local DeferredWork = require("core.timing.engine.deferred_work")
local TableUtil = require("core.text.engine.table_util")
local NativeClose = require("core.ui.ui.webview_close_owner").new(DeferredWork, Logger)

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

-- The last synchronous collection: its duration, budget and collector costs
local _last_phase_a = nil

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
local _open_revision = 0

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

--- Invalidates action ownership before native cancellation can reenter the bridge.
--- @param session table Exact retained page session.
local function cancel_action(session)
	session.action_epoch = (session.action_epoch or 0) + 1
	local epoch = session.action_epoch
	local previous = session.action_request
	session.action_request = nil
	if previous then previous.cancel() end
	return epoch
end

--- Stops a page session's probes and releases its message controller.
--- @param session table|nil
local function retire_session(session)
	if not session then return end
	if _session == session then _session = nil end
	cancel_action(session)
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
local function continuation_snapshot()
	local snapshot = {}
	for handle in pairs(_continuation_timers) do snapshot[#snapshot + 1] = handle end
	return snapshot
end

local function stop_continuations(snapshot)
	snapshot = snapshot or continuation_snapshot()
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
	if _closing_window ~= nil then return false end
	local session, generation = _session, _window_generation
	local consumed = session and session.native_delete_metatable ~= nil and getmetatable(webview) == nil
	if session and session.native_delete_pending and not consumed then return false end
	local continuations = continuation_snapshot()
	_focus_owner = nil
	if not consumed then
		local delete = webview.delete
		if type(delete) ~= "function" then
			Logger.error(LOG, "Healthcheck %s refused; owned WebView has no delete method.", reason)
			return false
		end
		_closing_window = webview
		session.native_delete_metatable = getmetatable(webview)
		session.native_delete_pending = session.presentation_attempted == true
		local ok, result = xpcall(function() return delete(webview) end, debug.traceback)
		consumed = session.native_delete_metatable ~= nil and getmetatable(webview) == nil
		if not consumed and (not ok or result == false) then
			pcall(Logger.error, LOG, "Healthcheck %s did not commit; exact WebView retained: %s.", reason, tostring(result))
			if _closing_window == webview then _closing_window = nil end
			return false
		end
		if _closing_window == webview then _closing_window = nil end
	end
	if _window == webview then _window = nil end
	if _window_generation == generation then _window_generation = generation + 1 end
	retire_session(session)
	local continuations_stopped = stop_continuations(continuations)
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
-- reality is enforced by tests/meta/architecture/test_adapter_wiring_reachability.lua, which
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
		contract = { "available", "create", "is_chosen_program", "revalidate_program", "cli_identity" },
		wired    = true,
	},
	{
		id       = "adapters.apple_shortcuts_cli",
		contract = { "parse_list", "reply", "observed_rows", "bounded_list_command", "list_blocking", "ports" },
		-- The run_apple_shortcut action and its editor list and run through it.
		wired    = true,
	},
	{
		id       = "adapters.field_check_ports",
		contract = { "new" },
		-- The Debug menu's field checks build their ports on click.
		wired    = true,
	},
	{
		id       = "adapters.field_probe_ports",
		contract = { "new" },
		-- Merged into the field check ports; only the field run's probes read it.
		wired    = true,
	},
	{
		id       = "adapters.field_run_ports",
		contract = { "new" },
		-- Built by infra/field_run.lua, which starts only in developer source mode.
		wired    = true,
	},
	{
		id       = "adapters.runtime_owner_ports",
		contract = { "new", "unpinned_count" },
		-- Required by the remap bridge on an owned boot, the default unless `runtime = "shared"`.
		wired    = true,
	},
	{
		id       = "adapters.runtime_capture_port",
		contract = { "new" },
		-- Built by the owned runtime ports; dormant at default boot.
		wired    = true,
	},
	{
		id       = "adapters.installed_physical_source",
		contract = { "new", "module_path" },
		-- Built by the owned runtime's capture port and the owned runtime field check.
		wired    = true,
	},
	{
		id       = "adapters.karabiner_coexistence",
		contract = { "new" },
		-- Built by the owned runtime ports and the field check; acts only when consented.
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
		id       = "adapters.physical_history_context",
		contract = { "new" },
		-- Explicit retained history uses this factory; loading never enables capture.
		wired    = true,
	},
	{
		id       = "adapters.physical_lifecycle_event",
		contract = { "classify" },
		wired    = true,
	},
	{
		id       = "adapters.physical_context_probe",
		contract = { "snapshot" },
		-- Reached by the explicit fenced sampler; loading performs no native read.
		wired    = true,
	},
	{
		id       = "adapters.physical_observation_clock",
		contract = { "now" },
		-- Reached by explicit configuration binding; loading never samples time.
		wired    = true,
	},
	{
		id       = "platform.system.power_source",
		contract = { "on_battery" },
		-- Read by the keystats aggregate recovery, which paces its slices by it.
		wired    = true,
	},
	{
		id       = "adapters.managed_ollama_hint",
		contract = { "get", "cancel" },
		-- Structural dispatch wiring; source and image admission stay independent.
		wired    = true,
	},
	{
		id       = "adapters.managed_ollama_bootstrap",
		contract = { "prepare" },
		wired    = true,
	},
	{
		id       = "adapters.managed_ollama_daemon",
		contract = { "new", "prepare" },
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
		id       = "adapters.prediction_tooltip_port",
		contract = { "wrap" },
		wired    = true,
	},
	{
		id       = "core.process.adapters.program_providers",
		contract = { "create" },
		wired    = true,
	},
	{
		id       = "core.process.adapters.owned_program_runner",
		contract = { "available", "spawn" },
		wired    = true,
	},
	{
		id       = "adapters.keyboard_source_probe",
		contract = { "current_source_id", "request" },
		wired    = true,
	},
	{
		id       = "adapters.input_source_selector",
		contract = { "command", "command_named", "upgrade" },
		wired    = true,
	},
	{
		id       = "core.ui.adapters.webview_result",
		contract = { "is_error" },
		wired    = true,
	},
	{
		id       = "adapters.accessibility_permission",
		contract = { "is_trusted", "request_prompt" },
		wired    = true,
	},
	{
		id       = "adapters.accessibility_copies",
		contract = { "parse", "find" },
		-- The Accessibility wait asks it for the other copies before any reset.
		wired    = true,
	},
	{
		id       = "platform.system.screen_capture",
		contract = { "permission_state", "request_permission", "open_permission_settings",
			"clipboard_change_count", "clipboard_has_image", "copy_image_file_to_clipboard" },
		wired    = true,
	},
	{
		id       = "adapters.privacy_settings",
		contract = { "url", "url_for", "os_major" },
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
		id       = "platform.focus.running_application",
		contract = { "by_name", "by_bundle_id", "current" },
		-- Every application lookup goes through it; none scans windows.
		wired    = true,
	},
	{
		id       = "core.ui.adapters.own_window",
		contract = { "webview_window_number", "for_webview", "console", "is_webview_focused" },
		-- Every webview and console window lookup; none scans other applications.
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
		id       = "core.logger.adapters.boot_journal",
		contract = { "append", "write_now", "set_user_log_ready", "describe_path" },
		wired    = true,
	},
	{
		id       = "adapters.reload_breadcrumb",
		contract = { "record", "record_boot", "path" },
		wired    = true,
	},
	{
		id       = "adapters.keyboard_layout_files",
		contract = { "write_new", "remove" },
		wired    = true,
	},
	{
		id       = "core.crypto.crypto",
		contract = { "sha256" },
		wired    = true,
	},
	{
		id       = "adapters.event_provenance",
		contract = { "classify", "classify_with_fence", "is_owned" },
		wired    = true,
	},
	{
		id       = "core.events.clock",
		contract = { "lateness_ms", "duration_ms" },
		-- The keymap taps and the physical fence read every key event's lateness.
		wired    = true,
	},
	{
		id       = "platform.input.keyboard_geometry",
		contract = { "initialize", "event_type", "form", "native_code", "physical_code" },
		wired    = true,
	},
	{
		id       = "core.fs.adapters.file_system",
		contract = { "read", "write", "exists", "prepare_parent_for_create" },
		wired    = true,
	},
	{
		id       = "adapters.foreign_ledger_snapshot",
		contract = { "open", "advance", "start", "poll", "close" },
		-- Metrics foreign sync verifies source receipts before admitting SQL batches.
		wired    = true,
	},
	{
		id       = "core.fs.adapters.ledger_append",
		contract = { "cleanup", "recover", "flush" },
		wired    = true,
	},
	{
		id       = "core.fs.adapters.write_lock_path",
		contract = { "for_canonical" },
		-- Every cooperative publication and removal of adapters.file_system.
		wired    = true,
	},
	{
		id       = "core.fs.adapters.legacy_folder_migration",
		contract = { "native_ports", "plan", "rewrites", "run" },
		-- init.lua moves the old folders once at boot, before paths.toml is read.
		wired    = true,
	},
	{
		id       = "adapters.metadata_command_stats",
		contract = { "clock", "record", "snapshot" },
		-- Slow ingest and slow preferences save reports count the metadata forks.
		wired    = true,
	},
	{
		id       = "core.ui.adapters.graphics_renderer",
		contract = { "createWindow", "destroyWindow", "drawBitmap", "show", "hide" },
		wired    = true,
	},
	{
		id       = "platform.system.info",
		contract = { "os_version", "runtime_version", "arch", "monitor_count",
			"main_screen_scale", "keyboard_layout", "elevated", "home" },
		wired    = true,
	},
	{
		id       = "platform.input.hotkey_registrar",
		contract = { "bind", "unbind", "setEnabled" },
		wired    = true,
	},
	{
		id       = "adapters.python_interpreter",
		contract = { "resolve", "inspect", "native_arch", "parse_header" },
		wired    = true,
	},
	{
		id       = "core.network.adapters.http_client",
		contract = { "get", "post" },
		wired    = true,
	},
	{
		id       = "core.fs.adapters.json_codec",
		contract = { "encode", "decode" },
		wired    = true,
	},
	{
		id       = "platform.input.key_state",
		contract = { "isDown", "isUp" },
		wired    = true,
	},
	{
		id       = "platform.input.keyboard_hook",
		contract = { "start", "stop" },
		wired    = true,
	},
	{
		id       = "core.logger.adapters.log_transport",
		contract = { "start", "enqueue", "drain", "stop", "status" },
		wired    = true,
	},
	{
		id       = "platform.input.modifier_injector",
		contract = { "arm", "disarm", "is_armed" },
		wired    = true,
	},
	{
		id       = "adapters.mouse_control",
		contract = { "setPos", "getPos" },
		wired    = true,
	},
	{
		id       = "core.network.adapters.info",
		contract = { "getSsidHash", "getSignalStrength", "isInternetReachable", "isVpnActive" },
		wired    = true,
	},
	{
		id       = "platform.focus.application_notifier",
		contract = { "send", "new" },
		wired    = true,
	},
	{
		id       = "platform.system.notifier",
		contract = { "send" },
		wired    = true,
	},
	{
		id       = "adapters.input_source_broker",
		contract = { "subscribe", "unsubscribe", "is_subscribed" },
		wired    = true,
	},
	{
		id       = "core.process.adapters.lifecycle",
		contract = { "start", "stop" },
		wired    = true,
	},
	{
		id       = "platform.focus.secure_field_detector",
		contract = { "isSecureField", "isSecureApp", "refresh" },
		wired    = true,
	},
	{
		id       = "adapters.one_shot_shift",
		contract = { "new" },
		wired    = true,
	},
	{
		id       = "core.process.adapters.shell_runner",
		contract = { "exec", "spawn" },
		wired    = true,
	},
	{
		id       = "core.fs.adapters.storage",
		contract = { "get", "set" },
		wired    = true,
	},
	{
		id       = "platform.input.synthetic_input",
		contract = {
			"begin", "emit_key_stroke", "claim_tag", "claim_physical_fence",
			"current_action_epoch", "register_action_listener", "enter_callback",
			"leave_callback", "keyboard_characters",
		},
		wired    = true,
	},
	{
		id       = "platform.input.synthetic_input_loopback_owner",
		contract = { "new" },
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
		id       = "core.network.adapters.system_curl",
		contract = { "check", "message_for", "parse_version", "verdict_for" },
		-- Every curl start goes through ShellRunner.spawn or TaskLifecycle.native.
		wired    = true,
	},
	{
		id       = "core.process.adapters.task_environment",
		contract = { "sanitize" },
		wired    = true,
	},
	{
		id       = "core.process.adapters.task_lifecycle",
		contract = { "guard_callback", "create", "native", "start" },
		wired    = true,
	},
	{
		id       = "core.process.adapters.task_output_turn",
		contract = { "request" },
		-- The Karabiner lease ACK deadlines prove a task output turn before failing.
		wired    = true,
	},
	{
		id       = "platform.input.text_sender",
		contract = { "send" },
		wired    = true,
	},
	{
		id       = "core.events.timer_scheduler",
		contract = { "after", "every" },
		wired    = true,
	},
	{
		id       = "core.fs.adapters.toml_cache",
		contract = { "init", "load", "store", "stats" },
		wired    = true,
	},
	{
		id       = "core.ui.adapters.tooltip_renderer",
		contract = { "show", "hide" },
		wired    = true,
	},
	{
		id       = "tray.adapters.menu",
		contract = { "setIcon", "setMenu", "setTooltip", "destroy" },
		wired    = true,
	},
	{
		id       = "adapters.unicode_carrier",
		contract = { "note_physical_key", "keycode" },
		-- The keymap taps report held keys; every synthetic text event asks it.
		wired    = true,
	},
	{
		id       = "adapters.update_launcher",
		contract = { "request_check" },
		wired    = true,
	},
	{
		id       = "core.events.wake_watcher",
		contract = { "new" },
		wired    = true,
	},
	{
		id       = "platform.focus.window_info",
		contract = { "getFocused", "getAll" },
		wired    = true,
	},
	{
		id       = "platform.focus.window_manager",
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

--- One adapter of the module contract check: it loads and exposes its contract.
--- @param spec table One ADAPTER_SPECS entry.
--- @param ok_list table Receives the id when it passed.
--- @param failed table Receives the id and the reason when it did not.
local function check_adapter(spec, ok_list, failed)
	local loaded, mod = pcall(require, spec.id)
	if not loaded then
		failed[#failed + 1] = spec.id .. " (load failed)"
		Logger.warn(LOG, "Adapter '%s' could not be loaded: %s.", spec.id, tostring(mod))
		return
	end
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

--- The facts phase A leaves to the local_state probe, as ordered steps: the
--- Wi-Fi signal (hs.wifi.interfaceDetails, about 50 ms of CoreWLAN queries on
--- the Mac) and one module contract check per adapter (requiring an adapter
--- not loaded yet compiles it: 30 to 65 ms in all). Together they held the
--- synchronous diagnostics at 90 to 150 ms against its 5 ms budget
--- (field report 2026-10-31); as steps, the probe runs them in slices that
--- each fit that budget, between run-loop turns.
--- The versions, the keyboard state and the USB devices come first: 5.9, 5.2
--- and 7.2 ms of the 21.5 ms phase A still took (field report 2026-11-03).
--- @param snapshot table|nil The phase A snapshot: whether details are
---   included, and the peripherals the bluetooth probe may already have added.
--- @return table steps Functions run in order, each a bounded main-thread read.
--- @return table sections { versions, input, peripherals = { items },
---   network = { wifi_signal }, developer = { modules_ok, modules_failed } }
function M.local_state_steps(snapshot)
	local detailed = type(snapshot) == "table" and snapshot.detailed == true
	local ok_list, failed = {}, {}
	local sections = {
		versions    = {},
		input       = {},
		peripherals = {},
		network     = {},
		permissions = { items = {} },
		developer   = { modules_ok = ok_list, modules_failed = failed },
	}
	local function fill(target, values)
		for key, value in pairs(values) do target[key] = value end
	end
	local steps = {
		function() fill(sections.versions, H.collect_versions()) end,
		function() fill(sections.input, H.collect_input()) end,
		function()
			local items = H.collect_peripherals(detailed).items
			-- The bluetooth probe may have answered first; its devices stay listed
			local current = type(snapshot) == "table" and type(snapshot.sections) == "table"
				and snapshot.sections.peripherals and snapshot.sections.peripherals.items or {}
			for _, item in ipairs(current) do
				if item.bus == "bluetooth" then items[#items + 1] = item end
			end
			sections.peripherals.items = items
		end,
		function() sections.network.wifi_signal = H.collect_network().wifi_signal end,
	}
	-- One permission per step: each TCC query is its own slice, so the run loop
	-- turns between them; read live every time, never a remembered grant
	local permission_ids = TableUtil.sorted_keys(M.config().schema.permissions[M.DRIVER] or {})
	for index, id in ipairs(permission_ids) do
		steps[#steps + 1] = function() sections.permissions.items[index] = H.read_permission(id) end
	end
	for _, spec in ipairs(ADAPTER_SPECS) do
		steps[#steps + 1] = function() check_adapter(spec, ok_list, failed) end
	end
	return steps, sections
end

--- Runs the local_state steps at once, for a report collected without a page
--- (Debug > Report a bug, the field run): after phase A was measured, like
--- its configuration.
--- @param snapshot table The phase A snapshot, completed in place.
local function complete_local_state(snapshot)
	local started = hs.timer.absoluteTime()
	local steps, sections = M.local_state_steps(snapshot)
	local failures = {}
	for index, step in ipairs(steps) do
		local ok, err = pcall(step)
		if not ok then
			failures[#failures + 1] = tostring(err):match("^[^\n]*")
			Logger.error(LOG, "Local state step %d raised: %s.", index, tostring(err))
		end
	end
	for id, values in pairs(sections) do
		for key, value in pairs(values) do snapshot.sections[id][key] = value end
	end
	snapshot.probes.local_state = {
		state   = #failures == 0 and "ok" or "error",
		cleanup = "settled",
		ms      = math.floor((hs.timer.absoluteTime() - started) / 1e6 + 0.5),
	}
end

--- The warnings and errors: the logger's session counters, its last error and
--- the newest entries of today's errors file (the ring before it exists).
--- @return table
local function collect_issues()
	local recent, source = {}, "unavailable"
	local ok, err = pcall(function()
		local limits = Snapshot.load_recent_issue_limits(Paths.shared("diagnostics/data/recent_issues.json"))
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

--- The developer section: the log level and the ring; the module check is the
--- local_state probe's.
--- @return table
local function collect_developer()
	return {
		modules_disabled    = {},
		log_level           = level_name(),
		ring_lines          = #(Logger.ring_buffer_snapshot() or {}),
		event_tap_telemetry = M.event_tap_telemetry(require("platform.system.info").runtime_version()).summary,
	}
end

--- The last synchronous collection's duration, its budget and each collector's
--- cost, for the field run, which reports them without a person reading the log.
--- @return table|nil { ms, budget_ms, collectors = { { name, ms } } }, nil before any.
function M.last_phase_a()
	if _last_phase_a == nil then return nil end
	local collectors = {}
	for index, entry in ipairs(_last_phase_a.collectors) do
		collectors[index] = { name = entry.name, ms = entry.ms }
	end
	return { ms = _last_phase_a.ms, budget_ms = _last_phase_a.budget_ms, collectors = collectors }
end

--- Collects the synchronous (phase A) snapshot: memory, Hammerspoon queries
--- and small files only; the probes fill the rest.
--- @param opts table|nil { detailed = boolean, extensive = boolean, state = menu state|nil }
--- @return table The version 2 snapshot.
function M.run(opts)
	opts = type(opts) == "table" and opts or {}
	local detailed = opts.detailed == true
	local extensive = opts.extensive == true
	-- Debug > Report a bug collects without the window, so it hands the menu
	-- state here rather than to show_window
	if type(opts.state) == "table" then _menu_state = opts.state end
	Logger.start(LOG, "Collecting the diagnostics…")
	-- The budget is the collection's: the shared documents load once per
	-- session, before the clock starts
	local schema = M.config().schema
	local started = hs.timer.absoluteTime()

	-- Each collector is isolated: a report exists to be read when things are
	-- broken, so one collector raising costs its own section, never the window
	local timings = {}
	local function section(name, collector)
		local section_started = hs.timer.absoluteTime()
		local ok, value = pcall(collector)
		timings[#timings + 1] = { name = name, ms = (hs.timer.absoluteTime() - section_started) / 1e6 }
		if not ok then
			Logger.error(LOG, "Diagnostics collector '%s' raised: %s — section left empty.", name, tostring(value))
			return {}
		end
		return value
	end

	local sections = {
		paths       = section("paths", function() return H.collect_paths(schema.report.subdir) end),
		-- The versions, the keyboard state and the USB devices are the
		-- local_state probe's: together they held phase A 18 of its 21.5 ms
		versions    = {},
		hardware    = section("hardware", H.collect_hardware),
		system      = section("system", function() return H.collect_system(detailed, os.time() - _load_time) end),
		input       = {},
		features    = section("features", function() return H.collect_features(_menu_state) end),
		-- Filled by the configuration probe: reading and decoding the files is far
		-- over the phase A budget
		configuration_files = { items = {} },
		configuration = { items = {} },
		unavailable = section("platform_coverage", H.collect_unavailable),
		ai          = section("ai", H.collect_ai),
		-- Filled by the local_state probe with the developer section's module check
		network     = {},
		-- Filled by the local_state probe: the Accessibility and Screen
		-- Recording queries are TCC calls, 9.2 ms of phase A's 10.2 ms
		permissions = { items = {} },
		peripherals = { items = {} },
		issues      = section("issues", collect_issues),
		developer   = section("developer", collect_developer),
	}
	local snapshot = {
		schema_version = schema.schema_version,
		driver         = M.DRIVER,
		generated_at   = Snapshot.utc_now(),
		detailed       = detailed,
		extensive      = extensive,
		sections       = sections,
		probes         = Snapshot.pending_probes(schema, M.DRIVER, extensive),
	}

	local elapsed = (hs.timer.absoluteTime() - started) / 1e6
	sections.developer.phase_a_ms = elapsed
	_last_phase_a = { ms = elapsed, budget_ms = schema.phase_a_budget_ms, collectors = timings }
	-- Not a warning: the next snapshot would count it among the session's
	-- problems. The report's developer section carries the duration.
	if elapsed > schema.phase_a_budget_ms then
		Logger.info(LOG, "The synchronous diagnostics took %.1f ms, over the %d ms budget%s.", elapsed,
			schema.phase_a_budget_ms, Snapshot.slowest_collectors(timings, schema.phase_a_slowest_named))
	end
	local undeclared = Snapshot.check_fields(snapshot, schema)
	if #undeclared > 0 then
		Logger.error(LOG, "The diagnostics snapshot carries fields the schema does not declare: %s.",
			table.concat(undeclared, ", "))
	end
	Logger.success(LOG, "Diagnostics collected in %.1f ms.", elapsed)
	-- A report from the Debug menu has no page to keep responsive: its
	-- configuration is collected now, after phase A was measured
	if opts.complete_local == true then
		local err = require("diagnostics.engine.healthcheck.configuration").complete(snapshot,
			H.configuration_context(schema, opts.configuration))
		if err then Logger.error(LOG, "The configuration could not be collected: %s.", err) end
		complete_local_state(snapshot)
	end
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
	local WebviewResult = require("core.ui.adapters.webview_result")
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
	Cleanup.archive(session)
	Cleanup.refresh(session)
	local captured = session.snapshot
	-- Without the extensive opt-in only the local probes run (the configuration)
	session.probes = require("ui.healthcheck.probes").start(M.config().schema, session.snapshot,
		function(id, result, sections)
			if _session ~= session or session.snapshot ~= captured then return end
			session.snapshot.probes[id] = result
			for section_id, values in pairs(sections or {}) do
				local target = session.snapshot.sections[section_id]
				for key, value in pairs(values) do target[key] = value end
			end
			send(session, { type = "probe", id = id, result = result, sections = sections })
		end, { local_only = session.snapshot.extensive ~= true })
end

--- The page's first message: its configuration and the first snapshot.
--- @param session table
--- @return table
local function init_message(session)
	local documents = M.config()
	session.snapshot.export_revision = session.snapshot.export_revision or 1
	return {
		type = "init",
		config = {
			schema    = documents.schema,
			redaction = documents.redaction,
			context   = require("ui.healthcheck.report").redaction_context(),
			-- The guided diagnostic collection is a Windows host action only.
			capabilities = { diagnostic_collection = false },
		},
		snapshot = session.snapshot,
	}
end

--- Handles one validated action of the session's page.
--- @param session table
--- @param action table From healthcheck.actions.validate.
--- @param documents table M.config().
local function perform_action(session, action, documents)
	local epoch = cancel_action(session)
	if _session ~= session or _window ~= session.webview then return end
	Cleanup.refresh(session)
	if _session ~= session or _window ~= session.webview or session.action_epoch ~= epoch then return end
	if action.action == "export_snapshot" then
		if not require("diagnostics.engine.healthcheck.share").capture_page_checks(session.snapshot, action) then
			send(session, { type = "action", action = "export_snapshot", ok = false, export_sequence = action.export_sequence })
			return
		end
		send(session, { type = "action", action = "export_snapshot", ok = true,
			export_sequence = action.export_sequence, snapshot = session.snapshot,
			share_text = require("diagnostics.engine.healthcheck.share").document(session.snapshot, documents.schema,
				require("core.i18n.engine.i18n").get(documents.schema.share_policy.notice_key), action.day_log == true).text })
	elseif action.action == "day_log" then
		-- Opt-in: ticking collects and redacts today's log; unticking drops it
		local DayLogHost = require("diagnostics.engine.healthcheck.day_log")
		if not action.enabled then
			DayLogHost.discard(session.snapshot)
			send(session, { type = "action", action = "day_log", ok = true, state = "off" })
			return
		end
		Logger.start(LOG, "Collecting today's log for the report…")
		Logger.flush_repeats(true)
		local reply = DayLogHost.prepare(session.snapshot, documents, require("ui.healthcheck.report").redaction_context(),
			function(cap) return DayLogHost.read_file(Logger.today_log_path(), cap) end)
		if reply.state == "ready" then
			Logger.success(LOG, "Today's log is ready: %d lines, %d bytes.", reply.lines, reply.bytes)
		else
			Logger.warn(LOG, "Today's log is not attachable: %s.", tostring(reply.state))
		end
		send(session, reply)
	elseif action.action == "close" then
		close_owned_window(session.webview, "page close")
	elseif action.action == "cancel" then
		Cleanup.cancel(session)
		send(session, { type = "action", action = "cancel", ok = true, snapshot = session.snapshot })
	elseif action.action == "refresh" then
		Cleanup.archive(session)
		session.detailed = action.detailed
		local revision = (session.snapshot.export_revision or 1) + 1
		session.snapshot = M.run({ detailed = action.detailed, extensive = action.extensive })
		session.snapshot.export_revision = revision
		Cleanup.refresh(session)
		send(session, { type = "snapshot", snapshot = session.snapshot })
		start_probes(session)
	else
		local Report = require("ui.healthcheck.report")
		local snapshot = session.snapshot
		local revision, generation = snapshot.export_revision, session.generation
		local function current()
			return package.loaded["ui.healthcheck.core"] == M and _session == session and _window == session.webview and _closing_window ~= session.webview and not session.native_delete_pending
				and session.action_epoch == epoch and session.snapshot == snapshot
				and snapshot.export_revision == revision and session.generation == generation
		end
		local completed = false
		local request = Report.perform(action, snapshot.sections.paths, documents, Report.redaction_context(), nil, snapshot, {
			current = current,
			complete = function(result)
				if not current() then return end
				completed = true
				session.action_request = nil
				result.type, result.action = "action", action.action
				send(session, result)
			end,
		})
		if current() and not completed then session.action_request = request else request.cancel() end
	end
end

--- Handles one message of the session's page.
--- @param session table
--- @param message table The usercontent message ({ body = … }).
local function on_page_message(session, message)
	if _session ~= session or _window ~= session.webview or _closing_window == session.webview or session.native_delete_pending then return end
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
	local ok_strings, strings = pcall(function() return require("core.i18n.engine.locale").catalogue() end)
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

--- The open window, for ui/window_toggle (nil when closed).
--- @return userdata|nil view
function M.window() return _window end

--- Closes the open diagnostics window, for ui/window_toggle.
--- @return boolean committed
function M.close_window()
	if _window == nil then return true end
	return close_owned_window(_window, "toggle close")
end

--- Opens the diagnostics window. Replaces any existing window (singleton).
--- @param opts table|nil { state = menu state|nil }
--- @return boolean opened
function M.show_window(opts)
	if NativeClose.retry_cleanup() ~= true then return false end
	_open_revision = _open_revision + 1
	local revision = _open_revision
	opts = type(opts) == "table" and opts or {}
	Logger.start(LOG, "Opening the diagnostics window…")
	if revision ~= _open_revision or package.loaded["ui.healthcheck.core"] ~= M then return false end
	if type(opts.state) == "table" then _menu_state = opts.state end

	if _window then
		Logger.debug(LOG, "Closing existing healthcheck window before reopening.")
		if not close_owned_window(_window, "reopen") then return false end
	elseif not stop_continuations() then
		Logger.error(LOG, "Healthcheck startup refused: prior timer cleanup remains pending.")
		return false
	end

	if revision ~= _open_revision or package.loaded["ui.healthcheck.core"] ~= M then return false end
	local ok_snap, snapshot = pcall(M.run)
	if not ok_snap or type(snapshot) ~= "table" then
		Logger.error(LOG, "The diagnostics could not be collected: %s.", tostring(snapshot))
		return false
	end

	local i18n = require("core.i18n.engine.i18n")
	local ui_builder = require("core.ui.ui.builder")
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
	}
	_session = session
	local function abandon_open_window(label, detail)
		Logger.error(LOG, "%s: %s.", label, tostring(detail))
		close_owned_window(wv, "open-failure rollback")
		return false
	end

	local policy_ok, policy_error = xpcall(function()
		NativeClose.disarm(wv)
		assert(wv:allowNewWindows(false) == wv, "native child-window policy was not acknowledged")
		assert(wv:allowNewWindows() == false, "native child windows remain enabled")
	end, debug.traceback)
	if not policy_ok then return abandon_open_window("The diagnostics native window policy was refused", policy_error) end

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
	pcall(function() wv:allowGestures(false) end)

	local ok_wcb, wcb_err = pcall(function()
		NativeClose.bind(wv, function()
			if generation ~= _window_generation or _window ~= wv then return end
			if _closing_window == wv then return end
			local continuations = continuation_snapshot()
			_window = nil
			_window_generation = _window_generation + 1
			retire_session(session)
			if not stop_continuations(continuations) then
				Logger.error(LOG, "Healthcheck close retained timer cleanup debt.")
			end
			Logger.debug(LOG, "Window closing callback received.")
		end)
	end)
	if not ok_wcb then return abandon_open_window("The diagnostics close owner was refused", wcb_err) end

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

	-- Before this boundary no native show can have created a fade owner.
	-- Mark first: show itself may mutate and then raise.
	session.presentation_attempted = true
	local ok_sh, show_result = xpcall(function() return wv:show() end, debug.traceback)
	if ok_sh ~= true or show_result == nil or show_result == false then
		return abandon_open_window("wv:show() failed — window will not appear", show_result)
	end

	-- Raised and focused once, like every window: never given a level that
	-- keeps it above the windows the user opens afterwards.
	local focus_ok, focused = xpcall(function()
		return ui_builder.force_focus(wv, true, { is_current = function()
			return _focus_owner == focus_owner and _window == wv and _window_generation == generation
		end })
	end, debug.traceback)
	if not focus_ok or focused ~= true then
		Logger.error(LOG, "Diagnostics window presentation was refused; the current report remains open.")
		return false
	end

	Logger.success(LOG, "Diagnostics window opened.")
	return true
end

return M
