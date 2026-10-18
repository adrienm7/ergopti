--- tests/support/platform/remap/layout/wake_reresolves_layout_actions_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_wake_reresolves_layout_actions
--- DESCRIPTION:
--- Prelude shared by the test_wake_reresolves_layout_actions_* test files: their modules, default
--- state and scenario fixture. Each test file loads it fresh, so no state
--- leaks from one file to the next.
--- ==============================================================================

local helpers = require("tests.helpers")

local SYSTEM_DID_WAKE = 7
local SCREENS_DID_UNLOCK = 8
local LEASE_TOKENS = {
	"00112233445566778899aabbccddeeff",
	"102132435465768798a9babbdcddedef",
}

--- Loads platform.remap with observable collaborators and a retained wake callback.
--- @param options table|nil Harness behavior overrides.
--- @return table remap
--- @return table calls
local function load_remap(options)
	options = options or {}
	local calls = {
		sequence = {},
		logs = {},
		refresh = 0,
		resolve = 0,
		build = 0,
		deploy = 0,
		lease_start = 0,
		lease_pause = 0,
		lease_resume = 0,
		lease_bound_start = 0,
		lease_bound_stop = 0,
		classifier_refresh = 0,
		managed_clear = 0,
		ke_stop = 0,
		rebind = 0,
		watcher_start = 0,
		watcher_stop = 0,
		watcher_active = false,
		wizard_runs = 0,
		onboarding_stops = 0,
		timer_cancel_attempts = 0,
		timers = {},
		lease_phase = options.initial_phase or "prepared",
		lease_start_callbacks = {},
		lease_pause_callbacks = {},
		lease_resume_callbacks = {},
		lease_stop_callbacks = {},
		script_paused = options.paused == true,
		activation_blocked = options.activation_blocked == true,
		refresh_enters_recovery = options.refresh_enters_recovery == true,
		lease_token = LEASE_TOKENS[1],
		lease_token_index = 1,
		resume_tokens = {},
		stop_exact_tokens = {},
	}

	local function append(value)
		calls.sequence[#calls.sequence + 1] = value
	end
	local function log(level)
		return function(_subsystem, message, ...)
			local ok, rendered = pcall(string.format, tostring(message), ...)
			calls.logs[#calls.logs + 1] = {
				level = level,
				message = ok and rendered or tostring(message),
			}
		end
	end
	package.loaded["infra.logger"] = {
		start = log("start"),
		debug = log("debug"),
		info = log("info"),
		warn = log("warn"),
		error = log("error"),
		success = log("success"),
		done = log("done"),
	}
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
			return {
				enabled = options.enabled ~= false,
				tap_hold_config = {},
				mod_combos_config = {},
				tap_hold_timeout_ms = 200,
				sticky_timeout_ms = 1000,
				simultaneous_threshold_ms = 50,
				combo_symmetric = false,
			}
		end,
		save_user_config = function() return true end,
		resolve_layout_actions = function()
			calls.resolve = calls.resolve + 1
			append("resolve")
			if options.resolve_raises then error("synthetic layout failure") end
			return 3, "ansi"
		end,
	}
	package.loaded["platform.remap.generator"] = {
		build_karabiner_json = function()
			calls.build = calls.build + 1
			append("build")
			return {}
		end,
		merge_and_deploy_config = function()
			calls.deploy = calls.deploy + 1
			append("deploy")
			return true, "ok"
		end,
		KE_PHYSICAL_KC_LOG = nil,
	}
	-- karabiner.json is not part of this scenario: the switch-off cleanup is
	-- covered by the rule-removal tests.
	package.loaded["platform.remap.managed_rule_removal"] = {
		remove_managed_rules = function() return true, "unchanged", 0 end,
	}
	package.loaded["platform.remap.ke_lifecycle"] = {
		open_gui = function() return true end,
		stop = function()
			calls.ke_stop = calls.ke_stop + 1
			append("ke-stop")
			return true
		end,
		notify_ready = function() end,
	}
	package.loaded["platform.remap.lease_controller"] = {
		unregister_guardian = function(on_done)
			calls.guardian_unregistrations = (calls.guardian_unregistrations or 0) + 1
			calls.unregister_callback = on_done
			if options.unregister_async ~= true then on_done(true, "unregistered") end
			return true
		end,
		init = function(listener)
			calls.phase_listener = listener
			return true
		end,
		token = function()
			if options.model_exact_layout_fence and calls.lease_token == nil then
				if calls.lease_phase ~= "idle" and calls.lease_phase ~= "failed" then return nil end
				calls.lease_token_index = calls.lease_token_index + 1
				calls.lease_token = LEASE_TOKENS[calls.lease_token_index]
				helpers.assert_type(calls.lease_token, "string",
					"test exhausted its fresh-token catalogue")
			end
			if calls.lease_phase == "idle" or calls.lease_phase == "failed" then
				calls.lease_phase = "prepared"
				if calls.phase_listener then calls.phase_listener("prepared") end
			end
			return calls.lease_token
		end,
		status = function()
			return calls.lease_phase, {
				phase = calls.lease_phase,
				token = (calls.lease_phase == "idle" or calls.lease_phase == "failed")
					and nil or calls.lease_token,
				activation_blocked = calls.activation_blocked,
			}
		end,
		refresh_liveness = function()
			calls.refresh = calls.refresh + 1
			append("refresh")
			if options.refresh_raises then error("synthetic refresh failure") end
			if calls.refresh_enters_recovery then
				calls.lease_phase = "recovering"
				if calls.phase_listener then calls.phase_listener("recovering") end
			end
			return options.refresh_result ~= false
		end,
		start = function()
			error("fresh ACTIVE start must be unreachable")
		end,
		start_paused = function(on_done)
			calls.lease_start = calls.lease_start + 1
			append("lease-start-paused")
			if calls.lease_phase == "paused" then
				on_done(true, "already-paused")
				return true
			end
			calls.lease_phase = "starting"
			calls.lease_start_callbacks[#calls.lease_start_callbacks + 1] = on_done
			return true
		end,
		resume_prepared = function(token, on_done)
			helpers.assert_eq(token, calls.lease_token,
				"RESUME must name the exact current generation")
			calls.lease_resume = calls.lease_resume + 1
			calls.resume_tokens[#calls.resume_tokens + 1] = token
			append("lease-resume")
			calls.lease_phase = "resuming"
			calls.lease_resume_callbacks[#calls.lease_resume_callbacks + 1] = on_done
			return true
		end,
		stop = function(_reason, on_done)
			calls.lease_phase = "stopping"
			calls.lease_stop_callbacks[#calls.lease_stop_callbacks + 1] = on_done
			return true
		end,
		stop_exact = function(token, _reason, on_done)
			calls.stop_exact_tokens[#calls.stop_exact_tokens + 1] = token
			if not options.model_exact_layout_fence then return true end
			if calls.lease_phase == "stopping" and token == calls.lease_token then return true end
			if token ~= calls.lease_token then
				if on_done then on_done(true, "generation-gone") end
				return true
			end
			calls.lease_phase = "stopping"
			append("lease-stopping")
			if calls.phase_listener then calls.phase_listener("stopping") end
			local start_callbacks = calls.lease_start_callbacks
			calls.lease_start_callbacks = {}
			for _, callback in ipairs(start_callbacks) do callback(false, "lease-stopping") end
			local resume_callbacks = calls.lease_resume_callbacks
			calls.lease_resume_callbacks = {}
			for _, callback in ipairs(resume_callbacks) do callback(false, "lease-stopping") end
			calls.lease_token = nil
			calls.lease_phase = "idle"
			append("lease-idle")
			if calls.phase_listener then calls.phase_listener("idle") end
			if on_done then on_done(true, "stopped") end
			return true
		end,
		pause = function(on_done)
			calls.lease_pause = calls.lease_pause + 1
			append("lease-pause")
			calls.lease_phase = "pausing"
			calls.lease_pause_callbacks[#calls.lease_pause_callbacks + 1] = on_done
			return true
		end,
		resume = function(on_done)
			calls.lease_resume = calls.lease_resume + 1
			calls.resume_tokens[#calls.resume_tokens + 1] = calls.lease_token
			append("lease-resume")
			calls.lease_phase = "resuming"
			calls.lease_resume_callbacks[#calls.lease_resume_callbacks + 1] = on_done
			return true
		end,
	}
	package.loaded["platform.remap.watchers"] = {
		start_gesture_watcher = function()
			calls.lease_bound_start = calls.lease_bound_start + 1
			append("lease-bound-start")
			return {
				stop = function()
					calls.lease_bound_stop = calls.lease_bound_stop + 1
				end,
			}
		end,
		stop_gesture_watcher = function(watcher)
			if watcher ~= nil then watcher:stop() end
			return true
		end,
		start_cycle_windows_hotkey = function() return "cycle" end,
		start_alt_tab_windows_hotkey = function() return "windows" end,
		start_alt_tab_apps_hotkey = function() return "apps" end,
		start_alt_tab_monitor_hotkey = function() return "monitor" end,
		start_input_source_watcher = function() return true end,
		stop_input_source_watcher = function() return true end,
		stop_alt_tab_apps_tracker = function() return true end,
	}
	package.loaded["adapters.hotkey_registrar"] = { unbind = function() return true end }
	-- layers.toml, read at every regeneration, lives in get_config_dir(); none here.
	package.loaded["infra.config_paths"] = {
		get = function() return "missing-config.toml" end,
		get_config_dir = function() return "tests/unit/platform/remap/no-layers-toml" end,
	}
	package.loaded["modules.keylogger.kc_bridge"] = {
		clear_managed_set = function()
			calls.managed_clear = calls.managed_clear + 1
			append("managed-clear")
			return true
		end,
		refresh_managed_set = function()
			calls.classifier_refresh = calls.classifier_refresh + 1
			append("classifier-refresh")
			return true
		end,
	}
	package.loaded["modules.gestures.engine"] = {}
	package.loaded["modules.shortcuts"] = {
		is_paused = function()
			append("pause-query")
			if options.pause_raises then error("synthetic pause-state failure") end
			return calls.script_paused
		end,
		rebind_for_layout = function()
			calls.rebind = calls.rebind + 1
			append("rebind")
			if options.rebind_raises then error("synthetic rebind failure") end
			return options.rebind_result ~= false
		end,
	}
	package.loaded["platform.remap.onboarding"] = {
		run_first_run_wizard = function()
			calls.wizard_runs = calls.wizard_runs + 1
		end,
		stop = function(on_done)
			calls.onboarding_stops = calls.onboarding_stops + 1
			if type(on_done) == "function" then on_done(true, "onboarding-stopped") end
			return true
		end,
	}

	local retained_callback = nil
	local wake_watcher = {
		start = function(self)
			calls.watcher_start = calls.watcher_start + 1
			if options.start_activates_then_raises then
				calls.watcher_active = true
				error("synthetic watcher start failure after activation")
			end
			if options.start_raises then error("synthetic watcher start failure") end
			if options.start_result == false then return false end
			calls.watcher_active = true
			return self
		end,
		stop = function(self)
			calls.watcher_stop = calls.watcher_stop + 1
			if calls.watcher_stop <= (options.stop_refusals or 0) then
				error("synthetic watcher stop failure")
			end
			calls.watcher_active = false
			return self
		end,
	}
	package.loaded["hs.caffeinate.watcher"] = {
		systemDidWake = SYSTEM_DID_WAKE,
		screensDidUnlock = SCREENS_DID_UNLOCK,
		new = function(callback)
			if options.constructor_raises then error("synthetic watcher construction failure") end
			if options.constructor_nil then return nil end
			retained_callback = callback
			return wake_watcher
		end,
	}

	local function new_timer(delay, callback)
		local timer = {
			delay = delay,
			callback = callback,
			running = true,
			fired = false,
			committed = true,
		}
		timer.timer = timer
		function timer:stop()
			self.running = false
			return self
		end
		function timer:fire(force)
			if not self.running and force ~= true then return end
			self.running = false
			self.fired = true
			self.committed = false
			self.timer = nil
			self.callback()
		end
		calls.timers[#calls.timers + 1] = timer
		if options.settle_timer_synchronous and delay ~= 2.0 then timer:fire() end
		return timer
	end
	package.loaded["adapters.timer_scheduler"] = {
		after = function(delay, callback)
			return new_timer(delay, callback), true
		end,
		cancel = function(timer)
			if type(timer) ~= "table" or timer.timer == nil then return true end
			calls.timer_cancel_attempts = calls.timer_cancel_attempts + 1
			if calls.timer_cancel_attempts <= (options.timer_cancel_refusals or 0) then
				timer.committed = false
				return false
			end
			local stopped = timer:stop()
			if stopped == false then return false end
			timer.committed = false
			timer.fired = true
			timer.timer = nil
			return true
		end,
	}

	local remap = helpers.load_with_stubs("platform.remap", {
		execute = function() return "", true end,
		keycodes = {
			inputSourceChanged = function() end,
			currentLayout = function() return "ABC" end,
			map = { f17 = 64 },
		},
		timer = {
			doAfter = function(delay, callback)
				return new_timer(delay, callback)
			end,
			doEvery = function()
				return { stop = function() end }
			end,
			secondsSinceEpoch = function() return 1000 end,
			absoluteTime = function() return 0 end,
			usleep = function() end,
		},
	})
	local init_ok, init_err = pcall(remap.init, {
		expand_path = function(path) return path end,
		read = function() return nil end,
	})
	calls.init_ok = init_ok
	calls.init_err = init_err
	calls.wake = function(event)
		if not retained_callback then return false, "no callback" end
		return pcall(retained_callback, event)
	end
	calls.fire_latest_timer = function(force)
		local timer = calls.timers[#calls.timers]
		if not timer then return false end
		timer:fire(force)
		return true
	end
	calls.latest_timer = function() return calls.timers[#calls.timers] end
	calls.retained_callback = function() return retained_callback end
	calls.set_script_paused = function(value) calls.script_paused = value == true end
	calls.publish_phase = function(phase)
		calls.lease_phase = phase
		append("lease-" .. phase)
		if calls.phase_listener then calls.phase_listener(phase) end
	end
	calls.deliver_start_callbacks = function(ok, reason)
		local callbacks = calls.lease_start_callbacks
		calls.lease_start_callbacks = {}
		for _, callback in ipairs(callbacks) do
			callback(ok ~= false, reason or (ok == false and "start-failed" or "ready-paused"))
		end
	end
	calls.deliver_ready = function()
		calls.publish_phase("paused")
		calls.deliver_start_callbacks(true, "ready-paused")
	end
	calls.deliver_pause_callbacks = function(ok, reason)
		local callbacks = calls.lease_pause_callbacks
		calls.lease_pause_callbacks = {}
		for _, callback in ipairs(callbacks) do
			callback(ok ~= false, reason or (ok == false and "pause-failed" or "paused"))
		end
	end
	calls.deliver_paused = function()
		calls.publish_phase("paused")
		calls.deliver_pause_callbacks(true, "paused")
	end
	calls.deliver_resume_callbacks = function(ok, reason)
		local callbacks = calls.lease_resume_callbacks
		calls.lease_resume_callbacks = {}
		for _, callback in ipairs(callbacks) do
			callback(ok ~= false, reason or (ok == false and "resume-failed" or "resumed"))
		end
	end
	calls.deliver_resumed = function()
		calls.publish_phase("active")
		calls.deliver_resume_callbacks(true, "resumed")
	end
	calls.deliver_stop_callbacks = function(ok, reason)
		local callbacks = calls.lease_stop_callbacks
		calls.lease_stop_callbacks = {}
		for _, callback in ipairs(callbacks) do
			callback(ok ~= false, reason or (ok == false and "stop-failed" or "stopped"))
		end
	end
	calls.deliver_stopped = function()
		calls.publish_phase("idle")
		calls.deliver_stop_callbacks(true, "stopped")
	end
	calls.deliver_stop_failure = function(reason)
		calls.publish_phase("failed")
		calls.deliver_stop_callbacks(false, reason or "stop-failed")
	end
	calls.activate_initial = function()
		helpers.assert_true(remap.regenerate())
		calls.deliver_ready()
		calls.deliver_resumed()
	end
	return remap, calls
end

local function error_log_contains(calls, needle)
	for _, item in ipairs(calls.logs) do
		if item.level == "error" and item.message:find(needle, 1, true) then return true end
	end
	return false
end

local function sequence_index(sequence, expected)
	for index, value in ipairs(sequence) do
		if value == expected then return index end
	end
	return nil
end

local function reset_layout_observations(calls)
	calls.sequence = {}
	calls.timers = {}
	calls.resolve = 0
	calls.build = 0
	calls.deploy = 0
	calls.classifier_refresh = 0
	calls.rebind = 0
end

return {
	LEASE_TOKENS = LEASE_TOKENS,
	SCREENS_DID_UNLOCK = SCREENS_DID_UNLOCK,
	SYSTEM_DID_WAKE = SYSTEM_DID_WAKE,
	error_log_contains = error_log_contains,
	load_remap = load_remap,
	reset_layout_observations = reset_layout_observations,
	sequence_index = sequence_index,
}
