--- tests/support/modules/keylogger/context_tracker/foreground_refusal_fixture.lua

--- Drives the real engine, context tracker, pause transaction and synthetic sink.
local helpers = require("tests.helpers")
local ProvenanceFixture = require("tests.support.keylogger_provenance_fixture")
local M = {}
local OWNERS = {
	"keylogger.physical_lifecycle_observation",
	"adapters.physical_observation_clock",
	"hs",
	"tests.stubs.hs",
	"infra.logger",
	"infra.manifest_reader",
	"infra.config_paths",
	"infra.dialog_util",
	"infra.teardown_transaction",
	"modules.keylogger.init",
	"modules.keylogger.log_manager",
	"modules.keylogger.context_tracker",
	"modules.keylogger.kc_bridge",
	"modules.keylogger.watchers",
	"modules.keylogger.timestamp",
	"modules.keylogger.physical_accounting_mode",
	"adapters.synthetic_input",
	"adapters.event_provenance",
	"adapters.process_lifecycle",
	"adapters.keyboard_hook",
	"adapters.input_source_broker",
	"adapters.storage",
	"adapters.timer_scheduler",
	"modules.keylogger.aggregator.events",
	"modules.keylogger.aggregator.state",
	"modules.keylogger.aggregator.core",
	"modules.keylogger.aggregator.physical",
	"ui.metrics_typing.init",
	"modules.keylogger",
	"modules.keylogger.privacy_context",
	"adapters.secure_field_detector",
	"keylogger.private_window",
	"keylogger.metrics",
	"keylogger.physical_context_observation",
	"keylogger.physical_configuration_observation",
	"keylogger.physical_subscription_lifetime",
	"modules.shortcuts.script_control",
	"infra.notifications",
	"modules.gestures.engine",
	"modules.gestures.actions",
	"adapters.key_state",
	"infra.script_chord_catalogue",
	"script_chords",
	"modules.llm.api_mlx",
	"modules.llm.api_ollama",
	"modules.llm.api_remote",
	"modules.llm.warmup_controller",
	"ui.wpm.wpm_menubar",
	"ui.wpm.wpm_widget",
	"platform.remap.onboarding",
	"ui.tooltip",
	"infra.toml.reader",
	"toml_codec.reader",
	"toml_codec.bom",
	"toml_codec.basic_string",
	"toml_codec.key_path",
	"toml_codec.record_scanner",
	"logger.shim",
	"keycodes",
	"infra.keycodes",
	"json",
	-- Optional keymap startup imports survive a rejected parent construction.
	"adapters.clipboard",
	"adapters.file_system",
	"adapters.json_codec",
	"adapters.keyboard_geometry",
	"adapters.shell_runner",
	"adapters.task_environment",
	"adapters.text_sender",
	"adapters.tooltip_renderer",
	"compat.utf8",
	"core.llm.ollama_runtime_choice",
	"diagnostics.operation_reporter",
	"diagnostics.runtime_log",
	"hotstring_engine",
	"hotstring_priority",
	"hotstrings.languages",
	"hotstrings.personal_files",
	"infra.capsword_output",
	"infra.deferred_work",
	"infra.fs_dir",
	"infra.hotstring_engine",
	"infra.launcher_environment",
	"keymap.control_signals",
	"keymap.terminators",
	"keymap.terminators_catalogue",
	"keymap.utils",
	"llm.enable_admission",
	"llm.local_server_auth",
	"llm.local_server_discovery",
	"llm.parser",
	"llm.profile_selector",
	"llm.prompt_action",
	"llm.prompt_builder",
	"llm.rewrite",
	"llm.translate",
	"logger",
	"modules.keymap.control_sentinels",
	"modules.keymap.expander",
	"modules.keymap.registry",
	"modules.keymap.registry_groups",
	"modules.keymap.registry_index",
	"modules.keymap.state",
	"modules.keymap.terminator_replay",
	"modules.keymap.terminators",
	"modules.keymap.utils",
	"modules.llm",
	"modules.llm.api_common",
	"modules.llm.api_token_crypto",
	"modules.llm.app_filter",
	"modules.llm.local_servers",
	"modules.llm.ollama_binary",
	"modules.llm.parser",
	"modules.llm.profiles",
	"modules.llm.prompt_builder",
	"modules.llm.streaming_handler",
	"platform.remap.lease_helper",
	"text_utils",
}

--- Owns native/cache ports and always retires both public runtimes.
---@param callback function Receives the real public runtime and native controls.
---@return ... results Original callback results.
function M.with_runtime(callback)
	return helpers.with_stub_scope(OWNERS, function()
		local fixture = ProvenanceFixture.load_keylogger()
		local engine, hs = fixture.keylogger, fixture.hs
		local driver = helpers.driver_root():gsub("/$", "")
		local native, tracker, control
		local obs = { stages = {}, tracker_receipts = {}, native_queries = {} }
		local function run()
			obs.logs, obs.caffeinate = {}, { created = 0, stopped = 0 }
			local initial_logger = assert(package.loaded["infra.logger"])
			for _, level in ipairs({ "error", "warn" }) do
				initial_logger[level] = function(_, format, ...)
					local row = { kind = "fixture_diagnostic", level = level, message = string.format(format, ...) }
					obs.logs[#obs.logs + 1] = row
				end
			end
			-- The provenance fixture does not start sensors for its ordinary consumers.
			-- A full engine startup must provide the native caffeinate watcher self receipt.
			hs.caffeinate = { watcher = { new = function(callback)
				obs.caffeinate.created = obs.caffeinate.created + 1
				local watcher = { active = false, callback = callback }
				function watcher:start() self.active = true; return self end
				function watcher:stop()
					self.active = false
					obs.caffeinate.stopped = obs.caffeinate.stopped + 1
					return self
				end
				return watcher
			end } }
			native = { name = "TextEdit", pid = 101, bundle = "com.apple.TextEdit", fault = nil }
			local manager = assert(package.loaded["modules.keylogger.log_manager"])
			obs.modifier_presses = 0
			manager.log_modifier_press = function() obs.modifier_presses = obs.modifier_presses + 1 end
			manager.log_modifier_hold = function() end
			local native_mono = 10000000000
			hs.timer.absoluteTime = function() return native_mono end
			local field = { attributeValue = function(_, key)
				if key == "AXRole" then return "AXTextField" end
				if key == "AXSubrole" then return "AXTextField" end
				if key == "AXValue" then return "" end
			end }
			local app = {
				name = function()
					obs.native_queries[#obs.native_queries + 1] = "name"
					if native.fault == "throw-name" then error("controlled native application name refusal") end
					if native.fault == "nil-name" then return nil end
					if native.fault == "empty-name" then return "" end
					return native.name
				end,
				pid = function()
					if native.fault == "throw-pid" then error("controlled native PID refusal") end
					if native.fault == "nil-pid" then return nil end
					return native.pid
				end,
				bundleID = function()
					if native.fault == "throw-bundle" then error("controlled native bundle refusal") end
					if native.no_bundle then return nil end
					return native.bundle
				end,
				path = function()
					if native.fault == "throw-path" then error("controlled native path refusal") end
					if native.no_path then return nil end
					return "/Applications/" .. native.name .. ".app"
				end,
			}
			hs.application.frontmostApplication = function()
				obs.native_queries[#obs.native_queries + 1] = "frontmost"
				if native.on_frontmost then native.on_frontmost() end
				if native.fault == "throw-frontmost" then error("controlled native workspace refusal") end
				if native.fault == "nil-frontmost" then return nil end
				return app
			end
			hs.window.focusedWindow = function() return nil end
			hs.axuielement.applicationElement = function()
				return { attributeValue = function(_, key) if key == "AXFocusedUIElement" then return field end end }
			end
			hs.axuielement.observer = { new = function() return nil end }
			package.loaded["adapters.secure_field_detector"] = nil
			local tracker_path = driver .. "/modules/keylogger/context_tracker.lua"
			tracker = assert(loadfile(tracker_path))()
			local tracker_port = assert(package.loaded["modules.keylogger.context_tracker"])
			local original_tracker_init = assert(tracker_port.init)
			local actual_tracker_init_arguments
			tracker_port.init = function(...)
				local result = table.pack(original_tracker_init(...))
				if result[1] ~= true then return table.unpack(result, 1, result.n) end
				actual_tracker_init_arguments = table.pack(...)
				return tracker.init(...)
			end
			tracker_port.app_watcher_cb = tracker.app_watcher_cb
			tracker_port.resync_context = function(...)
				local receipt = table.pack(pcall(tracker.resync_context, ...))
				obs.tracker_receipts[#obs.tracker_receipts + 1] = { call_ok = receipt[1], result = receipt[2], detail = not receipt[1] and tostring(receipt[2]) or nil }
				if not receipt[1] then error(receipt[2], 0) end
				if native.after_resync == "false" then return false end
				if native.after_resync == "throw" then error("controlled delegated post-refresh refusal") end
				return table.unpack(receipt, 2, receipt.n)
			end
			local activation_callback
			package.loaded["adapters.process_lifecycle"].onAppActivate = function(callback)
				activation_callback = callback
				return true
			end
			local notices = {}
			package.loaded["infra.notifications"] = { notify = function(message) notices[#notices + 1] = message end }
			package.loaded["modules.gestures.engine"] = {}
			package.loaded["modules.gestures.actions"] = { SG_NAMES = {}, get_label = function(value) return value end }
			package.loaded["adapters.key_state"] = {}
			package.loaded["infra.script_chord_catalogue"] = {}
			local function yes() return true end
			for _, name in ipairs({ "modules.llm.api_mlx", "modules.llm.api_ollama", "modules.llm.api_remote", "modules.llm.warmup_controller" }) do
				package.loaded[name] = { pause_warmup = yes, resume_warmup = yes, stop_warmup = yes, stop = yes }
			end
			for _, name in ipairs({ "ui.wpm.wpm_menubar", "ui.wpm.wpm_widget" }) do package.loaded[name] = { is_running = function() return false end } end
			package.loaded["platform.remap.onboarding"] = { stop = yes }
			package.loaded["ui.tooltip"] = { hide_forced = yes }
			local control_path = driver .. "/modules/shortcuts/script_control.lua"
			control = assert(loadfile(control_path))()
			package.loaded["modules.shortcuts.script_control"] = control
			package.loaded["modules.keylogger"] = engine
			local keymap = { pause_processing = yes, resume_processing = yes, reset_predictions_for_pause = yes }
			local shortcuts = { is_bindings_started = function() return false end,
				has_bindings_pause_debt = function() return false end, pause_bindings = yes, release_bindings_pause_claim = yes }
			local gestures = { is_enabled = function() return false end, suspend = yes, resume = yes }
			assert(control.start(keymap, shortcuts, gestures, nil) == true, "Real script-control tap/watchdog startup must commit")
			local keyboard_hook = assert(package.loaded["adapters.keyboard_hook"])
			keyboard_hook.start = function(options) obs.handle_key = options.onEvent; return true end
			assert(fixture.start(control) == true)
			local function upvalue(fn, wanted)
				for index = 1, 100 do
					local name, value = debug.getupvalue(fn, index)
					if name == wanted then return value end
					if name == nil then break end
				end
				error("Required owned observation is unavailable: " .. wanted)
			end
			assert(actual_tracker_init_arguments and actual_tracker_init_arguments.n == 4)
			assert(rawequal(actual_tracker_init_arguments[1], fixture.state)
				and rawequal(actual_tracker_init_arguments[2], package.loaded["modules.keylogger.log_manager"])
				and type(actual_tracker_init_arguments[3]) == "function"
				and type(actual_tracker_init_arguments[4]) == "function",
				"The actual engine init boundary must supply the exact context/modifier owners")
			engine.set_secure_field_filter_enabled(true)
			assert(tracker.capture_frontmost_app() == true)
			assert(engine.may_persist() == true and fixture.state.is_secure_field == false)
			assert(type(activation_callback) == "function")
			local function pump_until(predicate)
				for _ = 1, 500 do
					if predicate() then return end
					native_mono = native_mono + 1000000
					local timers = {}; for index, timer in ipairs(hs.timer.__timers) do timers[index] = timer end
					for _, timer in ipairs(timers) do
						if timer.running and timer.delay <= 0.1 then timer:fire() end
					end
				end
				assert(predicate(), "The real pause/resume transaction did not reach its settled boundary")
			end
			local function record(label)
				local allowed = engine.may_persist()
				local context_guard = upvalue(engine.context_allows_logging, "_modifier_context_pending")
				local auth_guard = upvalue(engine.context_allows_logging, "_system_auth_modifier_settlement_pending")
				local row = { label = label, paused = control.is_paused(), admission_open = fixture.synthetic_input.admission_open(),
				may_persist = allowed, secure = fixture.state.is_secure_field, active_app_name = fixture.state.active_app_name,
				foreground_refresh_pending = fixture.state.foreground_refresh_pending, modifier_context_pending = context_guard, auth_modifier_pending = auth_guard, emitted_snapshots = #fixture.flushes }
				obs.stages[#obs.stages + 1] = row
				return row
			end
			local function sink()
				local before = #fixture.flushes
				local accepted = engine.notify_synthetic("probe", "hotstring", 0)
				fixture.drain()
				return accepted == true, #fixture.flushes - before
			end
			local runtime = { engine = engine, tracker = tracker, control = control,
				state = fixture.state, native = native, observation = obs, sink = sink,
				record = record, app = app, hs = hs, tracker_port = tracker_port }
			function runtime.modifier_press()
				local event = hs.eventtap.event.newKeyEvent({ "cmd" }, 55, true)
				event.getType = function() return hs.eventtap.event.types.flagsChanged end
				event.getKeyCode = function() return 55 end
				event.getFlags = function() return { cmd = true } end
				event.getCharacters = function() return "" end
				assert(type(obs.handle_key) == "function")
				obs.handle_key(event)
				assert(type(fixture.state.modifier_down_at[55]) == "number" and obs.modifier_presses == 1)
				return fixture.state.modifier_down_at[55]
			end
			function runtime.pause()
				assert(control.pause_all() == true)
				pump_until(function() return control.is_paused() == true end)
				local paused = record("paused")
				assert(not paused.may_persist and not paused.admission_open)
				local accepted, count = sink(); assert(not accepted and count == 0)
			end
			function runtime.resume()
				assert(control.resume_all() == true)
				pump_until(function() return control.is_paused() == false end)
				local resumed = record("resumed")
				assert(resumed.admission_open and resumed.modifier_context_pending == false
					and resumed.auth_modifier_pending == false)
				return resumed
			end
			function runtime.activate()
				activation_callback(native.name, app)
			end
			function runtime.foreground(name, bundle)
				native.name, native.pid, native.bundle = name, 202, bundle
			end
			local accepted, count = sink()
			assert(accepted and count == 1, "The initial real public sink must commit")
			return callback(runtime)
		end
		local outcome = table.pack(xpcall(run, debug.traceback))
		local control_ok, control_result = pcall(function() return control == nil or control.stop() end)
		local engine_ok, engine_result = pcall(engine.stop)
		local stopped_control = control_ok and control_result == true
		local stopped_engine = engine_ok and engine_result == true
		if not outcome[1] then
			local details = { tostring(outcome[2]) }
			for _, row in ipairs(obs.logs or {}) do
				details[#details + 1] = tostring(row.level) .. ": " .. tostring(row.message)
			end
			error(table.concat(details, "\n"), 0)
		end
		assert(stopped_control and stopped_engine, "Both exact public runtimes must retire")
		assert(obs.caffeinate.created == 1 and obs.caffeinate.stopped == 1)
		return table.unpack(outcome, 2, outcome.n)
	end)
end

return M
