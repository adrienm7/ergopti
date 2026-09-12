--- tests/support/guardian_recovery_fixture.lua

--- ==============================================================================
--- MODULE: Exact-Lease Automatic Recovery Regression Tests
--- DESCRIPTION:
--- Drives the real remap bridge over token-aware lifecycle doubles. Proves that
--- an unexpected private worker/guardian loss is repaired only after the old
--- generation is fenced, with a fresh token, bounded backoff, current layout,
--- and user pause/disable/shutdown intent taking precedence.
--- ==============================================================================

local helpers = require("tests.helpers")

local TOKENS = {
	"00112233445566778899aabbccddeeff",
	"102132435465768798a9babbdcddedef",
	"2031425364758697a8b9cacbdcedfe0f",
	"30415263748596a7b8c9dadbecfd0e1f",
	"405162738495a6b7c8d9eafbed0e1f2f",
}

local STUB_MODULES = {
	"adapters.file_system",
	"infra.fs_dir",
	"infra.logger",
	"infra.config_paths",
	"infra.timings",
	"platform.remap.defaults",
	"platform.remap.config",
	"platform.remap.generator",
	"platform.remap.ke_lifecycle",
	"platform.remap.ke_variables",
	"platform.remap.lease_controller",
	"platform.remap.onboarding",
	"platform.remap.watchers",
	"adapters.hotkey_registrar",
	"adapters.timer_scheduler",
	"modules.keylogger.kc_bridge",
	"modules.gestures.engine",
	"modules.shortcuts",
	"hs.caffeinate.watcher",
	"hs",
	"tests.stubs.hs",
	"platform.remap",
}

local function index_of(values, expected)
	for index, value in ipairs(values) do
		if value == expected then return index end
	end
	return nil
end

local function assert_delays(calls, expected)
	local actual = {}
	for _, timer in ipairs(calls.recovery_timers) do actual[#actual + 1] = timer.delay end
	helpers.assert_true(helpers.deep_equal(actual, expected),
		"unexpected recovery delays: " .. helpers.inspect(actual))
end

local function has_log(calls, needle)
	for _, entry in ipairs(calls.logs) do
		if entry.message:find(needle, 1, true) then return true end
	end
	return false
end

local function count_logs(calls, level, needle)
	local count = 0
	needle = needle and needle:lower() or nil
	for _, entry in ipairs(calls.logs) do
		local message = tostring(entry.message):lower()
		if entry.level == level and (needle == nil or message:find(needle, 1, true)) then
			count = count + 1
		end
	end
	return count
end

--- Runs one behavior with every process-global mutation restored afterwards.
--- @param options table|nil Harness behavior overrides.
--- @param body function Test body receiving (remap, calls).
local function with_remap(options, body)
	options = options or {}
	local previous_getenv = os.getenv
	local previous_execute = os.execute
	local previous_popen = io.popen
	local previous_hs = _G.hs
	local previous_modules = {}
	for _, name in ipairs(STUB_MODULES) do previous_modules[name] = package.loaded[name] end
	local previous_hs_modules = {}
	for name, value in pairs(package.loaded) do
		if type(name) == "string" and name:match("^hs%.") then
			previous_hs_modules[name] = value
		end
	end

	local calls = {
		phase = options.initial_phase or "active",
		current_token = TOKENS[1],
		token_index = 1,
		order = {},
		logs = {},
		recovery_timers = {},
		guardian_probe_timers = {},
		recovery_timer_arm_attempts = 0,
		recovery_timer_arm_failures_remaining = 0,
		hs_timers = {},
		start_callbacks = {},
		resume_callbacks = {},
		pause_callbacks = {},
		stop_exact_completions = {},
		stop_barrier_callbacks = {},
		failed_start_fence = nil,
		build_tokens = {},
		build_layouts = {},
		deploy_tokens = {},
		layout_revision = "layout-a",
		resolved_revision = "layout-a",
		script_paused = options.paused == true,
		cancel_fails = options.cancel_fails == true,
		cancel_failures_remaining = 0,
		cancel_attempts = 0,
		pause_intent_pending = false,
		hs_timer_failures_remaining = 0,
		pause_query_failures_remaining = 0,
		status_failures_remaining = 0,
		token_failures_remaining = 0,
		resolve_failures_remaining = 0,
		rebind_failures_remaining = 0,
		notify_failures_remaining = 0,
		disable_persist_failures_remaining = options.disable_persist_failures or 0,
		defer_stop_exact = false,
		build_failures_remaining = options.build_failures or 0,
		deploy_failures_remaining = options.deploy_failures or 0,
		classifier_failures_remaining = options.classifier_failures or 0,
		bind_failures_remaining = options.bind_failures or 0,
		builds = 0,
		deploys = 0,
		starts_paused = 0,
		resume_requests = 0,
		consumer_starts = 0,
		consumer_stops = 0,
		classifier_refreshes = 0,
		resolves = 0,
		rebinds = 0,
		hs_timer_attempts = 0,
		saves = 0,
		guardian_probe_count = 0,
		guardian_probe_termination_attempts = 0,
		guardian_probe_terminations = 0,
		guardian_probe_termination_failures_remaining =
			options.guardian_probe_termination_failures or 0,
		guardian_probes = {},
		guardian_probe_statuses = {},
		guardian_cached_status = options.guardian_cached_status or options.guardian_status,
		guardian_settings_opens = 0,
		onboarding_stop_attempts = 0,
		onboarding_stop_failures_remaining = options.onboarding_stop_failures or 0,
		ke_variables_recovery_observer = nil,
	}
	for index, outcome in ipairs(options.guardian_probe_statuses or {}) do
		calls.guardian_probe_statuses[index] = outcome
	end
	local function append(value) calls.order[#calls.order + 1] = value end
	local function publish(phase, token)
		calls.phase = phase
		if calls.phase_listener then calls.phase_listener(phase, token) end
	end

	local ok, err = xpcall(function()
	local logger = helpers.make_logger_stub()
	for _, level in ipairs({ "debug", "info", "warn", "error", "success" }) do
		logger[level] = function(_, message, ...)
			local ok, rendered = pcall(string.format, tostring(message), ...)
			calls.logs[#calls.logs + 1] = {
				level = level,
				message = ok and rendered or tostring(message),
			}
		end
	end
	package.loaded["infra.logger"] = logger
	package.loaded["infra.config_paths"] = {
		get = function() return "tests/unit/platform/remap/guardian-recovery.toml" end,
	}
	package.loaded["infra.timings"] = {
		sec = function(category, key)
			helpers.assert_eq(category, "debounce")
			helpers.assert_eq(key, "layout_tis_settle_ms")
			return 0.5
		end,
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
		save_user_config = function(state)
			calls.saves = calls.saves + 1
			if type(state) == "table" and state.enabled == false
				and calls.disable_persist_failures_remaining > 0 then
				calls.disable_persist_failures_remaining = calls.disable_persist_failures_remaining - 1
				return false
			end
			return true
		end,
		resolve_layout_actions = function()
			calls.resolves = calls.resolves + 1
			if calls.resolve_failures_remaining > 0 then
				calls.resolve_failures_remaining = calls.resolve_failures_remaining - 1
				error("synthetic-layout-resolution-failure")
			end
			calls.resolved_revision = calls.layout_revision
			append("resolve:" .. calls.layout_revision)
			return 1
		end,
	}
	package.loaded["platform.remap.generator"] = {
		build_karabiner_json = function(...)
			local token = select(7, ...)
			calls.builds = calls.builds + 1
			calls.build_tokens[#calls.build_tokens + 1] = token
			calls.build_layouts[#calls.build_layouts + 1] = calls.resolved_revision
			append("build:" .. tostring(token) .. ":" .. calls.resolved_revision)
			if calls.build_failures_remaining > 0 then
				calls.build_failures_remaining = calls.build_failures_remaining - 1
				return nil, "synthetic-build-failure"
			end
			return { recovery_token = token }, nil, {}, {}
		end,
		merge_and_deploy_config = function(generated)
			calls.deploys = calls.deploys + 1
			calls.deploy_tokens[#calls.deploy_tokens + 1] = generated.recovery_token
			append("deploy:" .. tostring(generated.recovery_token))
			if calls.deploy_failures_remaining > 0 then
				calls.deploy_failures_remaining = calls.deploy_failures_remaining - 1
				return false, "synthetic-deploy-failure"
			end
			return true, "ok"
		end,
		KE_PHYSICAL_KC_LOG = nil,
	}
	package.loaded["platform.remap.ke_lifecycle"] = {
		open_gui = function() return true end,
		stop = function() return true end,
		notify_ready = function()
			append("notify-ready")
			if calls.notify_failures_remaining > 0 then
				calls.notify_failures_remaining = calls.notify_failures_remaining - 1
				error("synthetic-ready-notification-failure")
			end
		end,
	}
	package.loaded["platform.remap.ke_variables"] = {
		set_recovery_observer = function(observer)
			helpers.assert_true(type(observer) == "function")
			helpers.assert_nil(calls.ke_variables_recovery_observer)
			calls.ke_variables_recovery_observer = observer
			return true
		end,
		clear_recovery_observer = function(observer)
			helpers.assert_true(observer == calls.ke_variables_recovery_observer)
			calls.ke_variables_recovery_observer = nil
			return true
		end,
	}
	package.loaded["platform.remap.onboarding"] = {
		run_first_run_wizard = function()
			calls.first_run_wizard_runs = (calls.first_run_wizard_runs or 0) + 1
			return true
		end,
		stop = function(on_done)
			calls.onboarding_stop_attempts = calls.onboarding_stop_attempts + 1
			if calls.onboarding_stop_failures_remaining > 0 then
				calls.onboarding_stop_failures_remaining = calls.onboarding_stop_failures_remaining - 1
				if type(on_done) == "function" then
					on_done(false, "synthetic-onboarding-stop-failure")
				end
				return false
			end
			if type(on_done) == "function" then on_done(true, "onboarding-stopped") end
			return true
		end,
	}

	package.loaded["platform.remap.lease_controller"] = {
		init = function(listener)
			calls.phase_listener = listener
			return true
		end,
		status = function()
			if calls.status_failures_remaining > 0 then
				calls.status_failures_remaining = calls.status_failures_remaining - 1
				error("synthetic-lease-status-failure")
			end
			return calls.phase, {
				phase = calls.phase,
				token = calls.current_token,
				activation_blocked = calls.pause_intent_pending,
				guardian_status = calls.guardian_cached_status,
			}
		end,
		token = function()
			if calls.phase == "failed" or calls.phase == "idle" then
				if calls.token_failures_remaining > 0 then
					calls.token_failures_remaining = calls.token_failures_remaining - 1
					return nil
				end
				calls.token_index = calls.token_index + 1
				calls.current_token = TOKENS[calls.token_index]
				append("allocate:" .. tostring(calls.current_token))
				publish("prepared", calls.current_token)
			end
			return calls.current_token
		end,
		start = function() error("automatic recovery must never start ACTIVE directly") end,
		start_paused = function(on_done)
			calls.starts_paused = calls.starts_paused + 1
			append("start-paused:" .. tostring(calls.current_token))
			publish("starting", calls.current_token)
			calls.start_callbacks[#calls.start_callbacks + 1] = {
				token = calls.current_token,
				callback = on_done,
			}
			return true
		end,
		resume_prepared = function(token, on_done)
			helpers.assert_eq(token, calls.current_token)
			calls.resume_requests = calls.resume_requests + 1
			append("resume:" .. token)
			publish("resuming", token)
			calls.resume_callbacks[#calls.resume_callbacks + 1] = {
				token = token,
				callback = on_done,
			}
			return true
		end,
		resume = function(on_done)
			local token = calls.current_token
			calls.resume_requests = calls.resume_requests + 1
			append("resume:" .. token)
			publish("resuming", token)
			calls.resume_callbacks[#calls.resume_callbacks + 1] = {
				token = token,
				callback = on_done,
			}
			return true
		end,
		pause = function(on_done)
			if calls.phase == "starting" then
				calls.pause_intent_pending = true
				calls.pause_callbacks[#calls.pause_callbacks + 1] = on_done
				return true
			end
			if calls.phase ~= "active" and calls.phase ~= "paused" then
				if on_done then on_done(false, "invalid-phase") end
				return false
			end
			publish("paused", calls.current_token)
			if on_done then on_done(true, "paused") end
			return true
		end,
		stop_exact = function(token)
			helpers.assert_eq(token, calls.current_token)
			if calls.phase == "stopping" then return true end
			append("stop-exact:" .. token)
			publish("stopping", token)
			local pending_resume = table.remove(calls.resume_callbacks, 1)
			if pending_resume then pending_resume.callback(false, "lease-stopping") end
			if calls.defer_stop_exact then
				calls.stop_exact_completions[#calls.stop_exact_completions + 1] = token
				return true
			end
			calls.current_token = nil
			publish("idle", nil)
			return true
		end,
		stop = function(_reason, on_done)
			if (calls.phase == "stopping" or calls.phase == "fencing")
				and (#calls.stop_exact_completions > 0 or calls.failed_start_fence ~= nil) then
				calls.stop_barrier_callbacks[#calls.stop_barrier_callbacks + 1] = on_done
				return true
			end
			local stopped_token = calls.current_token
			publish("stopping", stopped_token)
			calls.current_token = nil
			publish("idle", nil)
			if on_done then on_done(true, "stopped") end
			return true
		end,
		refresh_liveness = function() return true end,
		probe_guardian_status = function(on_done)
			calls.guardian_probe_count = calls.guardian_probe_count + 1
			local probe = {
				callback = on_done,
				deliveries = 0,
				invalidated = false,
				terminated = false,
			}
			probe.terminate = function()
				probe.invalidated = true
				if probe.terminated then return true end
				calls.guardian_probe_termination_attempts =
					calls.guardian_probe_termination_attempts + 1
				if calls.guardian_probe_termination_failures_remaining > 0 then
					calls.guardian_probe_termination_failures_remaining =
						calls.guardian_probe_termination_failures_remaining - 1
					return false
				end
				probe.terminated = true
				calls.guardian_probe_terminations = calls.guardian_probe_terminations + 1
				return true
			end
			calls.guardian_probes[#calls.guardian_probes + 1] = probe

			if (options.guardian_probe_start_failures or 0) >= calls.guardian_probe_count then
				return nil, "synthetic-guardian-probe-start-failure"
			end

			local outcome = table.remove(calls.guardian_probe_statuses, 1)
			if outcome == nil then outcome = options.guardian_probe_default_status or "ready" end
			local deferred = options.guardian_probe_deferred == true
			if type(outcome) == "table" and outcome.deferred ~= nil then
				deferred = outcome.deferred == true
			end
			probe.outcome = outcome
			if not deferred then
				probe.deliveries = probe.deliveries + 1
				if type(outcome) == "table" then
					if type(outcome.status) == "string" then
						calls.guardian_cached_status = outcome.status
					end
					on_done(outcome.status, outcome.error)
				else
					calls.guardian_cached_status = outcome
					on_done(outcome, nil)
				end
			end
			return probe
		end,
		open_guardian_settings = function(on_done)
			calls.guardian_settings_opens = calls.guardian_settings_opens + 1
			if on_done then on_done(true, "opened") end
			return true
		end,
	}

	local function make_handle(kind)
		return { kind = kind, enabled = true }
	end
	package.loaded["platform.remap.watchers"] = {
		start_gesture_watcher = function()
			if calls.bind_failures_remaining > 0 then
				calls.bind_failures_remaining = calls.bind_failures_remaining - 1
				return nil
			end
			calls.consumer_starts = calls.consumer_starts + 1
			append("consumer:gesture")
			return make_handle("gesture")
		end,
		stop_gesture_watcher = function(handle)
			if handle then handle.enabled = false end
			calls.consumer_stops = calls.consumer_stops + 1
			return true
		end,
		start_cycle_windows_hotkey = function()
			append("consumer:cycle")
			return make_handle("cycle")
		end,
		start_alt_tab_windows_hotkey = function()
			append("consumer:windows")
			return make_handle("windows")
		end,
		start_alt_tab_monitor_hotkey = function()
			append("consumer:monitor")
			return make_handle("monitor")
		end,
		start_alt_tab_apps_hotkey = function()
			append("consumer:apps")
			return make_handle("apps")
		end,
		stop_alt_tab_apps_tracker = function() return true end,
		start_input_source_watcher = function(callback)
			calls.input_source_callback = callback
			return true
		end,
		stop_input_source_watcher = function() return true end,
	}
	package.loaded["adapters.hotkey_registrar"] = {
		unbind = function(handle)
			if handle then handle.enabled = false end
			return true
		end,
	}
	package.loaded["modules.keylogger.kc_bridge"] = {
		clear_managed_set = function() return true end,
		refresh_managed_set = function()
			calls.classifier_refreshes = calls.classifier_refreshes + 1
			append("classifier")
			if calls.classifier_failures_remaining > 0 then
				calls.classifier_failures_remaining = calls.classifier_failures_remaining - 1
				return false
			end
			return true
		end,
	}
	package.loaded["modules.gestures.engine"] = {}
	local shortcuts_stub = {
		is_paused = function()
			if calls.pause_query_failures_remaining > 0 then
				calls.pause_query_failures_remaining = calls.pause_query_failures_remaining - 1
				error("synthetic-pause-query-failure")
			end
			return calls.script_paused
		end,
		rebind_for_layout = function()
			calls.rebinds = calls.rebinds + 1
			append("rebind")
			if calls.rebind_failures_remaining > 0 then
				calls.rebind_failures_remaining = calls.rebind_failures_remaining - 1
				error("synthetic-layout-rebind-failure")
			end
			return true
		end,
	}
	calls.shortcuts = shortcuts_stub
	package.loaded["modules.shortcuts"] = shortcuts_stub
	package.loaded["hs.caffeinate.watcher"] = {
		systemDidWake = 7,
		screensDidUnlock = 8,
		new = function()
			return {
				start = function(self) return self end,
				stop = function() return true end,
			}
		end,
	}

	local remap_initialized = false
	local timer_scheduler = {}
	function timer_scheduler.after(delay, callback)
		if remap_initialized then
			calls.recovery_timer_arm_attempts = calls.recovery_timer_arm_attempts + 1
		end
		if remap_initialized and calls.recovery_timer_arm_failures_remaining > 0 then
			calls.recovery_timer_arm_failures_remaining =
				calls.recovery_timer_arm_failures_remaining - 1
			return { fired = true }, false
		end
		local timer = {
			committed = true,
			delay = delay,
			callback = callback,
			fired = false,
			running = true,
			timer = {},
		}
		function timer:fire(force)
			if (not self.running or self.fired) and force ~= true then return false end
			self.fired = true
			self.committed = false
			timer_scheduler.cancel(self)
			self.callback()
			return true
		end
		if remap_initialized then
			local timers = delay == 2.0 and calls.guardian_probe_timers or calls.recovery_timers
			timers[#timers + 1] = timer
		else
			calls.first_run_timers = calls.first_run_timers or {}
			calls.first_run_timers[#calls.first_run_timers + 1] = timer
		end
		return timer, true
	end
	function timer_scheduler.cancel(timer)
		if not timer or timer.timer == nil then return true end
		calls.cancel_attempts = calls.cancel_attempts + 1
		timer.committed = false
		if calls.cancel_failures_remaining > 0 then
			calls.cancel_failures_remaining = calls.cancel_failures_remaining - 1
			return false
		end
		if calls.cancel_fails then return false end
		timer.running = false
		timer.fired = true
		timer.timer = nil
		return true
	end
	package.loaded["adapters.timer_scheduler"] = timer_scheduler

	os.getenv = function(name)
		if name == "ERGOPTI_REMAP_GUARDIAN_STATUS" then
			return options.guardian_status
		end
		return previous_getenv(name)
	end
	os.execute = function() error("remap recovery must not invoke os.execute") end
	io.popen = function() error("remap recovery must not spawn a process") end

	local hs_overrides = {
		execute = function() error("remap recovery must not inspect or signal stock Karabiner") end,
		keycodes = {
			inputSourceChanged = function() end,
			currentLayout = function() return calls.layout_revision end,
			map = { f17 = 64 },
		},
		timer = {
			doAfter = function(delay, callback)
				calls.hs_timer_attempts = calls.hs_timer_attempts + 1
				if calls.hs_timer_failures_remaining > 0 then
					calls.hs_timer_failures_remaining = calls.hs_timer_failures_remaining - 1
					error("synthetic-hs-timer-arm-failure")
				end
				local timer = { delay = delay, callback = callback, running = true }
				function timer:stop()
					self.running = false
					return self
				end
				function timer:fire(force)
					if not self.running and force ~= true then return false end
					self.running = false
					self.callback()
					return true
				end
				calls.hs_timers[#calls.hs_timers + 1] = timer
				return timer
			end,
			doEvery = function() return { stop = function() return true end } end,
			secondsSinceEpoch = function() return 1000 end,
			absoluteTime = function() return 0 end,
			usleep = function() end,
		},
	}
	package.loaded["hs"] = nil
	package.loaded["tests.stubs.hs"] = nil
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	for key, value in pairs(hs_overrides) do hs_stub[key] = value end
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	package.loaded["platform.remap"] = nil
	package.loaded["adapters.file_system"] = nil
	package.loaded["infra.fs_dir"] = nil
	local remap = require("platform.remap")
	remap.init({ expand_path = function(path) return path end })
	local scenario_cancel_fails = calls.cancel_fails
	local scenario_cancel_failures_remaining = calls.cancel_failures_remaining
	calls.cancel_fails = false
	calls.cancel_failures_remaining = 0
	for _, timer in ipairs(calls.first_run_timers or {}) do timer:fire() end
	calls.cancel_attempts = 0
	calls.cancel_fails = scenario_cancel_fails
	calls.cancel_failures_remaining = scenario_cancel_failures_remaining
	remap_initialized = true

	calls.publish_phase = publish
	function calls.publish_failed(token)
		token = token or calls.current_token
		calls.current_token = nil
		publish("failed", token)
	end
	function calls.fail_start(reason, after_failed_listener)
		local pending = table.remove(calls.start_callbacks, 1)
		helpers.assert_true(type(pending) == "table", "no retained start callback to fail")
		publish("fencing", pending.token)
		calls.current_token = nil
		publish("failed", pending.token)
		if after_failed_listener then after_failed_listener() end
		pending.callback(false, reason or "worker-lost")
	end
	function calls.begin_start_failure_fence(reason)
		local pending = table.remove(calls.start_callbacks, 1)
		helpers.assert_true(type(pending) == "table", "no retained start callback to fence")
		calls.failed_start_fence = {
			pending = pending,
			reason = reason or "worker-lost",
		}
		publish("fencing", pending.token)
	end
	function calls.complete_start_failure_fence()
		local failure = calls.failed_start_fence
		helpers.assert_true(type(failure) == "table", "no retained start fence to complete")
		calls.failed_start_fence = nil
		calls.current_token = nil
		publish("failed", failure.pending.token)
		failure.pending.callback(false, failure.reason)
		local callbacks = calls.stop_barrier_callbacks
		calls.stop_barrier_callbacks = {}
		for _, callback in ipairs(callbacks) do
			if callback then callback(true, failure.reason) end
		end
	end
	function calls.complete_stop_exact()
		local token = table.remove(calls.stop_exact_completions, 1)
		helpers.assert_true(type(token) == "string", "no retained exact STOP to complete")
		helpers.assert_eq(calls.current_token, token)
		calls.current_token = nil
		publish("idle", nil)
		local callbacks = calls.stop_barrier_callbacks
		calls.stop_barrier_callbacks = {}
		for _, callback in ipairs(callbacks) do
			if callback then callback(true, "stopped") end
		end
	end
	function calls.deliver_ready()
		local pending = table.remove(calls.start_callbacks, 1)
		helpers.assert_true(type(pending) == "table", "no retained start callback to complete")
		calls.current_token = pending.token
		publish("paused", pending.token)
		append("ready:" .. pending.token)
		pending.callback(true, "ready-paused")
		for _, callback in ipairs(calls.pause_callbacks) do
			if callback then callback(true, "paused") end
		end
		calls.pause_callbacks = {}
		calls.pause_intent_pending = false
	end
	function calls.deliver_resumed()
		local pending = table.remove(calls.resume_callbacks, 1)
		helpers.assert_true(type(pending) == "table", "no retained resume callback to complete")
		calls.current_token = pending.token
		publish("active", pending.token)
		append("active:" .. pending.token)
		pending.callback(true, "resumed")
	end
	function calls.latest_layout_timer()
		for index = #calls.hs_timers, 1, -1 do
			if calls.hs_timers[index].delay ~= 2.0 then return calls.hs_timers[index] end
		end
		return nil
	end
	function calls.deliver_guardian_probe(status, err, index)
		local probe = calls.guardian_probes[index or #calls.guardian_probes]
		helpers.assert_true(type(probe) == "table", "no retained guardian probe to complete")
		probe.deliveries = probe.deliveries + 1
		if type(status) == "string" and probe.invalidated ~= true then
			calls.guardian_cached_status = status
		end
		probe.callback(status, err)
	end
	body(remap, calls)
	end, debug.traceback)

	os.getenv = previous_getenv
	os.execute = previous_execute
	io.popen = previous_popen
	_G.hs = previous_hs
	for name in pairs(package.loaded) do
		if type(name) == "string" and name:match("^hs%.") then package.loaded[name] = nil end
	end
	for name, value in pairs(previous_hs_modules) do package.loaded[name] = value end
	for _, name in ipairs(STUB_MODULES) do package.loaded[name] = previous_modules[name] end
	if not ok then error(err, 0) end
end


return {
	TOKENS = TOKENS,
	index_of = index_of,
	assert_delays = assert_delays,
	has_log = has_log,
	count_logs = count_logs,
	with_remap = with_remap,
}
