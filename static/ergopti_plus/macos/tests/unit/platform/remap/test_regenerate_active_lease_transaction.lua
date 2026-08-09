--- tests/unit/platform/remap/test_regenerate_active_lease_transaction.lua

--- ==============================================================================
--- MODULE: Active-Lease Regeneration Regression Tests
--- DESCRIPTION:
--- Proves that an already-ACTIVE exact generation is replaced without entering
--- PAUSED and that completion follows classifier publication. Atomic file safety
--- is covered by the generator/filesystem suites; this harness deliberately does
--- not pretend that its constant deploy stub is a Core Service reload ACK.
--- ==============================================================================

local helpers = require("tests.helpers")

local TOKEN = "00112233445566778899aabbccddeeff"

local function index_of(values, expected)
	for index, value in ipairs(values) do
		if value == expected then return index end
	end
	return nil
end

--- Loads one fully activated remap instance over observable protocol doubles.
--- @param options table|nil Failure injection options used after activation.
--- @return table remap
--- @return table calls
local function load_active_remap(options)
	options = options or {}
	local calls = {
		phase = "prepared",
		testing = false,
		order = {},
		results = {},
		pause_requests = 0,
		resume_requests = 0,
		stop_exact_requests = 0,
		resolves = 0,
		builds = 0,
		deploys = 0,
		classifier_refreshes = 0,
		build_tokens = {},
		resolve_phases = {},
		build_phases = {},
		deploy_phases = {},
		classifier_phases = {},
	}

	local function noop() end
	local function append(value) calls.order[#calls.order + 1] = value end
	local function publish_phase(phase)
		calls.phase = phase
		if calls.phase_listener then calls.phase_listener(phase, TOKEN) end
	end

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
		resolve_layout_actions = function()
			calls.resolves = calls.resolves + 1
			calls.resolve_phases[#calls.resolve_phases + 1] = calls.phase
			append("resolve")
			return 1
		end,
	}
	package.loaded["platform.remap.generator"] = {
		build_karabiner_json = function(...)
			calls.builds = calls.builds + 1
			calls.build_phases[#calls.build_phases + 1] = calls.phase
			calls.build_tokens[#calls.build_tokens + 1] = select(7, ...)
			append("build")
			return {}, nil, {}, {}
		end,
		merge_and_deploy_config = function()
			calls.deploys = calls.deploys + 1
			calls.deploy_phases[#calls.deploy_phases + 1] = calls.phase
			append("deploy")
			return true, "ok"
		end,
		KE_PHYSICAL_KC_LOG = nil,
	}
	package.loaded["platform.remap.ke_lifecycle"] = {
		open_gui = function() return true end,
		stop = function() return true end,
		notify_ready = noop,
	}
	package.loaded["platform.remap.lease_controller"] = {
		init = function(listener)
			calls.phase_listener = listener
			return true
		end,
		token = function() return TOKEN end,
		status = function()
			local snapshot = {
				phase = calls.phase,
				token = TOKEN,
			}
			if not (calls.testing and options.omit_activation_blocked) then
				snapshot.activation_blocked = calls.testing and options.activation_blocked == true
			end
			return calls.phase, snapshot
		end,
		start = function() error("fresh ACTIVE start is forbidden") end,
		start_paused = function(on_done)
			if calls.phase == "prepared" or calls.phase == "starting" then
				publish_phase("paused")
			end
			on_done(true, "ready-paused")
			return true
		end,
		resume_prepared = function(token, on_done)
			helpers.assert_eq(token, TOKEN)
			calls.resume_requests = calls.resume_requests + 1
			publish_phase("active")
			on_done(true, "resumed")
			return true
		end,
		resume = function(on_done)
			calls.resume_requests = calls.resume_requests + 1
			publish_phase("active")
			on_done(true, "resumed")
			return true
		end,
		pause = function(on_done)
			calls.pause_requests = calls.pause_requests + 1
			publish_phase("paused")
			if on_done then on_done(true, "paused") end
			return true
		end,
		stop_exact = function(token)
			helpers.assert_eq(token, TOKEN)
			calls.stop_exact_requests = calls.stop_exact_requests + 1
			return true
		end,
		stop = function(_reason, on_done)
			publish_phase("idle")
			if on_done then on_done(true, "stopped") end
			return true
		end,
		refresh_liveness = function() return true end,
	}

	local function bind_hotkey()
		helpers.assert_eq(calls.phase, "paused",
			"fresh F17 consumers must be mounted before initial RESUME")
		return {}
	end
	package.loaded["platform.remap.watchers"] = {
		start_gesture_watcher = function() return {} end,
		stop_gesture_watcher = function() return true end,
		start_cycle_windows_hotkey = bind_hotkey,
		start_alt_tab_windows_hotkey = bind_hotkey,
		start_alt_tab_monitor_hotkey = bind_hotkey,
		start_alt_tab_apps_hotkey = bind_hotkey,
		stop_alt_tab_apps_tracker = function() return true end,
		start_input_source_watcher = noop,
		stop_input_source_watcher = function() return true end,
	}
	package.loaded["adapters.hotkey_registrar"] = { unbind = function() return true end }
	package.loaded["modules.keylogger.kc_bridge"] = {
		clear_managed_set = function() return true end,
		refresh_managed_set = function()
			calls.classifier_refreshes = calls.classifier_refreshes + 1
			calls.classifier_phases[#calls.classifier_phases + 1] = calls.phase
			append("classifier")
			return true
		end,
	}
	package.loaded["modules.gestures.engine"] = {}
	package.loaded["modules.shortcuts"] = { is_paused = function() return false end }
	package.loaded["infra.timings"] = { sec = function() return 0.01 end }
	package.loaded["infra.config_paths"] = {
		get = function() return "tests/unit/platform/remap/active-regeneration.toml" end,
	}
	package.loaded["hs.caffeinate.watcher"] = {
		systemDidWake = 7,
		screensDidUnlock = 8,
		new = function()
			return { start = function(self) return self end, stop = function() return true end }
		end,
	}

	local remap = helpers.load_with_stubs("platform.remap", {
		execute = function() return "", true end,
		keycodes = {
			inputSourceChanged = noop,
			currentLayout = function() return "ABC" end,
			map = { f17 = 64 },
		},
		timer = {
			doAfter = function(_delay, callback) return { stop = noop, fire = callback } end,
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
	helpers.assert_true(remap.regenerate(), "fixture must activate one exact lease")
	helpers.assert_eq(calls.phase, "active")

	calls.testing = true
	calls.order = {}
	calls.results = {}
	calls.pause_requests = 0
	calls.resume_requests = 0
	calls.stop_exact_requests = 0
	calls.resolves = 0
	calls.builds = 0
	calls.deploys = 0
	calls.classifier_refreshes = 0
	calls.build_tokens = {}
	calls.resolve_phases = {}
	calls.build_phases = {}
	calls.deploy_phases = {}
	calls.classifier_phases = {}

	function calls.record_result(ok, reason)
		calls.results[#calls.results + 1] = { ok = ok, reason = reason }
	end

	return remap, calls
end

helpers.describe("karabiner active-lease regeneration", function()
	helpers.it("keeps the exact generation ACTIVE through atomic replacement", function()
		local remap, calls = load_active_remap()
		helpers.assert_true(remap.regenerate(function(ok, reason)
			calls.order[#calls.order + 1] = "callback"
			calls.record_result(ok, reason)
		end))
		helpers.assert_eq(#calls.results, 1)
		helpers.assert_true(calls.results[1].ok)
		helpers.assert_eq(calls.pause_requests, 0,
			"PAUSED would expose raw physical keys while normal manipulators are gated off")
		helpers.assert_eq(calls.resume_requests, 0)
		helpers.assert_eq(calls.phase, "active")
		helpers.assert_eq(calls.resolve_phases[1], "active")
		helpers.assert_eq(calls.build_phases[1], "active")
		helpers.assert_eq(calls.deploy_phases[1], "active")
		helpers.assert_eq(calls.classifier_phases[1], "active")
		helpers.assert_eq(calls.build_tokens[1], TOKEN,
			"the replacement graph must remain gated by the exact active lease token")
		local deploy_at = index_of(calls.order, "deploy")
		local classifier_at = index_of(calls.order, "classifier")
		local callback_at = index_of(calls.order, "callback")
		helpers.assert_true(deploy_at < classifier_at,
			"the current classifier must follow publication")
		helpers.assert_true(classifier_at < callback_at,
			"regeneration must not report completion before classifier publication")
	end)

	helpers.it("fails closed when the pause-intent field is absent", function()
		local remap, calls = load_active_remap({ omit_activation_blocked = true })
		helpers.assert_true(remap.regenerate(calls.record_result) == false)
		helpers.assert_eq(calls.resolves, 0)
		helpers.assert_eq(calls.builds, 0)
		helpers.assert_eq(calls.deploys, 0)
		helpers.assert_eq(#calls.results, 1)
		helpers.assert_eq(calls.results[1].reason, "lease-status-unavailable")
	end)

	helpers.it("refuses work while an exact pause or stop intent is queued", function()
		local remap, calls = load_active_remap({ activation_blocked = true })
		helpers.assert_true(remap.regenerate(calls.record_result) == false)
		helpers.assert_eq(calls.resolves, 0)
		helpers.assert_eq(calls.builds, 0)
		helpers.assert_eq(calls.deploys, 0)
		helpers.assert_eq(#calls.results, 1)
		helpers.assert_eq(calls.results[1].reason, "pause-intent-pending")
	end)

	for _, phase in ipairs({ "pausing", "resuming", "recovering", "fencing", "stopping" }) do
		helpers.it("refuses atomic replacement during lease phase " .. phase, function()
			local remap, calls = load_active_remap()
			calls.phase = phase
			helpers.assert_true(remap.regenerate(calls.record_result) == false)
			helpers.assert_eq(calls.deploys, 0)
			helpers.assert_eq(calls.results[1].reason, "lease-transition-in-progress")
		end)
	end

	for _, case in ipairs({
		{ label = "false", value = false },
		{ label = "table", value = {} },
		{ label = "string", value = "forged-capability" },
		{ label = "number", value = 0 },
	}) do
		helpers.it("rejects forged recovery capability " .. case.label, function()
			local remap, calls = load_active_remap()
			helpers.assert_true(remap.regenerate(calls.record_result, case.value) == false)
			helpers.assert_eq(calls.resolves, 0)
			helpers.assert_eq(calls.builds, 0)
			helpers.assert_eq(calls.deploys, 0)
			helpers.assert_eq(#calls.results, 1)
			helpers.assert_eq(calls.results[1].reason, "invalid-recovery-capability")
		end)
	end
end)
