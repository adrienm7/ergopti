--- tests/unit/platform/remap/test_set_enabled_lease_transaction.lua

--- ==============================================================================
--- MODULE: Transactional Karabiner Enable/Disable Uses Only the Ergopti Lease
--- DESCRIPTION:
--- Behaviorally proves READY/STOPPED-ordered preference commits and exact
--- generation cleanup. No transition probes, launches, or tears down a stock
--- Karabiner process, and repeated clicks coalesce behind one native operation.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads platform.remap over pure doubles and returns observable side effects.
--- @return table remap
--- @return table calls
local function load_enabled_remap(options)
	options = options or {}
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
		lease_phase = options.initially_enabled == false and "prepared"
			or (options.paused == true and "paused" or "active"),
		timers = {},
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
		load_available_actions = function() return { { id = "none" } } end,
		load_tap_hold_keys = function() return { { id = "left_shift" } } end,
		load_mod_combos = function() return { { id = "left_shift+right_shift" } } end,
		compute_non_canonical_combos = function() return {} end,
		load_user_config = function()
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
	calls.init_result = remap.init({ expand_path = function(path) return path end })
	calls.stop, calls.start, calls.start_paused = 0, 0, 0
	calls.build, calls.deploy, calls.execute, calls.save = 0, 0, 0, 0
	calls.saved_enabled = {}
	calls.lease_bound_starts = 0
	calls.hotkey_attempts = 0
	calls.lifecycle_stop_attempts = 0
	calls.lifecycle_stop_failures_remaining = options.lifecycle_stop_failures or 0
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
	return remap, calls
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
		return function() effects.calls[name] = (effects.calls[name] or 0) + 1 end
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
	package.loaded["ui.tooltip"] = { hide_forced = record("tooltip_hide") }
	package.loaded["modules.keylogger"] = {
		resync_context = record("keylogger_resync"),
		log_shortcut = function() end,
	}

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
	script_control.start(keymap, shortcuts, gestures, remap)
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





-- =======================================
-- =======================================
-- ======= 1/ READY-Ordered Enable =======
-- =======================================
-- =======================================

helpers.describe("karabiner enable state is committed only after READY", function()
	helpers.it("coalesces enable clicks and leaves state/preferences false until READY", function()
		local remap, calls = load_enabled_remap({ initially_enabled = false })
		local first_result, second_result = nil, nil

		helpers.assert_true(remap.set_enabled(true, function(ok) first_result = ok end))
		helpers.assert_true(remap.set_enabled(true, function(ok) second_result = ok end))
		helpers.assert_eq(remap.get_enabled(), false,
			"deploy/start acceptance is not a committed enabled state")
		helpers.assert_eq(calls.save, 0, "enabled preference must not persist before READY")
		helpers.assert_eq(calls.build, 1)
		helpers.assert_eq(calls.deploy, 1)
		helpers.assert_eq(calls.start, 0, "fresh mode=ACTIVE must be unreachable")
		helpers.assert_eq(calls.start_paused, 1, "repeated enable clicks must join one paused start")
		helpers.assert_nil(first_result)
		helpers.assert_nil(second_result)

		calls.deliver_ready()
		helpers.assert_eq(remap.get_enabled(), true)
		helpers.assert_eq(calls.save, 1)
		helpers.assert_true(calls.saved_enabled[1] == true)
		helpers.assert_eq(calls.lease_bound_starts, 1)
		helpers.assert_eq(calls.hotkey_attempts, 4)
		helpers.assert_eq(calls.classifier_refreshes, 1)
		helpers.assert_eq(calls.resume_prepared, 1)
		helpers.assert_nil(first_result, "PAUSED READY is not an activation commit")
		calls.deliver_resumed()
		helpers.assert_true(first_result == true and second_result == true,
			"all joined callers must settle from the same RESUMED commit")
	end)

	helpers.it("keeps disabled and revokes the exact generation after every pre-READY failure", function()
		local cases = {
			{ label = "build", options = { build_succeeds = false } },
			{ label = "deploy", options = { deploy_succeeds = false } },
			{ label = "start", options = { start_requested = false } },
			{ label = "READY", options = {}, fail_ready = true },
		}
		for _, case in ipairs(cases) do
			case.options.initially_enabled = false
			local remap, calls = load_enabled_remap(case.options)
			local result = nil

			local accepted = remap.set_enabled(true, function(ok) result = ok end)
			if case.fail_ready then calls.deliver_ready(false, "ready-failed") end

			helpers.assert_eq(remap.get_enabled(), false, case.label .. " failure must not commit enabled")
			helpers.assert_eq(calls.save, 0, case.label .. " failure must not persist enabled=true")
			helpers.assert_eq(calls.stop, 1, case.label .. " failure must revoke its exact prepared/live token")
			helpers.assert_eq(calls.execute, 0, case.label .. " failure must not touch stock Karabiner")
			helpers.assert_true(accepted,
				"the public request remains accepted while exact failure teardown is pending: " .. case.label)
			helpers.assert_nil(result, "public failure waits for exact teardown: " .. case.label)
			calls.finish_stop(true, "stopped")
			helpers.assert_true(result == false, "failed enable must settle false: " .. case.label)
		end
	end)

	helpers.it("revokes READY when enabled preference persistence fails", function()
		local remap, calls = load_enabled_remap({ initially_enabled = false, save_succeeds = false })
		local result = nil
		remap.set_enabled(true, function(ok) result = ok end)

		calls.deliver_ready()
		helpers.assert_eq(remap.get_enabled(), false,
			"READY cannot commit when enabled=true was not durably saved")
		helpers.assert_eq(calls.save, 1)
		helpers.assert_eq(calls.stop_exact, 1,
			"the prepared token must be fenced after the persistence commit fails")
		helpers.assert_eq(calls.stop, 1,
			"the joined enable transaction must await exact failure teardown")
		helpers.assert_eq(calls.lease_bound_starts, 1,
			"required inputs are proven before attempting the preference commit")
		helpers.assert_eq(calls.resume_prepared or 0, 0,
			"persistence failure must send no RESUME")
		helpers.assert_nil(result)

		calls.finish_stop(true, "stopped")
		helpers.assert_true(result == false)
	end)

	helpers.it("keeps enable uncommitted when a required lease input fails", function()
		local remap, calls = load_enabled_remap({
			initially_enabled = false,
			hotkey_failure_index = 2,
		})
		local result = nil
		remap.set_enabled(true, function(ok) result = ok end)

		calls.deliver_ready()
		helpers.assert_eq(remap.get_enabled(), false,
			"a failed required input mount must never commit enabled state")
		helpers.assert_true(helpers.deep_equal(calls.saved_enabled, {}),
			"no compensating write is needed when prerequisites precede commit")
		helpers.assert_true(helpers.deep_equal(calls.stop_reasons, {
			"lease_input_bind_failed",
			"integration_enable_failed",
		}), "the exact failure fence must precede the joined enable-abort teardown")
		helpers.assert_nil(result, "the caller must wait for exact fencing before failure settlement")
		calls.finish_stop(true, "stopped")
		helpers.assert_true(result == false)
		helpers.assert_eq(calls.execute, 0, "input rollback must never act on stock Karabiner")
	end)

	helpers.it("enables atomically paused without exposing normal rules", function()
		local remap, calls = load_enabled_remap({ initially_enabled = false, paused = true })
		local result = nil

		remap.set_enabled(true, function(ok) result = ok end)
		helpers.assert_eq(calls.start, 0)
		helpers.assert_eq(calls.start_paused, 1,
			"a paused enable must put atomic mode=2 in the helper's first write")
		helpers.assert_eq(remap.get_enabled(), false)
		calls.deliver_ready()

		helpers.assert_eq(remap.get_enabled(), true)
		helpers.assert_true(result == true)
		helpers.assert_eq(calls.lease_bound_starts, 0,
			"paused READY must not start lease-bound gesture or keylogger resources")
		helpers.assert_eq(calls.classifier_refreshes, 0)
		helpers.assert_eq(calls.resume_prepared or 0, 0)
	end)

	helpers.it("re-reads pause state at READY before choosing whether to activate", function()
		local remap, calls = load_enabled_remap({ initially_enabled = false, paused = true })
		local result = nil

		remap.set_enabled(true, function(ok) result = ok end)
		calls.set_paused(false)
		calls.deliver_ready()

		helpers.assert_eq(calls.lease_bound_starts, 1)
		helpers.assert_eq(calls.hotkey_attempts, 4)
		helpers.assert_eq(calls.classifier_refreshes, 1)
		helpers.assert_eq(calls.resume_prepared, 1)
		helpers.assert_nil(result)
		calls.deliver_resumed()
		helpers.assert_true(result == true)
	end)

	helpers.it("retains F17 consumers until STOPPED when RESUME fails after commit", function()
		local remap, calls = load_enabled_remap({ initially_enabled = false })
		local result = nil
		remap.set_enabled(true, function(ok) result = ok end)
		calls.deliver_ready()
		helpers.assert_eq(remap.get_enabled(), true,
			"the enabled preference is committed immediately before RESUME")
		helpers.assert_eq(calls.hotkey_attempts, 4)
		local clears_before_failure = calls.classifier_clears
		local unbound_before_failure = calls.unbound

		-- Reproduce quit/disable winning while RESUME is in flight. The real
		-- controller publishes STOPPING and rejects the queued RESUME callback.
		calls.lease_phase = "stopping"
		calls.phase_listener("stopping")
		local callbacks = calls.resume_callbacks
		calls.resume_callbacks = {}
		for _, callback in ipairs(callbacks) do callback(false, "lease-stopping") end

		helpers.assert_eq(calls.stop, 1)
		helpers.assert_eq(calls.unbound, unbound_before_failure,
			"managed rules may still emit until the exact stop fence settles")
		helpers.assert_eq(calls.classifier_clears, clears_before_failure,
			"classification must remain live beside the retained F17 consumers")
		helpers.assert_nil(result)

		calls.finish_stop(true, "stopped")
		helpers.assert_true(result == false)
		helpers.assert_true(calls.unbound >= 4)
	end)
end)





-- =========================================================
-- =========================================================
-- ======= 1b/ Synchronous setters are transactional =======
-- =========================================================
-- =========================================================

helpers.describe("karabiner synchronous setters commit disk before live state", function()
	helpers.it("rolls back every setter class when persistence returns false", function()
		local remap = load_enabled_remap({ save_succeeds = false })
		local setters = {
			{ call = function() return remap.set_tap_action("left_shift", "escape") end,
				read = function() return remap.get_tap_action("left_shift") end, expected = "none" },
			{ call = function() return remap.set_hold_action("left_shift", "layer") end,
				read = function() return remap.get_hold_action("left_shift") end, expected = "none" },
			{ call = function() return remap.set_tap_timeout("left_shift", 321) end,
				read = function() return remap.get_tap_timeout("left_shift") end, expected = nil },
			{ call = function() return remap.set_combo_tap_action("left_shift+right_shift", "escape") end,
				read = function() return remap.get_combo_tap_action("left_shift+right_shift") end, expected = "none" },
			{ call = function() return remap.set_combo_hold_action("left_shift+right_shift", "layer") end,
				read = function() return remap.get_combo_hold_action("left_shift+right_shift") end, expected = "none" },
			{ call = function() return remap.set_combo_combo_action("left_shift+right_shift", "escape") end,
				read = function() return remap.get_combo_combo_action("left_shift+right_shift") end, expected = "none" },
			{ call = function() return remap.set_tap_hold_timeout(321) end,
				read = remap.get_tap_hold_timeout, expected = 200 },
			{ call = function() return remap.set_sticky_timeout(4321) end,
				read = remap.get_sticky_timeout, expected = 1000 },
			{ call = function() return remap.set_simultaneous_threshold(87) end,
				read = remap.get_simultaneous_threshold, expected = 50 },
			{ call = function() return remap.set_combo_symmetric(true) end,
				read = remap.get_combo_symmetric, expected = false },
		}
		for index, case in ipairs(setters) do
			helpers.assert_eq(case.call(), false, "setter " .. index .. " must expose save refusal")
			helpers.assert_eq(case.read(), case.expected,
				"setter " .. index .. " must preserve its pre-save live value")
		end
	end)

	helpers.it("reset publishes all defaults together or preserves every prior value", function()
		local remap, calls = load_enabled_remap()
		helpers.assert_true(remap.set_tap_action("left_shift", "escape"))
		helpers.assert_true(remap.set_combo_symmetric(true))
		helpers.assert_true(remap.set_tap_hold_timeout(321))
		calls.set_save_succeeds(false)

		helpers.assert_eq(remap.reset_to_defaults(), false)
		helpers.assert_eq(remap.get_tap_action("left_shift"), "escape")
		helpers.assert_eq(remap.get_combo_symmetric(), true)
		helpers.assert_eq(remap.get_tap_hold_timeout(), 321)
	end)
end)

helpers.describe("karabiner init fails closed on unsafe persisted config", function()
	helpers.it("arms no state, lease, watcher, or regeneration surface", function()
		local remap, calls = load_enabled_remap({ config_error = true })
		helpers.assert_eq(calls.init_result, false)
		helpers.assert_eq(calls.lease_init, 0,
			"an unreadable config may contain enabled=false, so no lease generation may be prepared")
		helpers.assert_eq(calls.input_source_watchers, 0)
		helpers.assert_eq(calls.build, 0)
		helpers.assert_eq(calls.deploy, 0)
		helpers.assert_eq(remap.get_enabled(), false,
			"require_state must prove that no default state was published")
	end)
end)





-- ========================================
-- ========================================
-- ======= 2/ Disable Is Lease-Only =======
-- ========================================
-- ========================================

helpers.describe("karabiner set_enabled(false) is exact-lease-only", function()
	helpers.it("revokes once and performs no stock or deploy side effect", function()
		local remap, calls = load_enabled_remap()

		remap.set_enabled(false)

		helpers.assert_eq(calls.stop, 1)
		helpers.assert_eq(calls.start, 0)
		helpers.assert_eq(calls.build, 0)
		helpers.assert_eq(calls.deploy, 0)
		helpers.assert_eq(calls.execute, 0,
			"disable must not probe, launch or signal a stock Karabiner process")
		calls.finish_stop(true, "stopped")
	end)

	helpers.it("coalesces repeated disable clicks while STOPPED is pending", function()
		local remap, calls = load_enabled_remap()
		remap.set_enabled(false)
		calls.stop, calls.execute = 0, 0

		remap.set_enabled(false)

		helpers.assert_eq(calls.stop, 0,
			"a pending disable must not start a second stop transaction")
		helpers.assert_eq(calls.execute, 0)
		calls.finish_stop(true, "stopped")
	end)

	helpers.it("rejects resume while the previous generation is still disabling", function()
		local remap, calls = load_enabled_remap({ paused = true })
		helpers.assert_true(remap.set_enabled(false))
		local build_before = calls.build
		local resumed, reason = nil, nil

		helpers.assert_true(remap.resume(function(ok, detail)
			resumed, reason = ok, detail
		end) == false)
		helpers.assert_true(resumed == false)
		helpers.assert_eq(reason, "disable-in-progress")
		helpers.assert_eq(calls.build, build_before,
			"resume must not deploy generation B before generation A reports STOPPED")
		helpers.assert_eq(calls.start_paused, 0)
		calls.finish_stop(true, "stopped")
	end)
end)





-- =================================================
-- =================================================
-- ======= 3/ Pause/Resume Callback Boundary =======
-- =================================================
-- =================================================

helpers.describe("karabiner pause/resume API exposes the complete transaction boundary", function()
	for _, mode in ipairs({ "throw", "false" }) do
		helpers.it("contains a PAUSE request returning " .. mode, function()
			local remap, calls = load_enabled_remap({ pause_mode = mode })
			local results = {}
			local call_ok, accepted = pcall(remap.pause, function(ok, reason)
				results[#results + 1] = { ok = ok, reason = reason }
			end)

			helpers.assert_true(call_ok, "PAUSE request failure escaped the public boundary")
			helpers.assert_true(accepted == false)
			helpers.assert_eq(#calls.pause_callbacks, 0)
			helpers.assert_eq(#results, 1, "the public callback must settle exactly once")
			helpers.assert_true(results[1].ok == false)
			helpers.assert_eq(results[1].reason,
				mode == "throw" and "request-raised" or "request-rejected")
		end)
	end

	helpers.it("settles pause only when the controller reports PAUSED", function()
		local remap, calls = load_enabled_remap()
		local result = nil

		helpers.assert_true(remap.pause(function(ok) result = ok end))
		helpers.assert_nil(result)
		calls.pause_callback(true, "paused")
		helpers.assert_true(result == true)
	end)

	helpers.it("publishing failure leaves the existing generation PAUSED and sends no RESUME", function()
		local remap, calls = load_enabled_remap({ paused = true, deploy_succeeds = false })
		local result = nil

		remap.resume(function(ok) result = ok end)
		helpers.assert_true(result == false)
		helpers.assert_eq(calls.build, 1)
		helpers.assert_eq(calls.deploy, 1)
		helpers.assert_eq(calls.resume or 0, 0,
			"publication failure must occur before the first RESUME write")
		helpers.assert_eq(calls.lease_bound_starts, 0)
		helpers.assert_eq(calls.stop, 0)
		helpers.assert_eq(calls.stop_exact, 0,
			"the already-PAUSED generation is the fail-closed rollback state")
	end)

	helpers.it("deploys and mounts every consumer before the first RESUME", function()
		local remap, calls = load_enabled_remap({ paused = true })
		local result = nil
		local starts_seen_by_callback = nil

		helpers.assert_true(remap.resume(function(ok)
			result = ok
			starts_seen_by_callback = calls.lease_bound_starts
		end))
		helpers.assert_nil(result,
			"local preparation alone must not publish success before RESUMED")
		helpers.assert_eq(calls.build, 1,
			"the private resume capability must refresh settings while script_control stays paused")
		helpers.assert_eq(calls.deploy, 1)
		helpers.assert_eq(calls.start, 0)
		helpers.assert_eq(calls.start_paused, 1)
		helpers.assert_eq(calls.lease_bound_starts, 1,
			"lease-bound inputs must mount while the generation remains PAUSED")
		helpers.assert_eq(calls.hotkey_attempts, 4)
		helpers.assert_eq(calls.classifier_refreshes, 1)
		helpers.assert_eq(calls.resume, 1,
			"explicit user resume sends exactly one RESUME after local preparation")

		calls.deliver_resumed()
		helpers.assert_eq(starts_seen_by_callback, 1,
			"the callback itself must observe already-started lease-bound inputs")
		helpers.assert_true(result == true)
	end)

	helpers.it("a failed local prerequisite retains the same PAUSED token without STOP", function()
		local remap, calls = load_enabled_remap({ paused = true, classifier_succeeds = false })
		local result = nil

		remap.resume(function(ok) result = ok end)
		helpers.assert_true(result == false)
		helpers.assert_eq(calls.lease_bound_starts, 1)
		helpers.assert_eq(calls.hotkey_attempts, 4)
		helpers.assert_eq(calls.unbound, 4)
		helpers.assert_eq(calls.resume or 0, 0)
		helpers.assert_eq(calls.stop, 0)
		helpers.assert_eq(calls.stop_exact, 0)
		helpers.assert_eq(calls.lease_phase, "paused")
	end)

	helpers.it("never treats retained disabled hotkey handles as live on resume", function()
		local remap, calls = load_enabled_remap({ paused = true, unbind_succeeds = false })
		local first_result = nil
		helpers.assert_true(remap.resume(function(ok) first_result = ok end))
		calls.deliver_resumed()
		helpers.assert_true(first_result == true)
		helpers.assert_eq(calls.resume, 1)

		calls.lease_phase = "paused"
		calls.phase_listener("paused")
		local retry_result, retry_reason = nil, nil
		helpers.assert_true(remap.resume(function(ok, reason)
			retry_result, retry_reason = ok, reason
		end))

		helpers.assert_true(retry_result == false)
		helpers.assert_eq(retry_reason, "lease-input-start-failed")
		helpers.assert_eq(calls.resume, 1,
			"a second RESUME must not be sent while all retained handles are disabled")
		helpers.assert_eq(calls.hotkey_attempts, 4,
			"non-live retained handles must not authorize or trigger fresh partial binds")
	end)

	helpers.it("keeps script-control paused when RESUMED is followed by deploy failure", function()
		local remap, calls = load_enabled_remap()
		local script_control, effects = load_resume_script_control(remap)

		script_control.pause_all()
		effects.fire_deferred()
		helpers.assert_eq(#calls.pause_callbacks, 1)
		calls.lease_phase = "paused"
		calls.phase_listener("paused")
		calls.pause_callbacks[1](true, "paused")
		helpers.assert_true(script_control.is_paused())

		calls.fail_deploy = true
		script_control.resume_all()
		effects.fire_deferred()

		helpers.assert_eq(calls.build, 1,
			"the reproduction must reach paused regeneration")
		helpers.assert_eq(calls.deploy, 1,
			"the reproduction must fail at publication rather than before generation")
		helpers.assert_true(script_control.is_paused(),
			"RESUMED plus failed publication must not commit _is_paused=false")
		helpers.assert_eq(count_notifications(effects, "script_control.resumed", "success"), 0,
			"failed publication must never display the resume success notification")
		helpers.assert_eq(effects.calls.keymap_resume, nil)
		helpers.assert_eq(effects.calls.shortcuts_resume, nil)
		helpers.assert_eq(effects.calls.gestures_resume, nil)
		helpers.assert_eq(calls.lease_bound_starts, 0,
			"no lease-bound input may start from a generation that failed to publish")
		helpers.assert_eq(calls.start, 0,
			"a failed publication must not request ACTIVE authority")
		helpers.assert_eq(calls.resume or 0, 0,
			"publication failure must precede RESUME")
		helpers.assert_eq(#calls.pause_callbacks, 1,
			"the native generation never left PAUSED, so no rollback PAUSE is needed")

		helpers.assert_true(script_control.is_paused())
		helpers.assert_true(helpers.deep_equal(effects.pause_listener, { true }),
			"a failed resume must publish no false state transition")
		helpers.assert_eq(count_notifications(effects, "script_control.resumed", "success"), 0)
		helpers.assert_eq(count_notifications(effects, "script_control.resume_failed", "error"), 1)

		calls.fail_deploy = false
		script_control.resume_all()
		effects.fire_deferred()
		helpers.assert_true(script_control.is_paused(),
			"a retry must still wait for RESUMED before committing")
		helpers.assert_eq(calls.lease_bound_starts, 1)
		helpers.assert_eq(calls.resume, 1)
		calls.deliver_resumed()
		helpers.assert_true(not script_control.is_paused(),
			"the same public path must remain retryable from exact PAUSED")
		helpers.assert_eq(calls.lease_bound_starts, 1)
		helpers.assert_eq(count_notifications(effects, "script_control.resumed", "success"), 1)
		script_control.stop()
	end)
end)





-- ===============================================
-- ===============================================
-- ======= 4/ STOPPED-Ordered State Commit =======
-- ===============================================
-- ===============================================

helpers.describe("karabiner disable state is committed only after STOPPED", function()
	helpers.it("keeps exact fence success distinct from a failed local hotkey delete", function()
		local remap, calls = load_enabled_remap({
			initially_enabled = false,
			unbind_succeeds = false,
		})
		remap.set_enabled(true)
		calls.deliver_ready()
		calls.deliver_resumed()

		local fenced, fence_reason = nil, nil
		helpers.assert_true(remap.revoke("test_shutdown", function(ok, reason)
			fenced, fence_reason = ok, reason
		end))
		helpers.assert_nil(fenced)
		calls.finish_stop(true, "stopped")

		helpers.assert_true(fenced == true,
			"STOPPED is an exact external fact even if later local cleanup fails")
		helpers.assert_eq(fence_reason, "stopped")
		helpers.assert_true(remap.teardown_local() == false,
			"a retained local hotkey must remain retryable without invalidating STOPPED")
		helpers.assert_true(fenced == true,
			"local teardown failure must not rewrite the published exact-fence result")
		helpers.assert_true(calls.unbound > 0,
			"the failure injection must reach a real lease-bound handle delete")
	end)

	helpers.it("retains a failed gesture watcher until local teardown retry", function()
		local remap, calls = load_enabled_remap({
			initially_enabled = false,
			gesture_stop_failures = 2,
		})
		remap.set_enabled(true)
		calls.deliver_ready()
		calls.deliver_resumed()

		local fenced = nil
		remap.revoke("test_shutdown", function(ok) fenced = ok end)
		calls.finish_stop(true, "stopped")
		helpers.assert_true(fenced == true)
		helpers.assert_eq(remap.teardown_local(), false,
			"the first native stop refusal must keep local teardown unsettled")
		helpers.assert_eq(calls.gesture_stop_attempts, 2)
		helpers.assert_eq(remap.teardown_local(), true,
			"the exact retained watcher must be retried, not forgotten")
		helpers.assert_eq(calls.gesture_stop_attempts, 3)
	end)

	helpers.it("retains a failed lifecycle timer cleanup until local teardown retry", function()
		local remap, calls = load_enabled_remap({
			initially_enabled = false,
		})
		remap.set_enabled(true)
		calls.deliver_ready()
		calls.deliver_resumed()

		local fenced = nil
		remap.revoke("test_shutdown", function(ok) fenced = ok end)
		calls.finish_stop(true, "stopped")
		helpers.assert_true(fenced == true)
		calls.lifecycle_stop_failures_remaining = 1
		local attempts_before_teardown = calls.lifecycle_stop_attempts
		local first_teardown = remap.teardown_local()
		helpers.assert_eq(calls.lifecycle_stop_attempts, attempts_before_teardown + 1,
			"local teardown must invoke the lifecycle cleanup exactly once per attempt")
		helpers.assert_eq(first_teardown, false,
			"a failed exact timer cancellation must keep local teardown unsettled")
		helpers.assert_eq(remap.teardown_local(), true,
			"the retained timer cleanup must be retried before teardown commits")
		helpers.assert_eq(calls.lifecycle_stop_attempts, attempts_before_teardown + 2)
		helpers.assert_eq(calls.execute, 0,
			"timer cleanup retry must never inspect or mutate stock Karabiner processes")
	end)

	helpers.it("commits disabled after a fallback fence without starting a recovery generation", function()
		local remap, calls = load_enabled_remap()
		local result, result_reason = nil, nil

		remap.set_enabled(false, function(ok, reason)
			result, result_reason = ok, reason
		end)
		-- The real controller uses ok=true once its native detached revoker has
		-- proven every exact token inert, even when the primary STOPPED ACK was lost.
		calls.finish_stop(true, "fallback-revoked")

		helpers.assert_eq(remap.get_enabled(), false)
		helpers.assert_eq(calls.save, 1)
		helpers.assert_true(calls.saved_enabled[1] == false)
		helpers.assert_true(result == true)
		helpers.assert_eq(result_reason, "fallback-revoked")
		helpers.assert_eq(calls.build, 0)
		helpers.assert_eq(calls.deploy, 0)
		helpers.assert_eq(calls.start, 0,
			"a proven fallback fence must not silently reactivate ErgoptiPlus")
		helpers.assert_eq(calls.start_paused, 0)
	end)

	helpers.it("keeps enabled state and persistence unchanged until the exact ACK", function()
		local remap, calls = load_enabled_remap()
		local result = nil

		remap.set_enabled(false, function(ok) result = ok end)
		helpers.assert_eq(remap.get_enabled(), true,
			"a stop request is not a committed disabled state")
		helpers.assert_eq(calls.save, 0, "disabled preference must not persist before STOPPED")
		helpers.assert_nil(result, "the public completion callback must wait for STOPPED")

		calls.finish_stop(true, "stopped")
		helpers.assert_eq(remap.get_enabled(), false)
		helpers.assert_eq(calls.save, 1)
		helpers.assert_true(result == true)
	end)

	helpers.it("rolls a failed stop forward to a new READY lease without claiming disabled", function()
		local remap, calls = load_enabled_remap()
		local result = nil

		remap.set_enabled(false, function(ok) result = ok end)
		calls.finish_stop(false, "stop-cli-failed")

		helpers.assert_eq(remap.get_enabled(), true,
			"failed STOPPED must preserve the last committed enabled preference")
		helpers.assert_eq(calls.save, 0)
		helpers.assert_eq(calls.build, 1,
			"a detached failed generation must be replaced explicitly")
		helpers.assert_eq(calls.deploy, 1)
		helpers.assert_eq(calls.start, 0)
		helpers.assert_eq(calls.start_paused, 1,
			"rollback generations must also begin atomically PAUSED")
		helpers.assert_true(calls.build_token ~= calls.stopped_token,
			"rollback generation must never reuse the detached lease token")
		helpers.assert_nil(result,
			"rollback is not complete until the replacement generation acknowledges READY")

		calls.deliver_ready()
		helpers.assert_nil(result,
			"restoration still waits for the exact RESUMED acknowledgement")
		calls.deliver_resumed()
		helpers.assert_true(result == false,
			"the requested disable failed even though the previous enabled state was restored")
		helpers.assert_eq(remap.get_enabled(), true)
	end)

	helpers.it("restores a failed disable atomically in paused mode without activating normal rules", function()
		local remap, calls = load_enabled_remap({ paused = true })
		local result = nil

		remap.set_enabled(false, function(ok) result = ok end)
		calls.finish_stop(false, "stop-cli-failed")

		helpers.assert_eq(remap.get_enabled(), true,
			"the last committed enabled state must survive paused rollback")
		helpers.assert_eq(calls.build, 1,
			"paused rollback must still deploy rules for a fresh generation")
		helpers.assert_eq(calls.start, 0,
			"paused rollback must never use the normal atomic mode=1 activation path")
		helpers.assert_eq(calls.start_paused, 1,
			"the replacement worker must request atomic mode=2 activation")
		helpers.assert_nil(result,
			"the failed disable must remain unsettled until paused READY")

		calls.deliver_ready()
		helpers.assert_true(result == false,
			"the disable request failed even though its prior paused state was restored")
		helpers.assert_eq(calls.lease_bound_starts, 0,
			"paused recovery must not restart gesture or keylogger resources")
	end)

	helpers.it("never starts a replacement lease after deployment fails", function()
		local remap, calls = load_enabled_remap({ deploy_succeeds = false })
		local result = nil

		remap.set_enabled(false, function(ok) result = ok end)
		calls.finish_stop(false, "stop-cli-failed")

		helpers.assert_eq(calls.build, 1)
		helpers.assert_eq(calls.deploy, 1)
		helpers.assert_eq(calls.start, 0,
			"a generation whose config was not deployed must never receive READY authority")
		helpers.assert_eq(calls.start_paused, 0)
		helpers.assert_true(result == false,
			"rollback must surface the deploy failure instead of waiting for an impossible READY")
		helpers.assert_eq(remap.get_enabled(), true)
	end)
end)
