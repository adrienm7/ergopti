--- tests/unit/platform/remap/test_guardian_auto_recovery.lua

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
	"infra.logger",
	"infra.config_paths",
	"infra.timings",
	"platform.remap.defaults",
	"platform.remap.config",
	"platform.remap.generator",
	"platform.remap.ke_lifecycle",
	"platform.remap.lease_controller",
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
	}
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
				enabled = true,
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

	local timer_scheduler = {}
	function timer_scheduler.after(delay, callback)
		calls.recovery_timer_arm_attempts = calls.recovery_timer_arm_attempts + 1
		if calls.recovery_timer_arm_failures_remaining > 0 then
			calls.recovery_timer_arm_failures_remaining =
				calls.recovery_timer_arm_failures_remaining - 1
			return { fired = true }
		end
		local timer = {
			delay = delay,
			callback = callback,
			fired = false,
			running = true,
		}
		function timer:fire(force)
			if (not self.running or self.fired) and force ~= true then return false end
			self.running = false
			self.fired = true
			self.callback()
			return true
		end
		calls.recovery_timers[#calls.recovery_timers + 1] = timer
		return timer
	end
	function timer_scheduler.cancel(timer)
		calls.cancel_attempts = calls.cancel_attempts + 1
		if calls.cancel_failures_remaining > 0 then
			calls.cancel_failures_remaining = calls.cancel_failures_remaining - 1
			return false
		end
		if calls.cancel_fails then return false end
		if not timer then return true end
		timer.running = false
		timer.fired = true
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
	local remap = require("platform.remap")
	remap.init({
		expand_path = function(path) return path end,
		read = function() return nil end,
	})

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





-- ================================================
-- ================================================
-- ======= 1/ Fresh Generation and Ordering =======
-- ================================================
-- ================================================

helpers.describe("Karabiner guardian-loss automatic recovery", function()
	helpers.it("waits for exact FAILED publication before arming recovery", function()
		with_remap({ guardian_status = "ready" }, function(_, calls)
			calls.publish_phase("fencing", TOKENS[1])
			helpers.assert_eq(#calls.recovery_timers, 0)
			helpers.assert_eq(calls.builds, 0)
			calls.publish_failed(TOKENS[1])
			assert_delays(calls, { 1.0 })
		end)
	end)

	helpers.it("coalesces FAILED and activates one freshly deployed token", function()
		with_remap({ guardian_status = "ready" }, function(_, calls)
			calls.publish_failed(TOKENS[1])
			calls.publish_failed(TOKENS[1])
			assert_delays(calls, { 1.0 })

			calls.recovery_timers[1]:fire()
			helpers.assert_eq(calls.build_tokens[1], TOKENS[2])
			helpers.assert_eq(calls.deploy_tokens[1], TOKENS[2])
			helpers.assert_true(TOKENS[2] ~= TOKENS[1])
			helpers.assert_eq(calls.starts_paused, 1)
			helpers.assert_eq(calls.resume_requests, 0)

			local allocate_at = index_of(calls.order, "allocate:" .. TOKENS[2])
			local build_at = index_of(calls.order, "build:" .. TOKENS[2] .. ":layout-a")
			local deploy_at = index_of(calls.order, "deploy:" .. TOKENS[2])
			local start_at = index_of(calls.order, "start-paused:" .. TOKENS[2])
			helpers.assert_true(allocate_at < build_at and build_at < deploy_at and deploy_at < start_at,
				"the fresh token must gate the exact config before its PAUSED worker starts")

			calls.deliver_ready()
			helpers.assert_eq(calls.consumer_starts, 1)
			helpers.assert_eq(calls.classifier_refreshes, 1)
			helpers.assert_eq(calls.resume_requests, 1)
			local classifier_at = index_of(calls.order, "classifier")
			local resume_at = index_of(calls.order, "resume:" .. TOKENS[2])
			helpers.assert_true(classifier_at < resume_at,
				"all local consumers and classification must precede RESUME")
			calls.deliver_resumed()

			calls.publish_failed(TOKENS[2])
			assert_delays(calls, { 1.0, 1.0 })
		end)
	end)

	helpers.it("retries a transient recovery timer-arm failure without consuming backoff", function()
		with_remap({ guardian_status = "ready" }, function(_, calls)
			calls.recovery_timer_arm_failures_remaining = 1
			calls.publish_failed(TOKENS[1])
			helpers.assert_eq(calls.recovery_timer_arm_attempts, 2)
			assert_delays(calls, { 1.0 })

			calls.recovery_timers[1]:fire()
			helpers.assert_eq(calls.build_tokens[1], TOKENS[2])
			calls.deliver_ready()
			calls.deliver_resumed()
			helpers.assert_eq(calls.phase, "active")
		end)
	end)

	for _, failure in ipairs({
		{
			label = "pause-state query",
			inject = function(calls) calls.pause_query_failures_remaining = 1 end,
		},
		{
			label = "lease-status query",
			inject = function(calls) calls.status_failures_remaining = 1 end,
		},
		{
			label = "token allocation",
			inject = function(calls) calls.token_failures_remaining = 1 end,
		},
	}) do
		helpers.it("retries after a transient recovery " .. failure.label .. " failure", function()
			with_remap({ guardian_status = "ready" }, function(_, calls)
				calls.publish_failed(TOKENS[1])
				failure.inject(calls)
				calls.recovery_timers[1]:fire()
				helpers.assert_eq(calls.builds, 0,
					"unknown pause/status/token state must not reach config generation")
				assert_delays(calls, { 1.0, 10.0 })

				calls.recovery_timers[2]:fire()
				helpers.assert_eq(calls.build_tokens[1], TOKENS[2])
				calls.deliver_ready()
				calls.deliver_resumed()
				helpers.assert_eq(calls.phase, "active")
			end)
		end)
	end

	helpers.it("retains recovery until the ACTIVE callback proves the exact token", function()
		with_remap({ guardian_status = "ready" }, function(_, calls)
			calls.publish_failed(TOKENS[1])
			calls.recovery_timers[1]:fire()
			calls.deliver_ready()
			calls.status_failures_remaining = 1
			calls.deliver_resumed()

			helpers.assert_eq(calls.phase, "idle",
				"an unprovable ACTIVE callback must fence its exact generation")
			assert_delays(calls, { 1.0, 10.0 })
			calls.recovery_timers[2]:fire()
			helpers.assert_eq(calls.build_tokens[2], TOKENS[3])
			calls.deliver_ready()
			calls.deliver_resumed()
			helpers.assert_eq(calls.phase, "active")
		end)
	end)

	helpers.it("retains an owned-token retry through a manual activation callback", function()
		with_remap({ guardian_status = "ready" }, function(remap, calls)
			calls.publish_failed(TOKENS[1])
			calls.build_failures_remaining = 1
			calls.recovery_timers[1]:fire()
			helpers.assert_eq(calls.phase, "prepared")
			assert_delays(calls, { 1.0, 10.0 })

			helpers.assert_true(remap.regenerate())
			calls.deliver_ready()
			calls.status_failures_remaining = 1
			calls.deliver_resumed()
			helpers.assert_eq(calls.phase, "idle")
			calls.recovery_timers[2]:fire()
			helpers.assert_eq(calls.build_tokens[3], TOKENS[3])
		end)
	end)

	helpers.it("starts a new series after exhausted owned-token manual recovery is lost", function()
		with_remap({ guardian_status = "ready", build_failures = 3 }, function(remap, calls)
			calls.publish_failed(TOKENS[1])
			for attempt = 1, 3 do calls.recovery_timers[attempt]:fire() end
			helpers.assert_eq(calls.phase, "prepared")
			helpers.assert_true(helpers.deep_equal(calls.build_tokens, {
				TOKENS[2], TOKENS[2], TOKENS[2],
			}), "all exhausted pre-publication attempts must retain the exact owned token")
			assert_delays(calls, { 1.0, 10.0, 30.0 })

			helpers.assert_true(remap.regenerate())
			calls.deliver_ready()
			calls.deliver_resumed()
			helpers.assert_eq(calls.phase, "active")
			calls.publish_failed(TOKENS[2])

			assert_delays(calls, { 1.0, 10.0, 30.0, 1.0 })
		end)
	end)

	helpers.it("settles recovery even when the ACTIVE notification raises", function()
		with_remap({ guardian_status = "ready" }, function(_, calls)
			calls.publish_failed(TOKENS[1])
			calls.recovery_timers[1]:fire()
			calls.deliver_ready()
			calls.notify_failures_remaining = 1
			calls.deliver_resumed()
			helpers.assert_eq(calls.phase, "active")
			helpers.assert_true(has_log(calls, "synthetic-ready-notification-failure"))

			calls.publish_failed(TOKENS[2])
			assert_delays(calls, { 1.0, 1.0 })
		end)
	end)

	helpers.it("uses exactly 1, 10, and 30 seconds across replacement-token failures", function()
		with_remap({ guardian_status = "ready" }, function(_, calls)
			calls.publish_failed(TOKENS[1])
			for attempt = 1, 3 do
				calls.recovery_timers[attempt]:fire()
				helpers.assert_eq(calls.build_tokens[attempt], TOKENS[attempt + 1])
				calls.fail_start("synthetic-worker-loss-" .. attempt)
			end
			assert_delays(calls, { 1.0, 10.0, 30.0 })
			helpers.assert_eq(calls.builds, 3)
			helpers.assert_eq(calls.starts_paused, 3)
			calls.publish_failed(TOKENS[4])
			helpers.assert_eq(#calls.recovery_timers, 3,
				"an exhausted series must not restart from a duplicate/new failed token")
			helpers.assert_eq(calls.builds, 3, "there must be no fourth automatic attempt")
		end)
	end)

	helpers.it("retries the exact owned PREPARED token after a transient build failure", function()
		with_remap({ guardian_status = "ready", build_failures = 1 }, function(_, calls)
			calls.publish_failed(TOKENS[1])
			calls.recovery_timers[1]:fire()
			helpers.assert_eq(calls.phase, "prepared")
			helpers.assert_eq(calls.build_tokens[1], TOKENS[2])
			assert_delays(calls, { 1.0, 10.0 })

			calls.recovery_timers[2]:fire()
			helpers.assert_eq(calls.build_tokens[2], TOKENS[2],
				"a safe PREPARED token is retried instead of discarded or confused with a manual token")
			helpers.assert_eq(calls.starts_paused, 1)
			calls.deliver_ready()
			calls.deliver_resumed()
		end)
	end)

	for _, failure in ipairs({
		{ label = "deploy", option = "deploy_failures", phase = "prepared" },
		{ label = "input bind", option = "bind_failures", phase = "idle" },
		{ label = "classifier", option = "classifier_failures", phase = "idle" },
	}) do
		helpers.it("continues after a transient " .. failure.label .. " failure", function()
			local options = { guardian_status = "ready" }
			options[failure.option] = 1
			with_remap(options, function(_, calls)
				calls.publish_failed(TOKENS[1])
				calls.recovery_timers[1]:fire()
				if failure.label ~= "deploy" then calls.deliver_ready() end
				helpers.assert_eq(calls.phase, failure.phase,
					"the harness must model the production terminal phase for this failure stage")
				assert_delays(calls, { 1.0, 10.0 })
				calls.recovery_timers[2]:fire()
				local expected_token = failure.label == "deploy" and TOKENS[2] or TOKENS[3]
				helpers.assert_eq(calls.build_tokens[2], expected_token)
				helpers.assert_eq(calls.starts_paused, failure.label == "deploy" and 1 or 2)
				calls.deliver_ready()
				calls.deliver_resumed()
				helpers.assert_eq(calls.phase, "active")
			end)
		end)
	end

	helpers.it("refunds a retry that fires while the exact failure fence is pending", function()
		with_remap({ guardian_status = "ready" }, function(_, calls)
			calls.publish_failed(TOKENS[1])
			calls.recovery_timers[1]:fire()
			calls.defer_stop_exact = true
			calls.bind_failures_remaining = 1
			calls.deliver_ready()
			helpers.assert_eq(calls.phase, "stopping")
			assert_delays(calls, { 1.0, 10.0 })

			calls.recovery_timers[2]:fire()
			helpers.assert_eq(calls.builds, 1,
				"a retry must not allocate or build while the old token is still retiring")
			calls.complete_stop_exact()
			assert_delays(calls, { 1.0, 10.0, 10.0 })
			calls.recovery_timers[3]:fire()
			helpers.assert_eq(calls.build_tokens[2], TOKENS[3])
			calls.deliver_ready()
			calls.deliver_resumed()
			helpers.assert_eq(calls.phase, "active")
		end)
	end)
end)





-- ==============================================
-- ==============================================
-- ======= 2/ User Intent Wins Every Race =======
-- ==============================================
-- ==============================================

helpers.describe("Karabiner recovery user-intent fencing", function()
	helpers.it("keeps a cancelled queued callback inert and resumes with a fresh token", function()
		with_remap({ guardian_status = "ready", cancel_fails = true }, function(remap, calls)
			calls.publish_failed(TOKENS[1])
			local stale_timer = calls.recovery_timers[1]
			local pause_committed = false
			helpers.assert_true(remap.pause(function(ok)
				pause_committed = ok == true
				if ok == true then calls.script_paused = true end
			end))
			helpers.assert_true(pause_committed,
				"a no-live-lease PAUSE must commit the caller's local fail-closed state")
			helpers.assert_true(calls.cancel_attempts > 0)
			stale_timer:fire(true)
			helpers.assert_eq(calls.builds, 0)
			helpers.assert_eq(calls.deploys, 0)
			helpers.assert_eq(calls.starts_paused, 0)

			calls.cancel_fails = false
			helpers.assert_true(remap.resume())
			helpers.assert_eq(calls.build_tokens[1], TOKENS[2])
			calls.deliver_ready()
			helpers.assert_eq(calls.resume_requests, 1)
			calls.deliver_resumed()
		end)
	end)

	helpers.it("does not arm automatic work when FAILED arrives under pause", function()
		with_remap({ guardian_status = "ready", paused = true }, function(remap, calls)
			calls.publish_failed(TOKENS[1])
			helpers.assert_eq(#calls.recovery_timers, 0)
			helpers.assert_eq(calls.builds, 0)
			helpers.assert_true(remap.resume())
			helpers.assert_eq(calls.build_tokens[1], TOKENS[2])
		end)
	end)

	helpers.it("never sends RESUME when pause wins after the recovery worker starts", function()
		with_remap({ guardian_status = "ready" }, function(remap, calls)
			calls.publish_failed(TOKENS[1])
			calls.recovery_timers[1]:fire()
			helpers.assert_eq(calls.phase, "starting")
			helpers.assert_true(remap.pause())
			calls.deliver_ready()
			helpers.assert_eq(calls.phase, "paused")
			helpers.assert_eq(calls.resume_requests, 0,
				"the queued user pause must defeat automatic activation after READY")
			helpers.assert_eq(#calls.resume_callbacks, 0)
		end)
	end)

	helpers.it("commits Pause only after an in-flight recovery fence settles", function()
		with_remap({ guardian_status = "ready" }, function(remap, calls)
			calls.publish_failed(TOKENS[1])
			calls.recovery_timers[1]:fire()
			calls.defer_stop_exact = true
			calls.bind_failures_remaining = 1
			calls.deliver_ready()
			helpers.assert_eq(calls.phase, "stopping")
			helpers.assert_eq(#calls.recovery_timers, 2)
			local stale_retry = calls.recovery_timers[2]

			local pause_results = {}
			helpers.assert_true(remap.pause(function(ok, reason)
				pause_results[#pause_results + 1] = { ok = ok, reason = reason }
				if ok then calls.script_paused = true end
			end))
			helpers.assert_eq(#pause_results, 0,
				"Pause must not publish while retiring rules may still emit")
			stale_retry:fire(true)
			helpers.assert_eq(calls.builds, 1,
				"the cancelled recovery timer must stay inert during the fence")

			calls.complete_stop_exact()
			helpers.assert_eq(#pause_results, 1)
			helpers.assert_eq(pause_results[1].ok, true)
			helpers.assert_eq(pause_results[1].reason, "already-fail-closed")
			helpers.assert_true(calls.script_paused)
			helpers.assert_eq(calls.phase, "idle")
			helpers.assert_eq(#calls.recovery_timers, 2,
				"settling the joined fence must not resurrect automatic recovery")
		end)
	end)

	helpers.it("cancels FAILED recovery published before a joined Pause callback", function()
		with_remap({ guardian_status = "ready" }, function(remap, calls)
			calls.publish_failed(TOKENS[1])
			calls.recovery_timers[1]:fire()
			calls.begin_start_failure_fence("synthetic-worker-loss")
			helpers.assert_eq(calls.phase, "fencing")

			local pause_results = {}
			helpers.assert_true(remap.pause(function(ok, reason)
				pause_results[#pause_results + 1] = { ok = ok, reason = reason }
				if ok then calls.script_paused = true end
			end))
			helpers.assert_eq(#pause_results, 0)
			calls.complete_start_failure_fence()

			helpers.assert_eq(#pause_results, 1)
			helpers.assert_eq(pause_results[1].ok, true)
			helpers.assert_true(calls.script_paused)
			-- Pause detached the original bounded series before the exact fence
			-- published FAILED. That publication may briefly create a fresh 1 s
			-- series, but the joined stop barrier must cancel it before returning.
			assert_delays(calls, { 1.0, 1.0 })
			helpers.assert_true(calls.cancel_attempts > 0)
			local stale_retry = calls.recovery_timers[2]
			stale_retry:fire(true)
			helpers.assert_eq(calls.builds, 1,
				"the FAILED listener's pre-callback retry must be cancelled after Pause commits")
		end)
	end)

	helpers.it("lets a committed disable defeat a timer whose native stop failed", function()
		with_remap({ guardian_status = "ready", cancel_fails = true }, function(remap, calls)
			calls.publish_failed(TOKENS[1])
			local stale_timer = calls.recovery_timers[1]
			helpers.assert_true(remap.set_enabled(false))
			helpers.assert_true(remap.get_enabled() == false)
			helpers.assert_true(calls.cancel_attempts > 0)
			stale_timer:fire(true)
			helpers.assert_eq(calls.builds, 0)
			helpers.assert_eq(calls.deploys, 0)
		end)
	end)

	helpers.it("makes Disable authoritative while a recovery fence is still pending", function()
		with_remap({ guardian_status = "ready", cancel_fails = true }, function(remap, calls)
			calls.publish_failed(TOKENS[1])
			calls.recovery_timers[1]:fire()
			calls.defer_stop_exact = true
			calls.bind_failures_remaining = 1
			calls.deliver_ready()
			helpers.assert_eq(calls.phase, "stopping")
			local stale_retry = calls.recovery_timers[2]

			local disable_results = {}
			helpers.assert_true(remap.set_enabled(false, function(ok, reason)
				disable_results[#disable_results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_true(remap.get_enabled(),
				"the preference cannot commit before the exact STOP barrier")
			stale_retry:fire(true)
			helpers.assert_eq(calls.builds, 1)
			helpers.assert_eq(calls.deploys, 1)
			helpers.assert_eq(calls.starts_paused, 1)

			calls.complete_stop_exact()
			helpers.assert_true(remap.get_enabled() == false)
			helpers.assert_eq(#disable_results, 1)
			helpers.assert_eq(disable_results[1].ok, true)
			helpers.assert_eq(#calls.recovery_timers, 2)
		end)
	end)

	helpers.it("epoch-fences a queued timer as soon as revocation is requested", function()
		with_remap({ guardian_status = "ready", cancel_fails = true }, function(remap, calls)
			calls.publish_failed(TOKENS[1])
			local stale_timer = calls.recovery_timers[1]
			helpers.assert_true(remap.revoke("test-shutdown"))
			helpers.assert_true(calls.cancel_attempts > 0)
			stale_timer:fire(true)
			helpers.assert_eq(calls.builds, 0)
			helpers.assert_eq(calls.deploys, 0)
		end)
	end)

	helpers.it("retains failed timer cancellation until local teardown proves cleanup", function()
		with_remap({ guardian_status = "ready" }, function(remap, calls)
			calls.publish_failed(TOKENS[1])
			calls.cancel_failures_remaining = 2
			helpers.assert_true(remap.revoke("test-shutdown"))
			helpers.assert_eq(calls.cancel_attempts, 1)
			helpers.assert_true(remap.teardown_local() == false,
				"teardown must not claim success while a native timer remains unproven")
			helpers.assert_eq(calls.cancel_attempts, 2)
			helpers.assert_true(remap.teardown_local())
			helpers.assert_eq(calls.cancel_attempts, 3)
		end)
	end)

	helpers.it("replays a worker loss hidden by a failed Disable rollback", function()
		with_remap({ guardian_status = "ready", disable_persist_failures = 1 }, function(remap, calls)
			local disable_results = {}
			helpers.assert_true(remap.set_enabled(false, function(ok, reason)
				disable_results[#disable_results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_true(remap.get_enabled())
			helpers.assert_eq(calls.build_tokens[1], TOKENS[2])
			helpers.assert_eq(calls.deploy_tokens[1], TOKENS[2])
			helpers.assert_eq(calls.starts_paused, 1)

			calls.fail_start("rollback-worker-lost", function()
				helpers.assert_eq(calls.phase, "failed")
				helpers.assert_eq(calls.current_token, nil)
				helpers.assert_eq(#disable_results, 0,
					"FAILED is published before the rollback transaction releases its gate")
				helpers.assert_eq(#calls.recovery_timers, 0,
					"the phase listener must not bypass an enabled-state transaction")
			end)

			helpers.assert_eq(#disable_results, 1)
			helpers.assert_eq(disable_results[1].ok, false)
			helpers.assert_eq(disable_results[1].reason, "persistence-failed-after-STOPPED")
			assert_delays(calls, { 1.0 })
			calls.recovery_timers[1]:fire()
			helpers.assert_true(helpers.deep_equal(calls.build_tokens, { TOKENS[2], TOKENS[3] }))
			helpers.assert_true(helpers.deep_equal(calls.deploy_tokens, { TOKENS[2], TOKENS[3] }))
			helpers.assert_eq(calls.starts_paused, 2)
			helpers.assert_eq(calls.resume_requests, 0)

			calls.deliver_ready()
			local ready_index = index_of(calls.order, "ready:" .. TOKENS[3])
			local consumer_index = index_of(calls.order, "consumer:gesture")
			local classifier_index = index_of(calls.order, "classifier")
			local resume_index = index_of(calls.order, "resume:" .. TOKENS[3])
			helpers.assert_true(ready_index < consumer_index and consumer_index < classifier_index
				and classifier_index < resume_index)
			calls.deliver_resumed()
			helpers.assert_eq(calls.phase, "active")
			helpers.assert_eq(#disable_results, 1)
		end)
	end)

	for _, failure in ipairs({
		{ label = "input bind", field = "bind_failures_remaining" },
		{ label = "classifier", field = "classifier_failures_remaining" },
	}) do
		helpers.it("waits for an exact fence after failed Disable rollback " .. failure.label,
			function()
				with_remap({ guardian_status = "ready", disable_persist_failures = 1 },
					function(remap, calls)
						local disable_results = {}
						calls.defer_stop_exact = true
						helpers.assert_true(remap.set_enabled(false, function(ok, reason)
							disable_results[#disable_results + 1] = { ok = ok, reason = reason }
						end))
						calls[failure.field] = 1
						calls.deliver_ready()

						helpers.assert_eq(calls.phase, "stopping")
						helpers.assert_eq(#calls.recovery_timers, 0,
							"no replacement may start before the exact STOP settles")
						helpers.assert_eq(#disable_results, 1)
						helpers.assert_eq(disable_results[1].ok, false)
						helpers.assert_eq(disable_results[1].reason,
							"persistence-failed-after-STOPPED")

						calls.complete_stop_exact()
						assert_delays(calls, { 1.0 })
						calls.recovery_timers[1]:fire()
						helpers.assert_true(helpers.deep_equal(
							calls.build_tokens, { TOKENS[2], TOKENS[3] }))
						helpers.assert_eq(calls.starts_paused, 2)
					end)
			end)
	end
end)





-- ============================================
-- ============================================
-- ======= 3/ Guardian and Layout Gates =======
-- ============================================
-- ============================================

helpers.describe("Karabiner recovery external gates", function()
	helpers.it("suppresses retries only when guardian approval is required", function()
		with_remap({ guardian_status = "requires_approval" }, function(_, calls)
			calls.publish_failed(TOKENS[1])
			helpers.assert_eq(#calls.recovery_timers, 0)
		end)
		for _, status in ipairs({ "ready", "unavailable" }) do
			with_remap({ guardian_status = status }, function(_, calls)
				calls.publish_failed(TOKENS[1])
				assert_delays(calls, { 1.0 })
			end)
		end
	end)

	helpers.it("waits for the newest post-TIS layout before building the replacement", function()
		with_remap({ guardian_status = "ready", cancel_fails = true }, function(_, calls)
			calls.publish_failed(TOKENS[1])
			local stale_recovery = calls.recovery_timers[1]
			calls.layout_revision = "layout-b"
			calls.input_source_callback("Layout B")
			stale_recovery:fire(true)
			helpers.assert_eq(calls.builds, 0,
				"the pre-layout recovery callback must be stale even when cancellation failed")

			local layout_timer = calls.latest_layout_timer()
			helpers.assert_true(type(layout_timer) == "table")
			layout_timer:fire()
			helpers.assert_eq(calls.resolved_revision, "layout-b")
			helpers.assert_eq(#calls.recovery_timers, 2)
			helpers.assert_eq(calls.recovery_timers[2].delay, 1.0)
			calls.recovery_timers[2]:fire()
			helpers.assert_eq(calls.build_tokens[1], TOKENS[2])
			helpers.assert_eq(calls.build_layouts[1], "layout-b",
				"replacement config must consume the settled layout, never the crash-time key map")
		end)
	end)

	local transient_layout_failures = {
		{
			label = "timer arm",
			fails_during_arm = true,
			inject = function(calls) calls.hs_timer_failures_remaining = 1 end,
		},
		{
			label = "pause query",
			inject = function(calls) calls.pause_query_failures_remaining = 1 end,
		},
		{
			label = "lease status query",
			inject = function(calls) calls.status_failures_remaining = 1 end,
			assert_after_failure = function(calls)
				helpers.assert_true(has_log(calls, "synthetic-lease-status-failure"),
					"an async status exception must reach the file-logger boundary")
			end,
		},
		{
			label = "action resolution",
			inject = function(calls) calls.resolve_failures_remaining = 1 end,
		},
		{
			label = "shortcut rebind",
			inject = function(calls) calls.rebind_failures_remaining = 1 end,
		},
		{
			label = "missing shortcut rebind API",
			inject = function(calls)
				calls.saved_rebind = calls.shortcuts.rebind_for_layout
				calls.shortcuts.rebind_for_layout = nil
			end,
			repair = function(calls)
				calls.shortcuts.rebind_for_layout = calls.saved_rebind
			end,
		},
	}

	for _, failure in ipairs(transient_layout_failures) do
		helpers.it("recovers after one transient layout " .. failure.label .. " failure", function()
			with_remap({ guardian_status = "ready" }, function(_, calls)
				calls.publish_failed(TOKENS[1])
				calls.layout_revision = "layout-b"
				failure.inject(calls)
				calls.input_source_callback("Layout B")

				if not failure.fails_during_arm then
					local settle_timer = calls.latest_layout_timer()
					helpers.assert_true(type(settle_timer) == "table")
					settle_timer:fire()
				end
				if failure.assert_after_failure then failure.assert_after_failure(calls) end
				if failure.repair then failure.repair(calls) end

				local retry_timer = calls.latest_layout_timer()
				helpers.assert_true(type(retry_timer) == "table",
					"a transient layout failure must retain an owned retry timer")
				helpers.assert_eq(retry_timer.delay, 1.0)
				retry_timer:fire()
				helpers.assert_eq(calls.resolved_revision, "layout-b")
				helpers.assert_eq(#calls.recovery_timers, 2,
					"layout completion must rearm the guardian-loss recovery series")

				calls.recovery_timers[2]:fire()
				helpers.assert_eq(calls.build_tokens[1], TOKENS[2])
				helpers.assert_eq(calls.build_layouts[1], "layout-b")
				calls.deliver_ready()
				calls.deliver_resumed()
				helpers.assert_eq(calls.phase, "active")
			end)
		end)
	end

	helpers.it("keeps recovery fail-closed after layout retries exhaust and resumes on a new event",
		function()
			with_remap({ guardian_status = "ready" }, function(_, calls)
				calls.publish_failed(TOKENS[1])
				calls.layout_revision = "layout-b"
				calls.pause_query_failures_remaining = 4
				calls.input_source_callback("Layout B")

				calls.latest_layout_timer():fire()
				for _, expected_delay in ipairs({ 1.0, 10.0, 30.0 }) do
					local retry_timer = calls.latest_layout_timer()
					helpers.assert_eq(retry_timer.delay, expected_delay)
					retry_timer:fire()
				end
				helpers.assert_eq(calls.builds, 0)
				helpers.assert_eq(#calls.recovery_timers, 1,
					"exhaustion must not bypass the unresolved layout barrier")

				calls.layout_revision = "layout-c"
				calls.input_source_callback("Layout C")
				calls.latest_layout_timer():fire()
				helpers.assert_eq(#calls.recovery_timers, 2,
					"a new physical layout event must revive the retained recovery")
				calls.recovery_timers[2]:fire()
				helpers.assert_eq(calls.build_layouts[1], "layout-c")
			end)
		end)

	helpers.it("never resumes a stale generation after its layout barrier exhausts", function()
		with_remap({ guardian_status = "ready" }, function(_, calls)
			calls.publish_failed(TOKENS[1])
			calls.recovery_timers[1]:fire()
			helpers.assert_eq(calls.phase, "starting")
			helpers.assert_eq(calls.build_layouts[1], "layout-a")

			calls.layout_revision = "layout-b"
			calls.pause_query_failures_remaining = 4
			calls.input_source_callback("Layout B")
			calls.latest_layout_timer():fire()
			for _ = 1, 3 do calls.latest_layout_timer():fire() end

			calls.deliver_ready()
			helpers.assert_eq(calls.phase, "idle",
				"the layout-A generation must be fenced after the layout-B barrier exhausts")
			helpers.assert_eq(calls.resume_requests, 0,
				"an exhausted barrier remains authoritative even after its pending record is released")

			calls.layout_revision = "layout-c"
			calls.input_source_callback("Layout C")
			calls.latest_layout_timer():fire()
			assert_delays(calls, { 1.0, 1.0 })
			calls.recovery_timers[2]:fire()
			helpers.assert_eq(calls.build_tokens[2], TOKENS[3])
			helpers.assert_eq(calls.build_layouts[2], "layout-c")
		end)
	end)

	helpers.it("retries after layout arrives between worker start and READY", function()
		with_remap({ guardian_status = "ready" }, function(_, calls)
			calls.publish_failed(TOKENS[1])
			calls.recovery_timers[1]:fire()
			helpers.assert_eq(calls.phase, "starting")

			calls.layout_revision = "layout-c"
			calls.input_source_callback("Layout C")
			calls.deliver_ready()
			helpers.assert_eq(calls.phase, "idle",
				"a layout-raced PAUSED token must be fenced before it can RESUME stale keycodes")
			helpers.assert_eq(calls.resume_requests, 0)
			helpers.assert_eq(#calls.recovery_timers, 1,
				"the retry waits for the retained TIS-settle pipeline")

			calls.latest_layout_timer():fire()
			assert_delays(calls, { 1.0, 1.0 })
			calls.recovery_timers[2]:fire()
			helpers.assert_eq(calls.build_tokens[#calls.build_tokens], TOKENS[3])
			helpers.assert_eq(calls.build_layouts[#calls.build_layouts], "layout-c")
		end)
	end)

	helpers.it("fences a recovery generation when layout changes before RESUMED", function()
		with_remap({ guardian_status = "ready" }, function(_, calls)
			calls.publish_failed(TOKENS[1])
			calls.recovery_timers[1]:fire()
			calls.deliver_ready()
			helpers.assert_eq(calls.phase, "resuming")
			helpers.assert_eq(calls.resume_requests, 1)

			calls.layout_revision = "layout-d"
			calls.input_source_callback("Layout D")
			helpers.assert_eq(calls.phase, "idle",
				"the exact old-layout generation must be fenced before RESUMED can activate it")
			helpers.assert_eq(#calls.resume_callbacks, 0,
				"the exact STOP must settle the in-flight RESUME callback")
			helpers.assert_eq(#calls.recovery_timers, 1,
				"the replacement waits for the post-TIS layout barrier")

			calls.latest_layout_timer():fire()
			assert_delays(calls, { 1.0, 1.0 })
			calls.recovery_timers[2]:fire()
			helpers.assert_eq(calls.build_tokens[2], TOKENS[3])
			helpers.assert_eq(calls.build_layouts[2], "layout-d")
		end)
	end)
end)
