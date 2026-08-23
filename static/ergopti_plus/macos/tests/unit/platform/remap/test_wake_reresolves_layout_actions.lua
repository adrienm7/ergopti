--- tests/unit/platform/remap/test_wake_reresolves_layout_actions.lua

--- ==============================================================================
--- MODULE: Behavioral Wake and Lease-Phase Lifecycle Tests
--- DESCRIPTION:
--- Drives the retained caffeinate callback over pure doubles. Proves the exact
--- lease is refreshed before layout work, pause/teardown are fail-closed, and
--- callback or watcher failures reach the file-logger boundary instead of being
--- swallowed by Hammerspoon's async callback dispatcher.
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
			return 3
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
	package.loaded["infra.config_paths"] = { get = function() return "missing-config.toml" end }
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
			if options.start_raises then error("synthetic watcher start failure") end
			if options.start_result == false then return false end
			return self
		end,
		stop = function(self)
			calls.watcher_stop = calls.watcher_stop + 1
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

helpers.describe("karabiner wake callback lifecycle", function()
	helpers.it("cancels and fences the deferred wizard before local teardown commits", function()
		local remap, calls = load_remap()
		local wizard_timer = calls.timers[1]
		helpers.assert_type(wizard_timer, "table",
			"enabled initialization must retain the deferred wizard timer")
		helpers.assert_eq(wizard_timer.delay, 2.0)

		helpers.assert_true(remap.stop())
		calls.deliver_stopped()
		helpers.assert_true(wizard_timer.running == false,
			"local teardown must cancel the exact deferred wizard timer")
		wizard_timer:fire(true)
		helpers.assert_eq(calls.wizard_runs, 0,
			"an already-queued wizard callback must reject the stopped lifecycle")
		helpers.assert_eq(calls.onboarding_stops, 2,
			"public revocation and final local teardown must each settle loaded onboarding")
	end)

	helpers.it("retries the exact deferred wizard within the bounded stop transaction", function()
		local remap, calls = load_remap({ timer_cancel_refusals = 1 })
		local wizard_timer = calls.timers[1]

		helpers.assert_true(remap.stop())
		calls.deliver_stopped()
		helpers.assert_eq(calls.timer_cancel_attempts, 2,
			"the aggregate stop must retry the exact refused timer within its bounded join")
		helpers.assert_true(wizard_timer.running == false,
			"the successful bounded retry must settle the original native capability")
		helpers.assert_true(remap.teardown_local(),
			"a repeated local teardown must recognize the exact timer as already settled")
		helpers.assert_eq(calls.timer_cancel_attempts, 2,
			"settled cleanup must not issue a third native cancellation")
		helpers.assert_true(wizard_timer.running == false)
		wizard_timer:fire(true)
		helpers.assert_eq(calls.wizard_runs, 0,
			"cleanup debt must remain callback-inert across every retry")
	end)

	helpers.it("renews the exact lease before redeploying the already-active generation", function()
		local _, calls = load_remap()
		helpers.assert_true(calls.init_ok, tostring(calls.init_err))
		calls.activate_initial()
		calls.sequence = {}
		calls.refresh = 0
		calls.resolve = 0
		calls.build = 0
		calls.deploy = 0
		calls.lease_start = 0
		calls.lease_pause = 0
		calls.lease_resume = 0
		calls.classifier_refresh = 0
		calls.rebind = 0

		local callback_ok, callback_err = calls.wake(SYSTEM_DID_WAKE)
		helpers.assert_true(callback_ok, tostring(callback_err))
		helpers.assert_eq(calls.sequence[1], "refresh",
			"the first post-wake side effect must prove exact-generation liveness")
		helpers.assert_eq(calls.refresh, 1)
		helpers.assert_eq(calls.resolve, 0,
			"the pre-settle callback must not read hs.keycodes.map")
		helpers.assert_eq(calls.build, 0)
		helpers.assert_true(calls.fire_latest_timer())
		helpers.assert_eq(calls.lease_pause, 0,
			"layout maintenance must never create a raw-key window by gating normal rules PAUSED")
		helpers.assert_eq(calls.lease_phase, "active")
		helpers.assert_eq(calls.resolve, 1,
			"the settled active pipeline must resolve exactly once at its consumer")
		helpers.assert_eq(calls.build, 1)
		helpers.assert_eq(calls.deploy, 1)
		helpers.assert_eq(calls.classifier_refresh, 1,
			"the redeployed generation must refresh synthetic-output classification")
		helpers.assert_eq(calls.lease_start, 0,
			"an ACTIVE replacement must not start or replace the exact lease authority")
		helpers.assert_eq(calls.rebind, 1,
			"wake and input-source changes must share the shortcut-rebind path")
		helpers.assert_eq(calls.lease_resume, 0)
		local resolve_at = sequence_index(calls.sequence, "resolve")
		local build_at = sequence_index(calls.sequence, "build")
		local deploy_at = sequence_index(calls.sequence, "deploy")
		local classifier_at = sequence_index(calls.sequence, "classifier-refresh")
		local rebind_at = sequence_index(calls.sequence, "rebind")
		helpers.assert_true(resolve_at < build_at and build_at < deploy_at)
		helpers.assert_true(deploy_at < classifier_at and classifier_at < rebind_at)
	end)

	helpers.it("refreshes while paused but never redeploys", function()
		local _, calls = load_remap({ paused = true, initial_phase = "paused" })
		calls.sequence = {}

		local callback_ok, callback_err = calls.wake(SCREENS_DID_UNLOCK)
		helpers.assert_true(callback_ok, tostring(callback_err))
		helpers.assert_eq(calls.sequence[1], "refresh")
		helpers.assert_eq(calls.refresh, 1)
		helpers.assert_eq(calls.resolve, 0)
		helpers.assert_true(calls.fire_latest_timer())
		helpers.assert_eq(calls.resolve, 1)
		helpers.assert_eq(calls.build, 0,
			"unknown wake timing must not undo the user-visible paused state")
		helpers.assert_eq(calls.deploy, 0)
		helpers.assert_eq(calls.rebind, 0,
			"paused bindings are rebuilt by the eventual resume transaction")
	end)

	helpers.it("logs async step failures and refuses a stale-layout deploy", function()
		local _, calls = load_remap({ resolve_raises = true, initial_phase = "active" })
		calls.sequence = {}

		local callback_ok, callback_err = calls.wake(SYSTEM_DID_WAKE)
		helpers.assert_true(callback_ok, tostring(callback_err))
		helpers.assert_eq(calls.sequence[1], "refresh")
		helpers.assert_true(calls.fire_latest_timer())
		helpers.assert_eq(calls.build, 0)
		helpers.assert_true(error_log_contains(calls,
			"Karabiner regeneration layout-action resolution failed"),
			"an hs.caffeinate callback exception must reach the file logger")
	end)

	helpers.it("fails closed when pause state cannot be proven", function()
		local _, calls = load_remap({ pause_raises = true })
		local callback_ok, callback_err = calls.wake(SYSTEM_DID_WAKE)

		helpers.assert_true(callback_ok, tostring(callback_err))
		helpers.assert_eq(calls.refresh, 1)
		helpers.assert_true(calls.fire_latest_timer())
		helpers.assert_eq(calls.build, 0,
			"a failed pause query must never be interpreted as unpaused")
		helpers.assert_true(error_log_contains(calls, "Settled Wake pause-state query failed"))
	end)

	helpers.it("continues the settled layout pipeline after a logged lease-refresh failure", function()
		local _, calls = load_remap({ refresh_raises = true, initial_phase = "active" })
		local callback_ok, callback_err = calls.wake(SYSTEM_DID_WAKE)

		helpers.assert_true(callback_ok, tostring(callback_err))
		helpers.assert_true(error_log_contains(calls, "Wake exact-lease liveness refresh failed"))
		helpers.assert_true(calls.fire_latest_timer())
		helpers.assert_eq(calls.resolve, 1)
		helpers.assert_eq(calls.deploy, 1,
			"independent layout work must not vanish with an async refresh exception")
	end)

	helpers.it("ignores disabled, unrelated, and post-stop retained callbacks", function()
		local disabled, disabled_calls = load_remap({ enabled = false })
		local disabled_ok, disabled_err = disabled_calls.wake(SYSTEM_DID_WAKE)
		helpers.assert_true(disabled_ok, tostring(disabled_err))
		helpers.assert_eq(disabled_calls.refresh, 0,
			"a disabled integration owns no live lease and must emit no lease write")
		helpers.assert_true(disabled_calls.fire_latest_timer())
		helpers.assert_eq(disabled_calls.resolve, 1)
		helpers.assert_eq(disabled_calls.rebind, 1,
			"disabling Ergopti Karabiner must not disable Hammerspoon layout maintenance")
		helpers.assert_eq(disabled_calls.build, 0)
		helpers.assert_eq(disabled_calls.deploy, 0)

		local remap, calls = load_remap()
		calls.activate_initial()
		calls.refresh = 0
		calls.resolve = 0
		calls.build = 0
		calls.deploy = 0
		calls.rebind = 0
		local unrelated_ok, unrelated_err = calls.wake(999)
		helpers.assert_true(unrelated_ok, tostring(unrelated_err))
		helpers.assert_eq(calls.refresh, 0)
		local wake_ok, wake_err = calls.wake(SYSTEM_DID_WAKE)
		helpers.assert_true(wake_ok, tostring(wake_err))
		local queued_timer = calls.latest_timer()
		remap.stop()
		helpers.assert_eq(calls.watcher_stop, 0,
			"lease consumers remain live until the exact native fence settles")
		queued_timer:fire(true)
		local stale_ok, stale_err = calls.wake(SYSTEM_DID_WAKE)
		helpers.assert_true(stale_ok, tostring(stale_err))
		helpers.assert_eq(calls.refresh, 1,
			"a queued callback retained after teardown must be epoch-invalidated")
		helpers.assert_eq(calls.resolve, 0)
		helpers.assert_eq(calls.deploy, 0)
		calls.deliver_stopped()
		helpers.assert_eq(calls.watcher_stop, 1,
			"the settled exact fence releases the wake watcher and pending timer")
		disabled.stop()
	end)

	helpers.it("replays a settled wake immediately after heartbeat recovery", function()
		local _, calls = load_remap()
		calls.activate_initial()
		reset_layout_observations(calls)
		calls.refresh_enters_recovery = true

		helpers.assert_true(calls.wake(SYSTEM_DID_WAKE))
		local original_timer = calls.latest_timer()
		helpers.assert_true(original_timer.delay > 0,
			"a new OS event must still wait for TIS to publish the new layout")
		original_timer:fire()
		helpers.assert_eq(calls.resolve, 0)
		helpers.assert_eq(calls.build, 0)
		helpers.assert_eq(calls.deploy, 0)
		helpers.assert_eq(calls.rebind, 0)

		calls.refresh_enters_recovery = false
		calls.publish_phase("active")
		local replay_timer = calls.latest_timer()
		helpers.assert_true(replay_timer ~= original_timer)
		helpers.assert_eq(replay_timer.delay, 0,
			"a retained event that already paid the TIS debounce must replay next-turn")
		replay_timer:fire()
		helpers.assert_eq(calls.resolve, 1)
		helpers.assert_eq(calls.build, 1)
		helpers.assert_eq(calls.deploy, 1)
		helpers.assert_eq(calls.rebind, 1)
	end)

	helpers.it("coalesces repeated layout events retained during recovery", function()
		local _, calls = load_remap()
		calls.activate_initial()
		reset_layout_observations(calls)
		calls.refresh_enters_recovery = true

		helpers.assert_true(calls.wake(SYSTEM_DID_WAKE))
		calls.latest_timer():fire()
		helpers.assert_true(calls.wake(SCREENS_DID_UNLOCK))
		calls.latest_timer():fire()
		helpers.assert_eq(calls.resolve, 0)
		helpers.assert_eq(calls.deploy, 0)

		calls.refresh_enters_recovery = false
		local timer_count_before_replay = #calls.timers
		calls.publish_phase("active")
		helpers.assert_eq(#calls.timers, timer_count_before_replay + 1,
			"the newest durable record must own exactly one recovery replay")
		calls.latest_timer():fire()
		helpers.assert_eq(calls.resolve, 1)
		helpers.assert_eq(calls.deploy, 1)
		helpers.assert_eq(calls.rebind, 1)
	end)

	for _, case in ipairs({
		{ transient = "stopping", settled = "idle" },
		{ transient = "fencing", settled = "failed" },
	}) do
		helpers.it("replays without redeploy after the exact lease settles " .. case.settled, function()
			local _, calls = load_remap()
			calls.activate_initial()
			reset_layout_observations(calls)
			calls.publish_phase(case.transient)

			helpers.assert_true(calls.wake(SYSTEM_DID_WAKE))
			calls.latest_timer():fire()
			helpers.assert_eq(calls.resolve, 0)
			helpers.assert_eq(calls.deploy, 0)

			calls.publish_phase(case.settled)
			local replay_timer = calls.latest_timer()
			helpers.assert_eq(replay_timer.delay, 0)
			replay_timer:fire()
			helpers.assert_eq(calls.resolve, 1)
			helpers.assert_eq(calls.build, 0)
			helpers.assert_eq(calls.deploy, 0)
			helpers.assert_eq(calls.rebind, 1)
			local timer_count = #calls.timers
			calls.publish_phase("active")
			helpers.assert_eq(#calls.timers, timer_count,
				"the settled non-deploying pipeline must consume its durable record")
		end)
	end

	helpers.it("refreshes Hammerspoon state without deploying from stable PREPARED", function()
		local _, calls = load_remap({ initial_phase = "prepared" })
		reset_layout_observations(calls)

		helpers.assert_true(calls.wake(SYSTEM_DID_WAKE))
		calls.latest_timer():fire()
		helpers.assert_eq(calls.resolve, 1)
		helpers.assert_eq(calls.build, 0)
		helpers.assert_eq(calls.deploy, 0)
		helpers.assert_eq(calls.rebind, 1)
	end)

	helpers.it("waits for both native PAUSED and the script pause commit", function()
		local remap, calls = load_remap()
		calls.activate_initial()
		local pause_results = {}
		helpers.assert_true(remap.pause(function(ok, reason)
			pause_results[#pause_results + 1] = { ok = ok, reason = reason }
			if ok then calls.set_script_paused(true) end
		end))
		reset_layout_observations(calls)

		helpers.assert_true(calls.wake(SYSTEM_DID_WAKE))
		calls.latest_timer():fire()
		calls.publish_phase("paused")
		local premature_replay = calls.latest_timer()
		helpers.assert_eq(premature_replay.delay, 0)
		premature_replay:fire()
		helpers.assert_eq(calls.resolve, 0,
			"native PAUSED alone must not consume a layout event before script-control commits")

		calls.deliver_pause_callbacks(true, "paused")
		helpers.assert_eq(#pause_results, 1)
		helpers.assert_true(pause_results[1].ok)
		local committed_replay = calls.latest_timer()
		helpers.assert_true(committed_replay ~= premature_replay)
		committed_replay:fire()
		helpers.assert_eq(#pause_results, 1,
			"layout replay must not resettle the originating pause transaction")
		helpers.assert_eq(calls.resolve, 1)
		helpers.assert_eq(calls.build, 0)
		helpers.assert_eq(calls.deploy, 0)
		helpers.assert_eq(calls.rebind, 0,
			"paused bindings are rebuilt only by the eventual resume transaction")
	end)

	helpers.it("waits for both native ACTIVE and the script resume commit", function()
		local remap, calls = load_remap({
			initial_phase = "paused",
			paused = true,
			model_exact_layout_fence = true,
		})
		local resume_results = {}
		local stale_token = calls.lease_token
		helpers.assert_true(remap.resume(function(ok, reason)
			resume_results[#resume_results + 1] = { ok = ok, reason = reason }
			if ok then calls.set_script_paused(false) end
		end))
		helpers.assert_eq(calls.resume_tokens[1], stale_token,
			"the fixture must reach RESUMING on the pre-layout token")
		reset_layout_observations(calls)

		helpers.assert_true(calls.wake(SYSTEM_DID_WAKE))
		helpers.assert_true(sequence_index(calls.stop_exact_tokens, stale_token) ~= nil,
			"the layout event must fence the exact pre-layout generation")
		helpers.assert_eq(calls.lease_phase, "idle",
			"the retry must remain fail-closed until the TIS settle timer fires")
		helpers.assert_eq(#resume_results, 0,
			"fencing an internal stale attempt must preserve the public Resume intent")
		local settle_timer = calls.latest_timer()
		settle_timer:fire()
		local fresh_token = calls.lease_token
		helpers.assert_true(fresh_token ~= stale_token,
			"post-TIS retry must own a fresh lease token")
		helpers.assert_eq(calls.resolve, 1)
		helpers.assert_eq(calls.build, 1)
		helpers.assert_eq(calls.deploy, 1)
		helpers.assert_eq(#resume_results, 0,
			"a rebuilt PAUSED generation is not success before READY and RESUMED")

		calls.deliver_ready()
		helpers.assert_eq(calls.resume_tokens[2], fresh_token,
			"only the fresh post-TIS generation may receive the replacement RESUME")
		helpers.assert_eq(#calls.resume_tokens, 2,
			"the stale generation must never receive a second RESUME")
		calls.deliver_resumed()
		helpers.assert_eq(#resume_results, 1)
		helpers.assert_true(resume_results[1].ok)
		local committed_replay = calls.latest_timer()
		helpers.assert_true(committed_replay ~= settle_timer)
		helpers.assert_eq(committed_replay.delay, 0)
		committed_replay:fire()
		helpers.assert_eq(#resume_results, 1,
			"layout replay must not resettle the originating resume transaction")
		helpers.assert_eq(calls.resolve, 1)
		helpers.assert_eq(calls.build, 1)
		helpers.assert_eq(calls.deploy, 1)
		helpers.assert_eq(calls.rebind, 1)
	end)

	helpers.it("retains a layout change until an enable transaction commits", function()
		local remap, calls = load_remap({
			enabled = false,
			model_exact_layout_fence = true,
		})
		local enable_results = {}
		local stale_token = calls.lease_token
		helpers.assert_true(remap.set_enabled(true, function(ok, reason)
			enable_results[#enable_results + 1] = { ok = ok, reason = reason }
		end))
		reset_layout_observations(calls)

		helpers.assert_true(calls.wake(SYSTEM_DID_WAKE))
		helpers.assert_true(sequence_index(calls.stop_exact_tokens, stale_token) ~= nil,
			"the layout event must fence the exact pre-layout Enable generation")
		helpers.assert_eq(calls.lease_phase, "idle")
		helpers.assert_eq(#calls.resume_tokens, 0,
			"the stale pre-layout generation must never receive RESUME")
		helpers.assert_eq(#enable_results, 0,
			"the internal exact fence must preserve the public Enable intent")
		helpers.assert_eq(calls.resolve, 0,
			"the private Enable retry must not read TIS before the settle timer")
		local settle_timer = calls.latest_timer()
		settle_timer:fire()
		local fresh_token = calls.lease_token
		helpers.assert_true(fresh_token ~= stale_token,
			"post-TIS Enable retry must own a fresh lease token")
		helpers.assert_eq(calls.resolve, 1)
		helpers.assert_eq(calls.build, 1)
		helpers.assert_eq(calls.deploy, 1)
		helpers.assert_eq(#enable_results, 0)

		calls.deliver_ready()
		helpers.assert_eq(calls.resume_tokens[1], fresh_token)
		helpers.assert_eq(#enable_results, 0,
			"pre-RESUME preference commit must not publish Enable success")
		calls.deliver_resumed()
		helpers.assert_eq(#enable_results, 1)
		helpers.assert_true(enable_results[1].ok)
		local committed_replay = calls.latest_timer()
		helpers.assert_true(committed_replay ~= settle_timer)
		helpers.assert_eq(committed_replay.delay, 0)
		committed_replay:fire()
		helpers.assert_eq(#enable_results, 1,
			"layout replay must not resettle the originating enable transaction")
		helpers.assert_eq(calls.resolve, 1)
		helpers.assert_eq(calls.build, 1)
		helpers.assert_eq(calls.deploy, 1)
		helpers.assert_eq(calls.rebind, 1)
	end)

	helpers.it("replays in disabled mode only after STOPPED and preference commit", function()
		local remap, calls = load_remap()
		calls.activate_initial()
		local disable_results = {}
		helpers.assert_true(remap.set_enabled(false, function(ok, reason)
			disable_results[#disable_results + 1] = { ok = ok, reason = reason }
		end))
		reset_layout_observations(calls)

		helpers.assert_true(calls.wake(SYSTEM_DID_WAKE))
		calls.latest_timer():fire()
		helpers.assert_eq(calls.resolve, 0)
		calls.publish_phase("idle")
		local premature_replay = calls.latest_timer()
		helpers.assert_eq(premature_replay.delay, 0)
		premature_replay:fire()
		helpers.assert_eq(calls.resolve, 0,
			"IDLE publication alone must not outrun the disable transaction callback")
		calls.deliver_stop_callbacks(true, "stopped")
		helpers.assert_eq(#disable_results, 1)
		helpers.assert_true(disable_results[1].ok)
		local replay_timer = calls.latest_timer()
		helpers.assert_eq(replay_timer.delay, 0)
		replay_timer:fire()
		helpers.assert_eq(#disable_results, 1,
			"layout replay must not resettle the originating disable transaction")
		helpers.assert_eq(calls.resolve, 1)
		helpers.assert_eq(calls.build, 0)
		helpers.assert_eq(calls.deploy, 0)
		helpers.assert_eq(calls.rebind, 1,
			"disabled Karabiner must not disable Hammerspoon layout maintenance")
	end)

	helpers.it("serializes a retained layout event behind disable rollback recovery", function()
		local remap, calls = load_remap()
		calls.activate_initial()
		local disable_results = {}
		helpers.assert_true(remap.set_enabled(false, function(ok, reason)
			disable_results[#disable_results + 1] = { ok = ok, reason = reason }
		end))
		reset_layout_observations(calls)
		helpers.assert_true(calls.wake(SYSTEM_DID_WAKE))
		calls.latest_timer():fire()

		calls.deliver_stop_failure("synthetic-stop-failure")
		local rollback_builds = calls.build
		calls.latest_timer():fire()
		helpers.assert_eq(calls.build, rollback_builds,
			"FAILED publication must not race the private rollback transaction")
		reset_layout_observations(calls)
		calls.publish_phase("paused")
		calls.latest_timer():fire()
		helpers.assert_eq(calls.build, 0,
			"a public layout rebuild must not race the private rollback generation")
		calls.deliver_start_callbacks(true, "ready-paused")
		calls.publish_phase("active")
		calls.latest_timer():fire()
		helpers.assert_eq(calls.build, 0)

		calls.deliver_resume_callbacks(true, "resumed")
		helpers.assert_eq(#disable_results, 1)
		helpers.assert_true(disable_results[1].ok == false)
		calls.latest_timer():fire()
		helpers.assert_eq(#disable_results, 1,
			"rollback replay must not resettle the failed disable transaction")
		helpers.assert_eq(calls.resolve, 0,
			"the rollback already resolved the settled layout serial before this observation reset")
		helpers.assert_eq(calls.build, 0,
			"the committed rollback generation must suppress a duplicate layout build")
		helpers.assert_eq(calls.deploy, 0,
			"the committed rollback generation must suppress a duplicate config deployment")
		helpers.assert_eq(calls.rebind, 1,
			"the consumed rollback deployment still owes exactly one shortcut rebind")
	end)

	helpers.it("rejects a cancelled timer callback without erasing its replacement", function()
		local _, calls = load_remap()
		calls.activate_initial()
		calls.sequence = {}
		calls.resolve = 0
		calls.build = 0
		calls.deploy = 0
		calls.rebind = 0
		calls.wake(SYSTEM_DID_WAKE)
		local first = calls.latest_timer()
		calls.wake(SCREENS_DID_UNLOCK)
		local second = calls.latest_timer()
		helpers.assert_true(first ~= second)
		helpers.assert_true(first.running == false, "the superseded timer must be cancelled")

		first:fire(true)
		helpers.assert_eq(calls.resolve, 0,
			"an already-queued cancelled callback must not perform stale work")
		helpers.assert_true(second.running,
			"the stale callback must not erase or cancel the retained replacement")
		second:fire()
		helpers.assert_eq(calls.resolve, 1)
		helpers.assert_eq(calls.deploy, 1)
		helpers.assert_eq(calls.rebind, 1)
		helpers.assert_eq(calls.lease_pause, 0)
		helpers.assert_eq(calls.lease_phase, "active")
	end)

	helpers.it("rejects a timer that fires before its handle can be retained", function()
		local _, calls = load_remap({ settle_timer_synchronous = true })
		local callback_ok, callback_err = calls.wake(SYSTEM_DID_WAKE)

		helpers.assert_true(callback_ok, tostring(callback_err))
		helpers.assert_eq(calls.resolve, 0)
		helpers.assert_eq(calls.deploy, 0)
		helpers.assert_true(error_log_contains(calls, "Could not schedule Wake layout refresh"),
			"a re-entrant timer implementation must fail visibly instead of losing ownership")
	end)

	helpers.it("contains constructor and start failures and records them", function()
		for _, case in ipairs({
			{ options = { constructor_raises = true }, diagnostic = "construction failed" },
			{ options = { constructor_nil = true }, diagnostic = "construction failed" },
			{ options = { start_raises = true }, diagnostic = "start failed" },
			{ options = { start_result = false }, diagnostic = "start failed" },
		}) do
			local remap, calls = load_remap(case.options)
			helpers.assert_true(calls.init_ok,
				"watcher setup failure escaped M.init(): " .. tostring(calls.init_err))
			helpers.assert_true(error_log_contains(calls, case.diagnostic),
				"watcher setup failure must be visible in the file logger")
			remap.stop()
		end
	end)
end)

helpers.describe("karabiner lease phase owns derivative input lifecycle", function()
	helpers.it("waits for READY before mounting and preserves resources during recovery", function()
		local remap, calls = load_remap()
		calls.phase_listener("active")
		helpers.assert_eq(calls.lease_bound_start, 0,
			"RESUMED publishes ACTIVE before post-resume regeneration; phase alone cannot mount inputs")

		helpers.assert_true(remap.regenerate())
		helpers.assert_eq(calls.lease_bound_start, 0)
		calls.deliver_ready()
		helpers.assert_eq(calls.lease_bound_start, 1,
			"only the exact generation READY transaction may mount lease-owned inputs")
		calls.phase_listener("recovering")
		helpers.assert_eq(calls.lease_bound_stop, 0,
			"the bounded one-shot heartbeat retry must not churn live input resources")
		remap.stop()
	end)

	helpers.it("retains actions and classification through FENCING until the exact fence", function()
		local remap, calls = load_remap()
		helpers.assert_true(remap.regenerate())
		calls.deliver_ready()
		local clear_before = calls.managed_clear
		local ke_before = calls.ke_stop

		calls.phase_listener("fencing")
		helpers.assert_eq(calls.lease_bound_stop, 0,
			"protocol failure is not yet proof that managed F17 output stopped")
		helpers.assert_eq(calls.ke_stop, ke_before)
		helpers.assert_eq(calls.managed_clear, clear_before,
			"events still in flight remain synthetic until the variable fence is proven")

		calls.phase_listener("failed")
		helpers.assert_eq(calls.lease_bound_stop, 1)
		helpers.assert_eq(calls.managed_clear, clear_before + 1,
			"the managed classifier is released only at a settled safe phase")
		local stopped_ke = calls.ke_stop
		remap.stop()
		calls.phase_listener("fencing")
		helpers.assert_eq(calls.ke_stop, stopped_ke,
			"a retained FENCING callback after M.stop() cannot repeat local teardown")
	end)

	helpers.it("retains consumers through normal STOPPING until the exact fence settles", function()
		local remap, calls = load_remap()
		helpers.assert_true(remap.regenerate())
		calls.deliver_ready()
		local clear_before = calls.managed_clear
		local ke_before = calls.ke_stop

		calls.phase_listener("stopping")
		helpers.assert_eq(calls.lease_bound_stop, 0,
			"rules can still emit during an accepted normal stop; early teardown loses output")
		helpers.assert_eq(calls.ke_stop, ke_before)
		helpers.assert_eq(calls.managed_clear, clear_before)
		calls.phase_listener("idle")
		helpers.assert_eq(calls.lease_bound_stop, 1)
		helpers.assert_eq(calls.managed_clear, clear_before + 1)
		remap.stop()
	end)
end)
