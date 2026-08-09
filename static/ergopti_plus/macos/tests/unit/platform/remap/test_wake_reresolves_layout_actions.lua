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
		lease_resume = 0,
		lease_bound_start = 0,
		lease_bound_stop = 0,
		managed_clear = 0,
		ke_stop = 0,
		rebind = 0,
		watcher_start = 0,
		watcher_stop = 0,
		timers = {},
		lease_phase = options.initial_phase or "prepared",
		lease_start_callbacks = {},
		lease_resume_callbacks = {},
		lease_stop_callbacks = {},
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
		end,
		notify_ready = function() end,
	}
	package.loaded["platform.remap.lease_controller"] = {
		init = function(listener)
			calls.phase_listener = listener
			return true
		end,
		token = function() return "00112233445566778899aabbccddeeff" end,
		status = function()
			return calls.lease_phase, {
				phase = calls.lease_phase,
				token = "00112233445566778899aabbccddeeff",
			}
		end,
		refresh_liveness = function()
			calls.refresh = calls.refresh + 1
			append("refresh")
			if options.refresh_raises then error("synthetic refresh failure") end
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
			helpers.assert_eq(token, "00112233445566778899aabbccddeeff")
			calls.lease_resume = calls.lease_resume + 1
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
		stop_exact = function() return true end,
		pause = function() return true end,
		resume = function(on_done)
			calls.lease_resume = calls.lease_resume + 1
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
		start_input_source_watcher = function() end,
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
		refresh_managed_set = function() return true end,
	}
	package.loaded["modules.gestures.engine"] = {}
	package.loaded["modules.shortcuts"] = {
		is_paused = function()
			append("pause-query")
			if options.pause_raises then error("synthetic pause-state failure") end
			return options.paused == true
		end,
		rebind_for_layout = function()
			calls.rebind = calls.rebind + 1
			append("rebind")
			if options.rebind_raises then error("synthetic rebind failure") end
			return options.rebind_result ~= false
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

	local remap = helpers.load_with_stubs("platform.remap", {
		execute = function() return "", true end,
		keycodes = {
			inputSourceChanged = function() end,
			currentLayout = function() return "ABC" end,
			map = { f17 = 64 },
		},
		timer = {
			doAfter = function(delay, callback)
				local timer = { delay = delay, callback = callback, running = true }
				function timer:stop()
					self.running = false
					return self
				end
				function timer:fire(force)
					if not self.running and force ~= true then return end
					self.running = false
					self.callback()
				end
				calls.timers[#calls.timers + 1] = timer
				if options.settle_timer_synchronous and delay ~= 2.0 then timer:fire() end
				return timer
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
	calls.deliver_ready = function()
		calls.lease_phase = "paused"
		if calls.phase_listener then calls.phase_listener("paused") end
		local callbacks = calls.lease_start_callbacks
		calls.lease_start_callbacks = {}
		for _, callback in ipairs(callbacks) do callback(true, "ready-paused") end
	end
	calls.deliver_resumed = function()
		calls.lease_phase = "active"
		if calls.phase_listener then calls.phase_listener("active") end
		local callbacks = calls.lease_resume_callbacks
		calls.lease_resume_callbacks = {}
		for _, callback in ipairs(callbacks) do callback(true, "resumed") end
	end
	calls.deliver_stopped = function()
		calls.lease_phase = "idle"
		if calls.phase_listener then calls.phase_listener("idle") end
		local callbacks = calls.lease_stop_callbacks
		calls.lease_stop_callbacks = {}
		for _, callback in ipairs(callbacks) do callback(true, "stopped") end
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

helpers.describe("karabiner wake callback lifecycle", function()
	helpers.it("renews the exact lease before redeploying the already-active generation", function()
		local _, calls = load_remap()
		helpers.assert_true(calls.init_ok, tostring(calls.init_err))
		calls.activate_initial()
		calls.sequence = {}
		calls.refresh = 0
		calls.resolve = 0
		calls.build = 0
		calls.deploy = 0
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
		helpers.assert_eq(calls.resolve, 1,
			"the settled active pipeline must resolve exactly once at its consumer")
		helpers.assert_eq(calls.build, 1)
		helpers.assert_eq(calls.deploy, 1)
		helpers.assert_eq(calls.lease_start, 1,
			"wake redeploy must reuse the active generation instead of opening a second lease")
		helpers.assert_eq(calls.rebind, 1,
			"wake and input-source changes must share the shortcut-rebind path")
	end)

	helpers.it("refreshes while paused but never redeploys", function()
		local _, calls = load_remap({ paused = true })
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
		local _, calls = load_remap({ resolve_raises = true })
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
		local _, calls = load_remap({ refresh_raises = true })
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

	helpers.it("rejects a cancelled timer callback without erasing its replacement", function()
		local _, calls = load_remap()
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
