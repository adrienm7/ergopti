--- tests/unit/platform/remap/test_kc_suppression_requires_live_lease.lua

--- ==============================================================================
--- MODULE: Karabiner Keycode Suppression Lease Boundary
--- DESCRIPTION:
--- Proves that Hammerspoon suppresses event-tap keycodes only while an exact
--- Ergopti Karabiner lease is live. A disabled, starting, failed or stopped
--- integration must treat identically shaped personal Karabiner output as user
--- input instead of silently dropping it from keylogger metrics.
--- ==============================================================================

local helpers = require("tests.helpers")

local TOKEN = "0123456789abcdef0123456789abcdef"

--- Loads the remap orchestrator with a stateful keycode-bridge double.
--- @param initially_enabled boolean Persisted integration setting.
--- @param options table|nil Failure injection options.
--- @return table remap Loaded remap module.
--- @return table ctx Observable lease and suppression state.
local function load_remap(initially_enabled, options)
	options = options or {}
	local ctx = {
		suppresses_personal_output = false,
		start_callback = nil,
		stop_callback = nil,
		phase_listener = nil,
		stop_calls = 0,
		phase = initially_enabled and "prepared" or "idle",
		gesture_starts = 0,
		gesture_stops = 0,
		hotkey_starts = 0,
		hotkey_stops = 0,
		unbind_attempts = {},
		timers = {},
	}

	package.loaded["platform.remap.defaults"] = {
		tap_hold_timeout_ms = 200,
		sticky_timeout_ms = 1000,
		simultaneous_threshold_ms = 50,
		combo_symmetric = false,
	}
	package.loaded["platform.remap.config"] = {
		load_available_actions = function()
			return {
				{ id = "none" },
				{ id = "ergopti_output", karabiner_to = { { key_code = "left_command" } } },
			}
		end,
		load_tap_hold_keys = function() return { { id = "caps" } } end,
		load_mod_combos = function() return { { id = "left_shift+right_shift" } } end,
		compute_non_canonical_combos = function() return {} end,
		load_user_config = function()
			return {
				enabled = initially_enabled,
				tap_hold_config = { caps = { tap = "ergopti_output", hold = "none" } },
				mod_combos_config = {},
				tap_hold_timeout_ms = 200,
				sticky_timeout_ms = 1000,
				simultaneous_threshold_ms = 50,
				combo_symmetric = false,
			}
		end,
		save_user_config = function() return true end,
		resolve_layout_actions = function() return 0 end,
	}
	package.loaded["platform.remap.generator"] = {
		build_karabiner_json = function()
			return { profiles = { { selected = true, complex_modifications = { rules = {} } } } }, nil, {}
		end,
		merge_and_deploy_config = function() return true, "ok" end,
		KE_PHYSICAL_KC_LOG = nil,
	}
	package.loaded["platform.remap.ke_lifecycle"] = {
		open_gui = function() return true end,
		stop = function() return true end,
		notify_ready = function() end,
	}
	package.loaded["platform.remap.lease_controller"] = {
		init = function(listener)
			ctx.phase_listener = listener
			if listener then listener(ctx.phase, initially_enabled and TOKEN or nil) end
			return true
		end,
		token = function() return TOKEN end,
		start_paused = function(callback)
			ctx.start_callback = callback
			ctx.phase = "starting"
			if ctx.phase_listener then ctx.phase_listener("starting", TOKEN) end
			return true
		end,
		resume_prepared = function(token, callback)
			helpers.assert_eq(token, TOKEN)
			ctx.resume_callback = callback
			ctx.phase = "resuming"
			if ctx.phase_listener then ctx.phase_listener("resuming", TOKEN) end
			return true
		end,
		stop = function(_reason, on_done)
			ctx.stop_calls = ctx.stop_calls + 1
			ctx.phase = "stopping"
			if ctx.phase_listener then ctx.phase_listener("stopping", TOKEN) end
			ctx.stop_callback = on_done
			return true
		end,
		pause = function() return true end,
		resume = function(callback)
			ctx.resume_callback = callback
			ctx.phase = "resuming"
			return true
		end,
		stop_exact = function(_token, reason)
			ctx.stop_calls = ctx.stop_calls + 1
			ctx.stop_reason = reason
			ctx.phase = "stopping"
			if ctx.phase_listener then ctx.phase_listener("stopping", TOKEN) end
			return true
		end,
		status = function()
			return ctx.phase, { phase = ctx.phase, token = TOKEN, activation_blocked = false }
		end,
	}
	package.loaded["platform.remap.watchers"] = {
		start_gesture_watcher = function()
			ctx.gesture_starts = ctx.gesture_starts + 1
			return { stop = function() end }
		end,
		stop_gesture_watcher = function(watcher)
			if watcher ~= nil then ctx.gesture_stops = ctx.gesture_stops + 1 end
			return true
		end,
		start_cycle_windows_hotkey = function()
			ctx.hotkey_starts = ctx.hotkey_starts + 1
			return "cycle"
		end,
		start_alt_tab_windows_hotkey = function()
			ctx.hotkey_starts = ctx.hotkey_starts + 1
			return "windows"
		end,
		start_alt_tab_apps_hotkey = function()
			ctx.hotkey_starts = ctx.hotkey_starts + 1
			return "apps"
		end,
		start_alt_tab_monitor_hotkey = function()
			ctx.hotkey_starts = ctx.hotkey_starts + 1
			return "monitor"
		end,
		start_input_source_watcher = function() return true end,
		stop_input_source_watcher = function() return true end,
		stop_alt_tab_apps_tracker = function() return true end,
	}
	package.loaded["adapters.hotkey_registrar"] = {
		unbind = function(handle)
			ctx.unbind_attempts[handle] = (ctx.unbind_attempts[handle] or 0) + 1
			if options.fail_cycle_unbind_once and handle == "cycle"
				and ctx.unbind_attempts[handle] == 1 then return false end
			ctx.hotkey_stops = ctx.hotkey_stops + 1
			return true
		end,
	}
	package.loaded["infra.timings"] = { sec = function() return 0.01 end }
	package.loaded["infra.config_paths"] = { get = function() return "missing-config.toml" end }
	package.loaded["modules.keylogger.kc_bridge"] = {
		refresh_managed_set = function(tap_hold_config)
			ctx.suppresses_personal_output = next(tap_hold_config) ~= nil
			return true
		end,
		clear_managed_set = function()
			if options.clear_mode == "throw" then error("synthetic classifier clear failure") end
			if options.clear_mode == "false" then return false end
			ctx.suppresses_personal_output = false
			return true
		end,
	}
	package.loaded["modules.gestures.engine"] = {}
	package.loaded["modules.shortcuts"] = { is_paused = function() return false end }
	package.loaded["platform.remap"] = nil

	local remap = helpers.load_with_stubs("platform.remap", {
		execute = function() return "", true end,
		json = { encode = function() return "{}" end },
		keycodes = {
			inputSourceChanged = function() end,
			currentLayout = function() return "ABC" end,
			map = { f17 = 64 },
		},
		timer = {
			doAfter = function(_, callback)
				local timer = { callback = callback, stopped = false }
				function timer:stop() self.stopped = true end
				ctx.timers[#ctx.timers + 1] = timer
				return timer
			end,
			doEvery = function() return { stop = function() end } end,
			secondsSinceEpoch = function() return 1000 end,
			absoluteTime = function() return 0 end,
			usleep = function() end,
		},
	})
	remap.init({ expand_path = function(path) return path end })

	function ctx.finish_start(ok, reason)
		ctx.phase = ok and "paused" or "failed"
		if ctx.phase_listener then ctx.phase_listener(ctx.phase, TOKEN) end
		ctx.start_callback(ok, reason or (ok and "ready-paused" or "failed"))
	end

	function ctx.finish_resume(ok, reason)
		ctx.phase = ok and "active" or "failed"
		if ctx.phase_listener then ctx.phase_listener(ctx.phase, TOKEN) end
		local callback = ctx.resume_callback
		ctx.resume_callback = nil
		if callback then callback(ok, reason or (ok and "resumed" or "failed")) end
	end

	function ctx.finish_stop(ok, reason)
		ctx.phase = ok and "idle" or "failed"
		if ctx.phase_listener then ctx.phase_listener(ctx.phase, TOKEN) end
		local callback = ctx.stop_callback
		ctx.stop_callback = nil
		if callback then callback(ok, reason or (ok and "stopped" or "failed")) end
	end

	return remap, ctx
end





-- =============================================
-- =============================================
-- ======= 1/ Exact Suppression Lifetime =======
-- =============================================
-- =============================================

helpers.describe("karabiner keycode suppression follows the exact live lease", function()
	for _, mode in ipairs({ "throw", "false" }) do
		helpers.it("reports local teardown failure when classifier clear returns " .. mode, function()
			local remap, ctx = load_remap(false, { clear_mode = mode })
			ctx.suppresses_personal_output = true

			local call_ok, stopped = pcall(remap.teardown_local)
			helpers.assert_true(call_ok, "classifier clear failure escaped local teardown")
			helpers.assert_true(stopped == false,
				"teardown must not claim personal Karabiner output classification was released")
			helpers.assert_true(ctx.suppresses_personal_output,
				"the double proves the classifier still owns the personal output keycode")
		end)
	end

	helpers.it("never suppresses personal Karabiner output while integration is disabled", function()
		local _, ctx = load_remap(false)

		helpers.assert_eq(ctx.suppresses_personal_output, false,
			"disabled Ergopti must not claim an output keycode that personal Karabiner also emits")
		helpers.assert_eq(ctx.gesture_starts, 0,
			"disabled Ergopti must not probe or mutate personal Karabiner on pointer input")
		helpers.assert_eq(ctx.hotkey_starts, 0,
			"disabled Ergopti must not capture personal F17 chords")
	end)

	helpers.it("waits for READY and clears the set on an unexpected watchdog failure", function()
		local remap, ctx = load_remap(true)
		helpers.assert_eq(ctx.suppresses_personal_output, false,
			"loading an enabled config is not proof that its lease is live")

		helpers.assert_true(remap.regenerate(), "an inert generation should deploy")
		helpers.assert_eq(ctx.suppresses_personal_output, false,
			"deploy/start request must remain inert until the watchdog confirms READY")
		helpers.assert_not_nil(ctx.start_callback, "regeneration must register a readiness callback")
		ctx.finish_start(true, "ready-paused")
		helpers.assert_true(ctx.suppresses_personal_output,
			"classification must be ready before the final RESUME write")
		helpers.assert_eq(ctx.gesture_starts, 1,
			"the CapsWord pointer watcher may start only under exact PAUSED READY")
		helpers.assert_eq(ctx.hotkey_starts, 4,
			"all four managed F17 chords must bind before RESUME")
		helpers.assert_not_nil(ctx.resume_callback)
		ctx.finish_resume(true, "resumed")

		helpers.assert_not_nil(ctx.phase_listener,
			"the bridge must hear a watchdog death that occurs after the one-shot READY callback")
		ctx.phase = "fencing"
		ctx.phase_listener("fencing", TOKEN)
		helpers.assert_true(ctx.suppresses_personal_output,
			"protocol failure is not yet proof that managed output stopped")
		helpers.assert_eq(ctx.hotkey_stops, 0,
			"F17 consumers must survive until fallback fencing settles")
		ctx.phase = "failed"
		ctx.phase_listener("failed", TOKEN)
		helpers.assert_eq(ctx.suppresses_personal_output, false,
			"a dead watchdog must immediately stop classifying personal output as Ergopti output")
		helpers.assert_eq(ctx.gesture_stops, 1,
			"a watchdog death must stop CapsWord probes and their touch hook")
		helpers.assert_eq(ctx.hotkey_stops, 4,
			"a watchdog death must release every personal F17 chord")
	end)

	helpers.it("retains every consumer until STOPPED settles a disable", function()
		local remap, ctx = load_remap(true)
		remap.regenerate()
		ctx.finish_start(true, "ready-paused")
		ctx.finish_resume(true, "resumed")
		helpers.assert_true(ctx.suppresses_personal_output)
		helpers.assert_eq(ctx.hotkey_starts, 4)

		remap.set_enabled(false)

		helpers.assert_true(ctx.suppresses_personal_output,
			"stopping is only an intent: Karabiner may still emit managed output until STOPPED")
		helpers.assert_eq(ctx.gesture_stops, 0,
			"the gesture consumer must remain alive while the exact lease can still emit")
		helpers.assert_eq(ctx.hotkey_stops, 0,
			"managed hotkeys must remain bound while the exact lease can still emit")

		ctx.finish_stop(true, "stopped")
		helpers.assert_eq(ctx.suppresses_personal_output, false,
			"STOPPED may release keycode ownership after the lease is provably inert")
		helpers.assert_eq(ctx.gesture_stops, 1,
			"STOPPED must release the gesture consumer")
		helpers.assert_eq(ctx.hotkey_stops, 4,
			"STOPPED must release every managed hotkey")
		helpers.assert_eq(ctx.stop_calls, 1, "disable must still request exact lease revocation")
	end)

	for _, method_name in ipairs({ "shutdown", "stop" }) do
		helpers.it("retains consumers until the fence for public " .. method_name, function()
			local remap, ctx = load_remap(true)
			remap.regenerate()
			ctx.finish_start(true, "ready-paused")
			ctx.finish_resume(true, "resumed")

			local accepted
			if method_name == "shutdown" then
				accepted = remap.shutdown("test-shutdown")
			else
				accepted = remap.stop()
			end
			helpers.assert_true(accepted)
			helpers.assert_true(ctx.suppresses_personal_output,
				method_name .. " must not clear classification before STOPPED")
			helpers.assert_eq(ctx.gesture_stops, 0)
			helpers.assert_eq(ctx.hotkey_stops, 0)

			ctx.finish_stop(true, "stopped")
			helpers.assert_eq(ctx.suppresses_personal_output, false)
			helpers.assert_eq(ctx.gesture_stops, 1)
			helpers.assert_eq(ctx.hotkey_stops, 4)
		end)
	end

	helpers.it("retains a handle whose adapter unbind returns false and retries it", function()
		local remap, ctx = load_remap(true, { fail_cycle_unbind_once = true })
		remap.regenerate()
		ctx.finish_start(true, "ready-paused")
		ctx.finish_resume(true, "resumed")

		remap.shutdown("first-stop")
		ctx.phase = "idle"
		ctx.phase_listener("idle", TOKEN)
		helpers.assert_eq(ctx.hotkey_stops, 3,
			"a false adapter result must not be counted or forgotten as released")
		helpers.assert_eq(ctx.unbind_attempts.cycle, 1)

		local stop_callback = ctx.stop_callback
		ctx.stop_callback = nil
		stop_callback(true, "stopped")
		helpers.assert_eq(ctx.unbind_attempts.cycle, 2)
		helpers.assert_eq(ctx.hotkey_stops, 4,
			"the retained opaque handle must be retried by the next fenced teardown")
	end)

	helpers.it("keeps suppression empty when lease activation fails", function()
		local remap, ctx = load_remap(true)
		remap.regenerate()
		ctx.finish_start(false, "activation-failed")

		helpers.assert_eq(ctx.suppresses_personal_output, false,
			"a failed activation cannot own output keycodes")
	end)
end)
