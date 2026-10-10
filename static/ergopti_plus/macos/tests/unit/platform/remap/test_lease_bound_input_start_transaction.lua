--- tests/unit/platform/remap/test_lease_bound_input_start_transaction.lua

--- ==============================================================================
--- MODULE: Lease-Bound Input Activation Transaction Regression Tests
--- DESCRIPTION:
--- Drives fresh READY(mode=PAUSED), local input preparation, and RESUMED through
--- pure doubles. Proves no managed F17 can be emitted before all four consumers
--- and the KC classifier exist, joined callers share one activation, failures
--- roll back/fence the captured token, and stale callbacks never stop a successor.
--- ==============================================================================

local helpers = require("tests.helpers")

local TOKEN_A = "00112233445566778899aabbccddeeff"
local TOKEN_B = "ffeeddccbbaa99887766554433221100"

--- Loads the remap orchestrator with an observable exact-lease protocol.
--- @param options table|nil Failure and race injection options.
--- @return table remap
--- @return table calls
local function load_remap(options)
	options = options or {}
	-- The fixture supplies intent from the real config owner, never native readiness.
	local default_runtime = helpers.with_stub_scope({ "platform.remap.config" }, function()
		local RealConfig = helpers.load_with_stubs("platform.remap.config")
		return RealConfig.build_default_state({}, {}).runtime
	end)
	local calls = {
		phase = options.initial_phase or "prepared",
		token = TOKEN_A,
		activation_blocked = false,
		start_callbacks = {},
		resume_callbacks = {},
		order = {},
		bind_attempts = {},
		unbound = {},
		stop_exact = {},
		stop_generic = 0,
		start_paused = 0,
		start_active = 0,
		gesture_starts = 0,
		gesture_stops = 0,
		tracker_stops = 0,
		classifier_refreshes = 0,
		classifier_clears = 0,
		deploys = 0,
		deploy_failure = options.deploy_failure,
		payload_published = false,
		public_results = {},
		timer_delays = {},
	}

	local function noop() end
	package.loaded["infra.logger"] = {
		start = noop, debug = noop, info = noop, warn = noop,
		error = noop, success = noop, done = noop,
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
				runtime = default_runtime,
				enabled = true,
				tap_hold_config = {},
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
		build_karabiner_json = function() return {} end,
		merge_and_deploy_config = function()
			calls.deploys = calls.deploys + 1
			calls.order[#calls.order + 1] = "deploy"
			calls.payload_published = true
			if calls.deploy_failure == "throw" then
				error("synthetic deploy failure")
			end
			if calls.deploy_failure == "false" then
				return false, "synthetic-deploy-failure"
			end
			return true, "ok"
		end,
		KE_PHYSICAL_KC_LOG = nil,
	}
	package.loaded["platform.remap.ke_lifecycle"] = {
		open_gui = function() return true end,
		stop = noop,
		notify_ready = noop,
	}

	local function publish_phase(phase)
		calls.phase = phase
		if calls.phase_listener then calls.phase_listener(phase, calls.token) end
	end
	package.loaded["platform.remap.lease_controller"] = {
		init = function(listener)
			calls.phase_listener = listener
			return true
		end,
		token = function() return calls.token end,
		status = function()
			return calls.phase, {
				phase = calls.phase,
				token = calls.token,
				activation_blocked = calls.activation_blocked,
			}
		end,
		start = function()
			calls.start_active = calls.start_active + 1
			return false
		end,
		start_paused = function(on_done)
			calls.start_paused = calls.start_paused + 1
			if calls.phase == "paused" then
				on_done(true, "already-paused")
				return true
			end
			calls.start_callbacks[#calls.start_callbacks + 1] = on_done
			publish_phase("starting")
			return true
		end,
		resume_prepared = function(token, on_done)
			calls.order[#calls.order + 1] = "resume_prepared"
			helpers.assert_eq(token, calls.token, "RESUME must target the prepared token")
			helpers.assert_eq(#calls.bind_attempts, 4,
				"all four F17 consumers must exist before RESUME")
			helpers.assert_eq(calls.classifier_refreshes, 1,
				"the KC classifier must exist before RESUME")
			if calls.activation_blocked then
				on_done(false, "pause-intent-pending")
				return false
			end
			calls.resume_callbacks[#calls.resume_callbacks + 1] = on_done
			publish_phase("resuming")
			return true
		end,
		resume = function(on_done)
			calls.order[#calls.order + 1] = "resume"
			helpers.assert_eq(#calls.bind_attempts, 4)
			helpers.assert_eq(calls.classifier_refreshes, 1)
			calls.resume_callbacks[#calls.resume_callbacks + 1] = on_done
			publish_phase("resuming")
			return true
		end,
		pause = function(on_done)
			if on_done then on_done(true, "already-paused") end
			return true
		end,
		stop_exact = function(token, reason)
			calls.stop_exact[#calls.stop_exact + 1] = { token = token, reason = reason }
			publish_phase("stopping")
			return true
		end,
		stop = function(_reason, on_done)
			calls.stop_generic = calls.stop_generic + 1
			if on_done then on_done(true, "already-stopped") end
			return true
		end,
		refresh_liveness = function() return true end,
	}

	local function bind(name)
		return function()
			local index = #calls.bind_attempts + 1
			calls.bind_attempts[index] = name
			calls.order[#calls.order + 1] = "bind-" .. name
			helpers.assert_eq(calls.phase, "paused", "F17 binding must run under mode=PAUSED")
			if options.replace_token_at_bind == index then
				calls.token = TOKEN_B
				calls.phase = "paused"
			end
			if options.fail_bind_index == index then
				if options.fail_bind_mode == "throw" then error("synthetic binder failure") end
				return nil
			end
			return "hotkey-" .. tostring(index)
		end
	end
	package.loaded["platform.remap.watchers"] = {
		start_gesture_watcher = function()
			calls.gesture_starts = calls.gesture_starts + 1
			calls.order[#calls.order + 1] = "gesture"
			helpers.assert_eq(calls.phase, "paused", "gesture watcher must mount under PAUSED")
			if options.watcher_failure == "throw" then error("synthetic watcher failure") end
			if options.watcher_failure == "nil" then return nil end
			return { id = "gesture" }
		end,
		stop_gesture_watcher = function(watcher)
			if watcher ~= nil then calls.gesture_stops = calls.gesture_stops + 1 end
			return true
		end,
		start_cycle_windows_hotkey = bind("cycle"),
		start_alt_tab_windows_hotkey = bind("windows"),
		start_alt_tab_monitor_hotkey = bind("monitor"),
		start_alt_tab_apps_hotkey = bind("apps"),
		stop_alt_tab_apps_tracker = function()
			calls.tracker_stops = calls.tracker_stops + 1
			return true
		end,
		start_input_source_watcher = function() return true end,
		stop_input_source_watcher = function() return true end,
	}
	package.loaded["adapters.hotkey_registrar"] = {
		unbind = function(handle)
			calls.unbound[#calls.unbound + 1] = handle
			return true
		end,
	}
	local classifier = {
		clear_managed_set = function()
			calls.classifier_clears = calls.classifier_clears + 1
			return true
		end,
	}
	if not options.classifier_missing then
		classifier.refresh_managed_set = function()
			calls.classifier_refreshes = calls.classifier_refreshes + 1
			calls.order[#calls.order + 1] = "classifier"
			helpers.assert_eq(calls.phase, "paused", "classifier must publish under PAUSED")
			if options.classifier_failure == "throw" then
				error("synthetic classifier failure")
			end
			if options.classifier_failure == "false" then return false end
			return true
		end
	end
	package.loaded["modules.keylogger.kc_bridge"] = classifier
	package.loaded["modules.gestures.engine"] = {}
	local shortcuts_paused = options.shortcuts_paused == true
	package.loaded["modules.shortcuts"] = {
		is_paused = function() return shortcuts_paused end,
		rebind_for_layout = function() return true end,
	}
	package.loaded["infra.timings"] = { sec = function() return 0.01 end }
	-- layers.toml, read at every regeneration, lives in get_config_dir(); none here.
	package.loaded["infra.config_paths"] = {
		get = function() return "tests/unit/platform/remap/activation.toml" end,
		get_config_dir = function() return "tests/unit/platform/remap/no-layers-toml" end,
	}
	package.loaded["hs.caffeinate.watcher"] = {
		systemDidWake = 7,
		screensDidUnlock = 8,
		new = function()
			return { start = function(self) return self end, stop = function(self) return self end }
		end,
	}

	-- Optional composition uses the genuine controller with its disclosed task/timer ports.
	if options.controller then
		package.loaded["platform.remap.lease_controller"] = options.controller
	end

	local remap = helpers.load_with_stubs("platform.remap", {
		execute = function() return "", true end,
		host = options.controller_host,
		settings = options.controller_settings,
		keycodes = {
			inputSourceChanged = noop,
			currentLayout = function() return "ABC" end,
			map = { f17 = 64 },
		},
		timer = {
			doAfter = function(delay, callback)
				calls.timer_delays[#calls.timer_delays + 1] = delay
				return { stop = noop, fire = callback }
			end,
			doEvery = function() return { stop = noop } end,
			secondsSinceEpoch = function() return 1000 end,
			absoluteTime = function() return 0 end,
			usleep = noop,
		},
	})
	remap.init({
		expand_path = function(path) return path end,
		read = function() return nil end,
	})

	function calls.regenerate(on_done)
		return remap.regenerate(function(ok, reason)
			calls.public_results[#calls.public_results + 1] = { ok = ok, reason = reason }
			if on_done then on_done(ok, reason) end
		end)
	end

	function calls.deliver_ready()
		publish_phase("paused")
		local callbacks = calls.start_callbacks
		calls.start_callbacks = {}
		for _, callback in ipairs(callbacks) do callback(true, "ready-paused") end
	end

	function calls.deliver_resumed()
		publish_phase("active")
		local callbacks = calls.resume_callbacks
		calls.resume_callbacks = {}
		for _, callback in ipairs(callbacks) do callback(true, "resumed") end
	end

	function calls.set_shortcuts_paused(value) shortcuts_paused = value == true end
	function calls.set_deploy_failure(mode) calls.deploy_failure = mode end
	return remap, calls
end

helpers.describe("lease-bound input activation transaction", function()
	for _, mode in ipairs({ "throw", "false" }) do
		helpers.it("contains a deploy " .. mode .. " before starting the lease", function()
			local _, calls = load_remap({ deploy_failure = mode })
			local call_ok, accepted = pcall(calls.regenerate)
			helpers.assert_true(call_ok, "deploy failure escaped the public regeneration boundary")
			helpers.assert_true(accepted == false)
			helpers.assert_eq(calls.deploys, 1)
			helpers.assert_eq(calls.start_paused, 0)
			helpers.assert_eq(#calls.public_results, 1)
			helpers.assert_true(calls.public_results[1].ok == false)
			helpers.assert_eq(calls.public_results[1].reason, "deploy-failed")
		end)

		helpers.it("fences the exact ACTIVE generation after a deploy " .. mode, function()
			local _, calls = load_remap()
			helpers.assert_true(calls.regenerate())
			calls.deliver_ready()
			calls.deliver_resumed()
			calls.public_results = {}
			calls.deploys = 0
			calls.payload_published = false
			calls.set_deploy_failure(mode)

			local call_ok, accepted = pcall(calls.regenerate)
			helpers.assert_true(call_ok, "ACTIVE deploy failure escaped regeneration")
			helpers.assert_true(accepted == false)
			helpers.assert_eq(calls.deploys, 1)
			helpers.assert_true(calls.payload_published,
				"the failure is injected after the replacement may already be visible")
			helpers.assert_eq(#calls.stop_exact, 1,
				"publication is ambiguous, so only the captured token may remain authoritative")
			helpers.assert_eq(calls.stop_exact[1].token, TOKEN_A)
			helpers.assert_eq(calls.stop_generic, 0)
			helpers.assert_eq(#calls.public_results, 1)
			helpers.assert_true(calls.public_results[1].ok == false)
			helpers.assert_eq(calls.public_results[1].reason, "deploy-failed")
		end)
	end

	helpers.it("prepares every consumer under PAUSED and publishes only after RESUMED", function()
		local _, calls = load_remap()
		helpers.assert_true(calls.regenerate())
		helpers.assert_eq(calls.start_paused, 1)
		helpers.assert_eq(calls.start_active, 0, "fresh mode=ACTIVE must be unreachable")
		helpers.assert_eq(#calls.bind_attempts, 0)

		calls.deliver_ready()
		helpers.assert_eq(#calls.bind_attempts, 4)
		helpers.assert_eq(calls.classifier_refreshes, 1)
		helpers.assert_eq(#calls.resume_callbacks, 1)
		helpers.assert_eq(#calls.public_results, 0,
			"READY(mode=PAUSED) is not public activation success")
		helpers.assert_true(helpers.deep_equal(calls.order, {
			"deploy", "gesture", "bind-cycle", "bind-windows",
			"bind-monitor", "bind-apps", "classifier", "resume_prepared",
		}))

		calls.deliver_resumed()
		helpers.assert_eq(#calls.public_results, 1)
		helpers.assert_true(calls.public_results[1].ok)
		helpers.assert_eq(#calls.stop_exact, 0)
	end)

	helpers.it("joins two READY callers into one mount and one RESUME", function()
		local _, calls = load_remap()
		helpers.assert_true(calls.regenerate())
		helpers.assert_true(calls.regenerate())
		helpers.assert_eq(calls.start_paused, 2)

		calls.deliver_ready()
		helpers.assert_eq(#calls.bind_attempts, 4)
		helpers.assert_eq(calls.classifier_refreshes, 1)
		helpers.assert_eq(#calls.resume_callbacks, 1)
		helpers.assert_eq(#calls.public_results, 0)

		calls.deliver_resumed()
		helpers.assert_eq(#calls.public_results, 2)
		helpers.assert_true(calls.public_results[1].ok)
		helpers.assert_true(calls.public_results[2].ok)
		helpers.assert_eq(#calls.stop_exact, 0)
	end)

	for index = 1, 4 do
		for _, mode in ipairs({ "nil", "throw" }) do
			helpers.it("rolls back binder " .. index .. " when it returns " .. mode, function()
				local _, calls = load_remap({ fail_bind_index = index, fail_bind_mode = mode })
				helpers.assert_true(calls.regenerate())
				local delivered, err = pcall(calls.deliver_ready)
				helpers.assert_true(delivered, "binder failure escaped async callback: " .. tostring(err))
				helpers.assert_eq(#calls.resume_callbacks, 0)
				helpers.assert_eq(#calls.stop_exact, 1)
				helpers.assert_eq(calls.stop_exact[1].token, TOKEN_A)
				helpers.assert_eq(calls.stop_generic, 0)
				helpers.assert_eq(#calls.unbound, index - 1)
				helpers.assert_eq(calls.gesture_stops, 1)
				helpers.assert_eq(#calls.public_results, 1)
				helpers.assert_true(calls.public_results[1].ok == false)
			end)
		end
	end

	for _, mode in ipairs({ "throw", "false" }) do
		helpers.it("rolls back all inputs and sends no RESUME when KC refresh returns " .. mode,
			function()
				local _, calls = load_remap({ classifier_failure = mode })
				helpers.assert_true(calls.regenerate())
				calls.deliver_ready()
				helpers.assert_eq(#calls.bind_attempts, 4)
				helpers.assert_eq(#calls.resume_callbacks, 0)
				helpers.assert_eq(#calls.unbound, 4)
				helpers.assert_eq(calls.gesture_stops, 1)
				helpers.assert_eq(#calls.stop_exact, 1)
				helpers.assert_true(calls.public_results[1].ok == false)
			end)
	end

	helpers.it("keeps the generation PAUSED and fences it when the KC API is absent", function()
		local _, calls = load_remap({ classifier_missing = true })
		helpers.assert_true(calls.regenerate())
		calls.deliver_ready()

		helpers.assert_eq(#calls.bind_attempts, 4,
			"the missing classifier is discovered after the local mount transaction")
		helpers.assert_eq(calls.classifier_refreshes, 0)
		helpers.assert_eq(#calls.resume_callbacks, 0,
			"no RESUME may be sent without the exact classifier contract")
		helpers.assert_eq(#calls.unbound, 4)
		helpers.assert_eq(calls.gesture_stops, 1)
		helpers.assert_eq(#calls.stop_exact, 1)
		helpers.assert_eq(calls.stop_exact[1].token, TOKEN_A)
		helpers.assert_true(calls.public_results[1].ok == false)
	end)

	helpers.it("a stale token rolls back locals without stopping its replacement", function()
		local _, calls = load_remap({ replace_token_at_bind = 2 })
		helpers.assert_true(calls.regenerate())
		calls.deliver_ready()
		helpers.assert_eq(calls.token, TOKEN_B)
		helpers.assert_eq(#calls.unbound, 4)
		helpers.assert_eq(calls.gesture_stops, 1)
		helpers.assert_eq(#calls.stop_exact, 0,
			"stale A must not translate into a stop of replacement B")
		helpers.assert_eq(calls.stop_generic, 0)
		helpers.assert_eq(#calls.resume_callbacks, 0)
		helpers.assert_true(calls.public_results[1].ok == false)
	end)

	helpers.it("an older PAUSE intent wins without mounting or fencing", function()
		local _, calls = load_remap()
		helpers.assert_true(calls.regenerate())
		calls.activation_blocked = true
		calls.deliver_ready()
		helpers.assert_eq(#calls.bind_attempts, 0)
		helpers.assert_eq(calls.classifier_refreshes, 0)
		helpers.assert_eq(#calls.resume_callbacks, 0)
		helpers.assert_eq(#calls.stop_exact, 0)
		helpers.assert_true(calls.public_results[1].ok)
		helpers.assert_eq(calls.public_results[1].reason, "ready-paused-by-user-intent")
	end)
end)


-- The scheduling/CLI edges below are modeled ports, never native receipt authority.
-- Both production owners execute; only their existing input/persistence ports vary.
helpers.describe("cold retained paused lease liveness", function()
	local support = require("tests.support.lease_controller_fixture")
	local function compose(run)
		return support.with_fixture(function(load)
			local controller, ctx = load()
			local remap, calls = load_remap({ controller = controller, shortcuts_paused = false,
				controller_host = hs.host, controller_settings = hs.settings })
			local worker
			calls.success_observations = {}
			helpers.assert_true(calls.regenerate(function(ok, reason)
				if ok == true and reason == "ready-paused-by-user-intent" then
					calls.success_observations[#calls.success_observations + 1] = {
						input_count = #worker.inputs, first_input = worker.inputs[1],
						token = controller.token(), phase = controller.status(),
					}
				end
			end))
			worker = ctx.spawns[1]
			helpers.assert_eq(worker.args[1], "--karabiner-lease-worker")
			helpers.assert_eq(worker.args[5], "2", "the actual fresh generation starts PAUSED")
			local captured = controller.token()
			helpers.assert_true(type(captured) == "string")
			helpers.assert_eq(controller.status(), "starting")
			helpers.assert_eq(#worker.inputs, 0)
			-- Public regeneration must enter before the later user pause intent.
			calls.set_shortcuts_paused(true)
			helpers.assert_true(controller.pause())
			helpers.assert_eq(controller.token(), captured)
			helpers.assert_eq(controller.status(), "starting")
			helpers.assert_eq(#worker.inputs, 0, "queued PAUSE cannot fabricate pre-READY input")
			return run(controller, ctx, calls, captured, worker, remap)
		end)
	end

	local function successor(controller, ctx, captured)
		helpers.assert_true(controller.stop_exact(captured, "controlled-owner-replacement"))
		helpers.assert_true(controller.start_paused())
		local worker, index
		for n, candidate in ipairs(ctx.spawns) do
			if candidate.args[1] == "--karabiner-lease-worker" then worker, index = candidate, n end
		end
		helpers.assert_true(worker ~= nil)
		ctx.chunk(index, "READY\n")
		helpers.assert_true(controller.token() ~= captured)
		return worker
	end

	local function no_retained_success(calls)
		helpers.assert_eq(#calls.public_results, 1, "refusal must settle its actual public callback")
		helpers.assert_true(calls.public_results[1].ok == false)
		for _, result in ipairs(calls.public_results) do
			helpers.assert_true(result.ok ~= true,
				"a refused captured refresh cannot publish retained PAUSED success")
		end
	end

	helpers.it("refreshes the genuine cold paused input slot before retained success", function()
		compose(function(controller, ctx, calls, captured, worker)
			ctx.chunk(1, "READY\n")
			helpers.assert_eq(#worker.inputs, 1)
			helpers.assert_eq(worker.inputs[1], "PING 1\n")
			helpers.assert_eq(#calls.success_observations, 1)
			local observed = calls.success_observations[1]
			helpers.assert_eq(observed.input_count, 1)
			helpers.assert_eq(observed.first_input, "PING 1\n")
			helpers.assert_eq(observed.token, captured)
			helpers.assert_eq(observed.phase, "paused")
			helpers.assert_eq(#calls.public_results, 1)
			helpers.assert_true(calls.public_results[1].ok)
			helpers.assert_eq(calls.public_results[1].reason, "ready-paused-by-user-intent")
			helpers.assert_eq(controller.token(), captured)
			helpers.assert_eq(controller.status(), "paused")
			helpers.assert_eq(#calls.bind_attempts, 0)
			helpers.assert_eq(calls.gesture_starts, 0)
			helpers.assert_eq(calls.classifier_refreshes, 0)
			helpers.assert_eq(#calls.resume_callbacks, 0)
			local ack, heartbeat, ack_count, heartbeat_count = nil, nil, 0, 0
			for _, timer in ipairs(ctx.timers) do
				if not timer.cancelled and not timer.fired then
					if timer.repeating and timer.delay == 5 then
						heartbeat, heartbeat_count = timer, heartbeat_count + 1
					elseif not timer.repeating and timer.delay == 3.75 then
						ack, ack_count = timer, ack_count + 1
					end
				end
			end
			helpers.assert_eq(ack_count, 1)
			helpers.assert_eq(heartbeat_count, 1)
			ctx.chunk(1, "PONG 1\n")
			helpers.assert_true(ack.cancelled)
			helpers.assert_true(not heartbeat.cancelled and not heartbeat.fired)
			local retained_heartbeat, live_ack_count = nil, 0
			for _, timer in ipairs(ctx.timers) do
				if not timer.cancelled and not timer.fired then
					if timer.repeating and timer.delay == 5 then retained_heartbeat = timer end
					if not timer.repeating and timer.delay == 3.75 then
						live_ack_count = live_ack_count + 1
					end
				end
			end
			helpers.assert_true(rawequal(retained_heartbeat, heartbeat))
			helpers.assert_eq(live_ack_count, 0)
			helpers.assert_eq(controller.status(), "paused")
			helpers.assert_eq(#worker.inputs, 1)
		end)
	end)

	helpers.it("serializes retained pause refresh with an actual in-flight heartbeat", function()
		compose(function(controller, ctx, calls, _, worker)
			local refresh = controller.refresh_liveness
			controller.refresh_liveness = function()
				helpers.assert_true(refresh())
				return refresh()
			end
			ctx.chunk(1, "READY\n")
			helpers.assert_eq(#worker.inputs, 1)
			helpers.assert_eq(worker.inputs[1], "PING 1\n")
			helpers.assert_true(calls.public_results[1].ok)
		end)
	end)

	helpers.it("refuses a successor created during retained-pause cleanup", function()
		compose(function(controller, ctx, calls, captured)
			local bridge = package.loaded["modules.keylogger.kc_bridge"]
			local clear = bridge.clear_managed_set
			local once, replacement = false, nil
			bridge.clear_managed_set = function()
				local result = clear()
				if not once then once = true; replacement = successor(controller, ctx, captured) end
				return result
			end
			ctx.chunk(1, "READY\n")
			helpers.assert_true(once and replacement ~= nil)
			helpers.assert_eq(#replacement.inputs, 0)
			no_retained_success(calls)
		end)
	end)

	helpers.it("refuses identity lost after an actual accepted refresh", function()
		compose(function(controller, ctx, calls, captured)
			local refresh = controller.refresh_liveness
			local replacement
			controller.refresh_liveness = function()
				local result = refresh()
				replacement = successor(controller, ctx, captured)
				return result
			end
			ctx.chunk(1, "READY\n")
			helpers.assert_true(replacement ~= nil)
			helpers.assert_eq(#replacement.inputs, 0)
			no_retained_success(calls)
		end)
	end)

	helpers.it("refuses retained success after a genuine task input rejection", function()
		compose(function(controller, ctx, calls, _, worker)
			ctx.next_input_result = false
			ctx.chunk(1, "READY\n")
			helpers.assert_true(controller.status() ~= "paused")
			no_retained_success(calls)
			for _, line in ipairs(worker.inputs) do helpers.assert_true(line ~= "RESUME\n") end
		end)
	end)

	helpers.it("contains a retained-pause refresh boundary throw", function()
		compose(function(controller, ctx, calls)
			controller.refresh_liveness = function() error("controlled-refresh-refusal") end
			ctx.chunk(1, "READY\n")
			no_retained_success(calls)
		end)
	end)

	helpers.it("requires literal true rather than a foreign truthy refresh result", function()
		compose(function(controller, ctx, calls)
			controller.refresh_liveness = function() return {} end
			ctx.chunk(1, "READY\n")
			no_retained_success(calls)
		end)
	end)
end)
