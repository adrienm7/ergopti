--- tests/support/remap_transaction_fixture.lua

--- ==============================================================================
--- MODULE: Remap Transaction Fixture
--- DESCRIPTION:
--- Owns remap, installer and script-control dependencies through all callbacks.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED_MODULES = {
	"platform.remap.defaults",
	"platform.remap.config",
	"platform.remap.generator",
	"platform.remap.ke_lifecycle",
	"platform.remap.lease_controller",
	"platform.remap.watchers",
	"adapters.hotkey_registrar",
	"infra.timings",
	"adapters.timer_scheduler",
	"infra.config_paths",
	"modules.keylogger.kc_bridge",
	"modules.gestures.engine",
	"modules.shortcuts",
	"platform.remap.onboarding",
	"platform.remap",
	"infra.logger",
	"infra.i18n",
	"infra.notifications",
	"infra.text_utils",
	"platform.remap.ke_paths",
	"adapters.task_lifecycle",
	"infra.keycodes",
	"modules.gestures.actions",
	"adapters.key_state",
	"modules.llm.warmup_controller",
	"modules.llm.api_mlx",
	"modules.llm.api_ollama",
	"modules.llm.api_remote",
	"ui.wpm.wpm_menubar",
	"ui.wpm.wpm_widget",
	"ui.tooltip",
	"modules.keylogger",
	"adapters.synthetic_input",
	"modules.shortcuts.script_control",
	"platform.remap.ke_variables",
	"adapters.json_codec",
	"adapters.shell_runner",
	"infra.deferred_work",
	"platform.remap.lease_contract",
	"modules.keymap.layout",
	"adapters.file_system",
	"infra.fs_dir",
	"adapters.event_provenance",
	"adapters.storage",
}

--- Runs native construction and every retained callback before restoring state.
--- @param run function Receives the scoped fixture constructors and observers.
return function(run)
	return helpers.with_stub_scope(OWNED_MODULES, function()
		local RealConfig = helpers.load_with_stubs("platform.remap.config")

		local REAL_ONBOARDING_CACHE_PATH = "/__ergopti_hs011_integration__/Karabiner-Elements.dmg"

		--- Clones a persisted payload so later live publication cannot rewrite evidence.
		--- @param value any Source value.
		--- @return any clone
		local function clone_payload(value)
			if type(value) ~= "table" then return value end
			local clone = {}
			for key, item in pairs(value) do clone[key] = clone_payload(item) end
			return clone
		end

		--- Loads platform.remap over pure doubles and returns observable side effects.
		--- @return table remap
		--- @return table calls
		local function load_enabled_remap(options)
			options = options or {}
			local onboarding_stop_succeeds = options.onboarding_stop_succeeds
			if onboarding_stop_succeeds == nil then onboarding_stop_succeeds = true end
			local calls = {
				stop = 0,
				stop_reasons = {},
				start = 0,
				start_paused = 0,
				build = 0,
				deploy = 0,
				execute = 0,
				save = 0,
				saved_enabled = {},
				saved_payloads = {},
				save_results = {},
				save_result_index = 0,
				lease_bound_starts = 0,
				stopped_token = "00112233445566778899aabbccddeeff",
				pause_callbacks = {},
				resume_callbacks = {},
				stop_exact = 0,
				stop_exact_tokens = {},
				stop_callbacks = {},
				classifier_refreshes = 0,
				classifier_clears = 0,
				save_succeeds = options.save_succeeds ~= false,
				lease_init = 0,
				input_source_watchers = 0,
				unbound = 0,
				gesture_stop_attempts = 0,
				lifecycle_stop_attempts = 0,
				lifecycle_stop_failures_remaining = 0,
				onboarding_stop_attempts = 0,
				onboarding_stop_succeeds = onboarding_stop_succeeds,
				lease_phase = options.initially_enabled == false and "prepared"
					or (options.paused == true and "paused" or "active"),
				timers = {},
				first_run_timers = {},
				timer_after_attempts = 0,
				timer_cancel_attempts = 0,
				wizard_runs = 0,
			}
			local paused_now = options.paused == true
			local lease_token = "ffeeddccbbaa99887766554433221100"
			local function publish_phase(phase)
				calls.lease_phase = phase
				if calls.phase_listener then calls.phase_listener(phase, lease_token) end
			end

			package.loaded["platform.remap.defaults"] = {
				tap_hold_timeout_ms = 200,
				sticky_timeout_ms = 1000,
				simultaneous_threshold_ms = 50,
				combo_symmetric = false,
			}
			package.loaded["platform.remap.config"] = {
				load_available_actions = function()
					if options.empty_data then return {} end
					return { { id = "none" } }
				end,
				load_tap_hold_keys = function() return { { id = "left_shift" } } end,
				load_mod_combos = function() return { { id = "left_shift+right_shift" } } end,
				compute_non_canonical_combos = function() return {} end,
				load_user_config = function(tap_hold_keys, mod_combos)
					if type(options.real_user_config_path) == "string" then
						return RealConfig.load_user_config(
							tap_hold_keys,
							mod_combos,
							options.real_user_config_path
						)
					end
					if options.config_error then return nil, "error" end
					return {
						enabled = options.initially_enabled ~= false,
						tap_hold_config = {},
						mod_combos_config = {},
						tap_hold_timeout_ms = 200,
						sticky_timeout_ms = 1000,
						simultaneous_threshold_ms = 50,
						combo_symmetric = false,
					}
				end,
				save_user_config = function(state)
					calls.save = calls.save + 1
					calls.saved_enabled[#calls.saved_enabled + 1] = state.enabled == true
					calls.saved_payloads[#calls.saved_payloads + 1] = clone_payload(state)
					calls.save_result_index = calls.save_result_index + 1
					local configured = calls.save_results[calls.save_result_index]
					if configured == "throw" then
						error("synthetic settings persistence failure")
					end
					if configured == "nil" then return nil end
					if configured == "false" then return false end
					if configured == "true" then return true end
					return calls.save_succeeds
				end,
				build_default_state = function()
					return {
						enabled = true,
						tap_hold_config = {},
						mod_combos_config = {},
						tap_hold_timeout_ms = 200,
						sticky_timeout_ms = 1000,
						simultaneous_threshold_ms = 50,
						combo_symmetric = false,
					}
				end,
				resolve_layout_actions = function() return 0 end,
			}
			package.loaded["platform.remap.generator"] = {
				build_karabiner_json = function(...)
					calls.build = calls.build + 1
					calls.build_token = select(7, ...)
					if options.build_succeeds == false then return nil, "build failed" end
					return {}
				end,
				merge_and_deploy_config = function()
					calls.deploy = calls.deploy + 1
					if options.deploy_succeeds == false or calls.fail_deploy then
						return false, "deploy failed"
					end
					return true, "ok"
				end,
				KE_PHYSICAL_KC_LOG = nil,
			}
			package.loaded["platform.remap.ke_lifecycle"] = {
				open_gui = function() return true end,
				stop = function()
					calls.lifecycle_stop_attempts = calls.lifecycle_stop_attempts + 1
					if calls.lifecycle_stop_failures_remaining > 0 then
						calls.lifecycle_stop_failures_remaining = calls.lifecycle_stop_failures_remaining - 1
						return false
					end
					return true
				end,
				notify_ready = function() end,
			}
			package.loaded["platform.remap.lease_controller"] = {
				init = function(phase_listener)
					calls.lease_init = calls.lease_init + 1
					calls.phase_listener = phase_listener
					return true
				end,
				token = function() return lease_token end,
				start = function(on_done)
					calls.start = calls.start + 1
					calls.start_callback = on_done
					return options.start_requested ~= false
				end,
				start_paused = function(on_done)
					calls.start_paused = calls.start_paused + 1
					if options.start_requested == false then return false end
					if calls.lease_phase == "paused" then
						on_done(true, "already-paused")
						return true
					end
					calls.start_paused_callback = on_done
					publish_phase("starting")
					return true
				end,
				resume_prepared = function(token, on_done)
					helpers.assert_eq(token, lease_token)
					calls.resume_prepared = (calls.resume_prepared or 0) + 1
					calls.resume_callbacks[#calls.resume_callbacks + 1] = on_done
					calls.resume_callback = on_done
					publish_phase("resuming")
					return true
				end,
				stop = function(reason, on_done)
					calls.stop = calls.stop + 1
					calls.stop_reasons[#calls.stop_reasons + 1] = reason
					calls.stop_callback = on_done
					calls.stop_callbacks[#calls.stop_callbacks + 1] = on_done
					return true
				end,
				pause = function(on_done)
					if options.pause_mode == "throw" then error("synthetic pause request failure") end
					if options.pause_mode == "false" then return false end
					calls.pause_callbacks[#calls.pause_callbacks + 1] = on_done
					calls.pause_callback = on_done
					return true
				end,
				resume = function(on_done)
					calls.resume = (calls.resume or 0) + 1
					calls.resume_callbacks[#calls.resume_callbacks + 1] = on_done
					calls.resume_callback = on_done
					publish_phase("resuming")
					return true
				end,
				stop_exact = function(token, reason)
					calls.stop_exact = calls.stop_exact + 1
					calls.stop_exact_tokens[#calls.stop_exact_tokens + 1] = token
					calls.stop_reasons[#calls.stop_reasons + 1] = reason
					publish_phase("stopping")
					return true
				end,
				status = function()
					return calls.lease_phase, {
						phase = calls.lease_phase,
						token = lease_token,
						activation_blocked = calls.activation_blocked == true,
					}
				end,
			}
			package.loaded["platform.remap.watchers"] = {
				start_gesture_watcher = function()
					calls.lease_bound_starts = calls.lease_bound_starts + 1
					return { stop = function() end }
				end,
				stop_gesture_watcher = function(watcher)
					if watcher == nil then return true end
					calls.gesture_stop_attempts = calls.gesture_stop_attempts + 1
					if calls.gesture_stop_attempts <= (options.gesture_stop_failures or 0) then
						return false
					end
					return true
				end,
				start_cycle_windows_hotkey = function()
					calls.hotkey_attempts = (calls.hotkey_attempts or 0) + 1
					if options.hotkey_failure_index == calls.hotkey_attempts then return nil end
					return "cycle"
				end,
				start_alt_tab_windows_hotkey = function()
					calls.hotkey_attempts = (calls.hotkey_attempts or 0) + 1
					if options.hotkey_failure_index == calls.hotkey_attempts then return nil end
					return "windows"
				end,
				start_alt_tab_apps_hotkey = function()
					calls.hotkey_attempts = (calls.hotkey_attempts or 0) + 1
					if options.hotkey_failure_index == calls.hotkey_attempts then return nil end
					return "apps"
				end,
				start_alt_tab_monitor_hotkey = function()
					calls.hotkey_attempts = (calls.hotkey_attempts or 0) + 1
					if options.hotkey_failure_index == calls.hotkey_attempts then return nil end
					return "monitor"
				end,
				start_input_source_watcher = function()
					calls.input_source_watchers = calls.input_source_watchers + 1
					return true
				end,
				stop_input_source_watcher = function() return true end,
				stop_alt_tab_apps_tracker = function() return true end,
			}
			package.loaded["adapters.hotkey_registrar"] = {
				unbind = function()
					calls.unbound = calls.unbound + 1
					return options.unbind_succeeds ~= false
				end,
			}
			package.loaded["infra.timings"] = { sec = function() return 0.01 end }
			local timer_scheduler = {}
			function timer_scheduler.after(delay, callback)
				calls.timer_after_attempts = calls.timer_after_attempts + 1
				local configured = nil
				if type(options.first_run_timer_after_results) == "table" then
					configured = options.first_run_timer_after_results[calls.timer_after_attempts]
				end
				if configured == "throw" then error("synthetic first-run timer acquisition failure") end
				local native_timer = {}
				if configured == "nil" then native_timer = nil end
				local timer = {
					callback = callback,
					committed = configured ~= false and configured ~= "nil",
					delay = delay,
					fired = false,
					timer = native_timer,
				}
				calls.first_run_timers[#calls.first_run_timers + 1] = timer
				if configured == false then return timer, false end
				if configured == "nil" then return timer, nil end
				return timer, true
			end
			function timer_scheduler.cancel(timer)
				if type(timer) ~= "table" or timer.timer == nil then return true end
				calls.timer_cancel_attempts = calls.timer_cancel_attempts + 1
				timer.committed = false
				local configured = nil
				if type(options.first_run_timer_cancel_results) == "table" then
					configured = options.first_run_timer_cancel_results[calls.timer_cancel_attempts]
				end
				if configured == "throw" then error("synthetic first-run timer cancellation failure") end
				if configured == false then return false end
				if configured == "nil" then return nil end
				timer.timer = nil
				return true
			end
			function timer_scheduler.every() return { committed = false, fired = true }, false end
			package.loaded["adapters.timer_scheduler"] = timer_scheduler
			package.loaded["infra.config_paths"] = { get = function() return "missing-config.toml" end }
			package.loaded["modules.keylogger.kc_bridge"] = {
				refresh_managed_set = function()
					calls.classifier_refreshes = calls.classifier_refreshes + 1
					if options.classifier_succeeds == false then error("classifier failed") end
					return true
				end,
				clear_managed_set = function()
					calls.classifier_clears = calls.classifier_clears + 1
					return true
				end,
			}
			package.loaded["modules.gestures.engine"] = {}
			package.loaded["modules.shortcuts"] = {
				is_paused = function() return paused_now end,
			}
			if options.onboarding_module then
				package.loaded["platform.remap.onboarding"] = options.onboarding_module
			else
				package.loaded["platform.remap.onboarding"] = {
					run_first_run_wizard = function()
						calls.wizard_runs = calls.wizard_runs + 1
						return true
					end,
					stop = function(on_done)
						calls.onboarding_stop_attempts = calls.onboarding_stop_attempts + 1
						if type(on_done) == "function" then
							local detail = "installer-stop-refused"
							if calls.onboarding_stop_succeeds then detail = "installer-stopped" end
							on_done(calls.onboarding_stop_succeeds, detail)
						end
						return calls.onboarding_stop_succeeds
					end,
				}
			end
			package.loaded["platform.remap"] = nil

			local remap = helpers.load_with_stubs("platform.remap", {
				execute = function()
					calls.execute = calls.execute + 1
					return "", true
				end,
				keycodes = {
					inputSourceChanged = function() end,
					currentLayout = function() return "ABC" end,
					map = { f17 = 64 },
				},
				timer = {
					doAfter = function(delay, callback)
						local timer = { delay = delay, callback = callback, running = true }
						function timer:stop() self.running = false end
						calls.timers[#calls.timers + 1] = timer
						return timer
					end,
					doEvery = function() return { stop = function() end } end,
					secondsSinceEpoch = function() return 1000 end,
					absoluteTime = function() return 0 end,
					usleep = function() end,
				},
			})
			if not options.skip_init then
				calls.init_result = remap.init({ expand_path = function(path) return path end })
			end
			calls.stop, calls.start, calls.start_paused = 0, 0, 0
			calls.build, calls.deploy, calls.execute, calls.save = 0, 0, 0, 0
			calls.saved_enabled = {}
			calls.saved_payloads = {}
			calls.lease_bound_starts = 0
			calls.hotkey_attempts = 0
			calls.lifecycle_stop_attempts = 0
			calls.lifecycle_stop_failures_remaining = options.lifecycle_stop_failures or 0
			calls.onboarding_stop_attempts = 0
			function calls.deliver_ready(ok, reason)
				publish_phase(ok == false and "failed" or "paused")
				local callback = calls.start_paused_callback
				calls.start_paused_callback = nil
				if callback then callback(ok ~= false, reason or (ok == false and "ready-failed" or "ready-paused")) end
			end
			function calls.deliver_resumed(ok, reason)
				publish_phase(ok == false and "paused" or "active")
				local callbacks = calls.resume_callbacks
				calls.resume_callbacks = {}
				for _, callback in ipairs(callbacks) do
					callback(ok ~= false, reason or (ok == false and "resume-failed" or "resumed"))
				end
			end
			function calls.finish_stop(ok, reason)
				publish_phase(ok == true and "idle" or "prepared")
				local callbacks = calls.stop_callbacks
				calls.stop_callbacks = {}
				for _, callback in ipairs(callbacks) do
					if callback then callback(ok == true, reason or (ok == true and "stopped" or "stop-failed")) end
				end
			end
			function calls.set_paused(value) paused_now = value == true end
			function calls.set_save_succeeds(value) calls.save_succeeds = value == true end
			function calls.set_save_results(results)
				calls.save_results = {}
				for index, result in ipairs(results or {}) do
					calls.save_results[index] = result
				end
				calls.save_result_index = 0
			end
			function calls.force_first_run_callback(index)
				local timer = calls.first_run_timers[index or #calls.first_run_timers]
				if timer then timer.callback() end
			end
			function calls.fire_first_run_timer(index)
				local timer = calls.first_run_timers[index or #calls.first_run_timers]
				if not timer or timer.timer == nil or timer.committed ~= true then return false end
				timer.fired = true
				timer.committed = false
				timer_scheduler.cancel(timer)
				timer.callback()
				return true
			end
			return remap, calls
		end

		--- Loads the real onboarding lifecycle with one controlled download task, then
		--- injects that exact module into the real remap transaction.
		--- @return table remap Initialized remap module.
		--- @return table calls Remap-side observations.
		--- @return table installer Real onboarding task and terminal observations.
		local function load_remap_with_real_onboarding(remap_options)
			local saved_hs = _G.hs
			local absent_module = {}
			local isolated_module_names = {
				"infra.logger",
				"infra.i18n",
				"infra.notifications",
				"infra.text_utils",
				"platform.remap.ke_paths",
				"adapters.timer_scheduler",
				"adapters.task_lifecycle",
				"platform.remap.onboarding",
			}
			local saved_modules = {}
			for _, module_name in ipairs(isolated_module_names) do
				local loaded_module = package.loaded[module_name]
				if loaded_module == nil then
					saved_modules[module_name] = absent_module
				else
					saved_modules[module_name] = loaded_module
				end
			end
			local installer = {
				order = {},
				outcomes = {},
				tasks = {},
				timers = {},
			}
			local uuid_counter = 0
			local hs_stub = {
				execute = function() return "", true, "exit", 0 end,
				host = {
					uuid = function()
						uuid_counter = uuid_counter + 1
						return string.format("00000000-0000-4000-8000-%012x", uuid_counter)
					end,
				},
				task = {},
			}
			hs_stub.task.new = function(executable, callback, args)
				local task = {
					args = args,
					callback = callback,
					executable = executable,
					terminate_calls = 0,
				}
				function task:start() return self end
				function task:terminate()
					self.terminate_calls = self.terminate_calls + 1
					return self
				end
				function task:complete(rc, stdout, stderr)
					return self.callback(rc or 1, stdout or "", stderr or "cancelled")
				end
				installer.tasks[#installer.tasks + 1] = task
				return helpers.attach_native_task_environment(task)
			end

			local function noop() end
			_G.hs = hs_stub
			package.loaded["infra.logger"] = setmetatable({}, { __index = function() return noop end })
			package.loaded["infra.i18n"] = { get = function(key) return key end }
			package.loaded["infra.notifications"] = { notify = noop }
			package.loaded["infra.text_utils"] = {
				applescript_format = function(format, value) return string.format(format, value) end,
				escape_gsub_replacement = function(value) return value end,
				shell_quote = function(value) return value end,
			}
			package.loaded["platform.remap.ke_paths"] = {
				CLI = "/test/karabiner_cli",
				CORE_SERVICE = "/test/Karabiner-Core-Service",
				GRABBER = "/test/karabiner_grabber",
			}
			package.loaded["adapters.timer_scheduler"] = {
				after = function(delay, callback)
					local timer = { callback = callback, cancelled = false, delay = delay }
					installer.timers[#installer.timers + 1] = timer
					return timer, true
				end,
				cancel = function(timer)
					if timer then timer.cancelled = true end
					return true
				end,
				every = function() return nil, false end,
			}
			package.loaded["adapters.task_lifecycle"] = nil
			package.loaded["platform.remap.onboarding"] = nil
			local onboarding = require("platform.remap.onboarding")
			onboarding.load_manifest = function()
				return {
					file_name = "Karabiner-Elements.dmg",
					sha256 = string.rep("a", 64),
					source_url = "https://example.invalid/Karabiner-Elements.dmg",
					version = "99.0.0",
				}
			end
			onboarding.get_cache_dmg_path = function() return REAL_ONBOARDING_CACHE_PATH end
			local install_started = onboarding.install_karabiner_elements(function(ok, detail)
				installer.order[#installer.order + 1] = "installer"
				installer.outcomes[#installer.outcomes + 1] = { ok = ok, detail = detail }
			end)
			_G.hs = saved_hs
			for _, module_name in ipairs(isolated_module_names) do
				local saved_module = saved_modules[module_name]
				if saved_module == absent_module then
					package.loaded[module_name] = nil
				else
					package.loaded[module_name] = saved_module
				end
			end
			helpers.assert_true(install_started)
			helpers.assert_eq(#installer.tasks, 1,
				"the integration fixture must own one real onboarding download task")
			installer.task = installer.tasks[1]
			installer.onboarding = onboarding

			local options = {}
			for key, value in pairs(remap_options or {}) do options[key] = value end
			options.onboarding_module = onboarding
			local remap, calls = load_enabled_remap(options)
			return remap, calls, installer
		end

		--- Wires the real script-control state machine to a prepared remap module.
		--- @param remap table Initialized remap module.
		--- @return table script_control
		--- @return table effects
		local function load_resume_script_control(remap)
			local effects = {
				calls = {},
				notifications = {},
				pause_listener = {},
			}
			local function record(name)
				return function()
					effects.calls[name] = (effects.calls[name] or 0) + 1
					return true
				end
			end

			package.loaded["infra.notifications"] = {
				notify = function(title, body, kind)
					effects.notifications[#effects.notifications + 1] = {
						title = title,
						body = body,
						kind = kind,
					}
				end,
			}
			package.loaded["infra.keycodes"] = {
				F13_KARABINER_RETURN = 0x6A,
				F14_KARABINER_BACKSPACE = 0x6B,
				F15_KARABINER_ESCAPE = 0x6C,
				BACKSPACE = 0x33,
				RETURN = 0x24,
				ESCAPE = 0x35,
			}
			package.loaded["modules.gestures.engine"] = {}
			package.loaded["modules.gestures.actions"] = {
				get_label = function(name) return name end,
				execute_single = function() return true end,
				SG_NAMES = { "none", "script_pause_toggle" },
				AX_NAMES = {},
			}
			package.loaded["adapters.key_state"] = {
				is_right_altgr_held = function() return false end,
				describe_held_modifiers = function() return "(none)" end,
			}
			package.loaded["modules.llm.warmup_controller"] = {
				stop = record("warmup_stop"),
				schedule_warmup_with_retry = record("warmup_resume"),
			}
			package.loaded["modules.llm.api_mlx"] = {
				stop_warmup = record("mlx_stop"),
				resume_warmup = record("mlx_resume"),
			}
			package.loaded["modules.llm.api_ollama"] = { stop_warmup = record("ollama_stop") }
			package.loaded["modules.llm.api_remote"] = { stop_warmup = function() return true end }
			package.loaded["ui.wpm.wpm_menubar"] = {
				is_running = function() return false end,
			}
			package.loaded["ui.wpm.wpm_widget"] = {
				is_running = function() return false end,
			}
			package.loaded["platform.remap.onboarding"] = {
				stop = function(on_done)
					if type(on_done) == "function" then on_done(true, "stopped") end
					return true
				end,
			}
			package.loaded["ui.tooltip"] = { hide_forced = record("tooltip_hide") }
			package.loaded["modules.keylogger"] = {
				resync_context = record("keylogger_resync"),
				log_shortcut = function() end,
			}

			-- Bind both native timer owners to the same fresh hs run loop as script_control;
			-- cached adapters would retain prior timers or an obsolete commitment contract.
			package.loaded["adapters.synthetic_input"] = nil
			package.loaded["adapters.timer_scheduler"] = nil
			local script_control = helpers.load_with_stubs("modules.shortcuts.script_control")
			local script_hs = hs
			package.loaded["modules.shortcuts"] = {
				is_paused = function() return script_control.is_paused() end,
			}
			local keymap = {
				pause_processing = record("keymap_pause"),
				resume_processing = record("keymap_resume"),
				reset_predictions = record("keymap_reset"),
			}
			local shortcuts = {
				pause_bindings = record("shortcuts_pause"),
				resume_bindings = record("shortcuts_resume"),
				is_bindings_started = function() return true end,
			}
			local gestures = {
				suspend = record("gestures_pause"),
				resume = record("gestures_resume"),
				is_enabled = function() return true end,
			}
			helpers.assert_true(script_control.start(keymap, shortcuts, gestures, remap),
				"the integration fixture must commit script-control native ownership")
			script_control.set_on_pause_change(function(value)
				effects.pause_listener[#effects.pause_listener + 1] = value
			end)

			--- Fires only live one-shot zero-delay work, never the recurring tap watchdog.
			function effects.fire_deferred()
				for _, timer in ipairs(script_hs.timer.__timers) do
					if timer.delay == 0 and timer.recurring ~= true and timer.running then timer:fire() end
				end
			end

			return script_control, effects
		end

		--- Counts notifications with an exact title and kind.
		--- @param effects table Script-control observations.
		--- @param title string Expected localized title key.
		--- @param kind string Expected notification kind.
		--- @return number count Matching notifications.
		local function count_notifications(effects, title, kind)
			local count = 0
			for _, item in ipairs(effects.notifications) do
				if item.title == title and item.kind == kind then count = count + 1 end
			end
			return count
		end

		return run({
			load_enabled_remap = load_enabled_remap,
			load_remap_with_real_onboarding = load_remap_with_real_onboarding,
			load_resume_script_control = load_resume_script_control,
			clone_payload = clone_payload,
			count_notifications = count_notifications,
		})
	end)
end
