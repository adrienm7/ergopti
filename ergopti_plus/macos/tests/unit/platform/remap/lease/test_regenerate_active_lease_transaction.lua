--- tests/unit/platform/remap/lease/test_regenerate_active_lease_transaction.lua

--- ==============================================================================
--- MODULE: Active-Lease Regeneration Regression Tests
--- DESCRIPTION:
--- Proves that an already-ACTIVE exact generation is replaced without entering
--- PAUSED and that completion follows classifier publication. Atomic file safety
--- is covered by the generator/filesystem suites; this harness deliberately does
--- not pretend that its constant deploy stub is a Core Service reload ACK.
---
--- Every regeneration also reads the user's layers.toml from the configuration
--- folder and hands the navigation layer to the generator: the last block pins
--- that wiring, an edit applying with the next regeneration, and a layer that
--- cannot be read failing the regeneration before anything is built.
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
		build_nav_layers = {},
		resolve_phases = {},
		build_phases = {},
		deploy_phases = {},
		classifier_phases = {},
		saved_bindings = {},
		built_bindings = {},
		build_forms = {},
		errors = {},
	}

	local function noop() end
	local function append(value) calls.order[#calls.order + 1] = value end
	local function publish_phase(phase)
		calls.phase = phase
		if calls.phase_listener then calls.phase_listener(phase, TOKEN) end
	end

	package.loaded["infra.logger"] = {
		start = noop, debug = noop, info = noop, warn = noop,
		error = function(_, message, ...)
			calls.errors[#calls.errors + 1] = string.format(message, ...)
		end,
		success = noop, done = noop,
	}
	package.loaded["platform.remap.defaults"] = {
		tap_hold_timeout_ms = 200,
		sticky_timeout_ms = 1000,
		simultaneous_threshold_ms = 50,
		combo_symmetric = false,
	}
	package.loaded["platform.remap.config"] = {
		load_available_actions = function() return options.actions or { { id = "none" } } end,
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
			local binding = state.tap_hold_config.left_shift or {}
			calls.saved_bindings[#calls.saved_bindings + 1] = { tap = binding.tap, hold = binding.hold }
			return true
		end,
		resolve_layout_actions = function()
			calls.resolves = calls.resolves + 1
			calls.resolve_phases[#calls.resolve_phases + 1] = calls.phase
			append("resolve")
			if options.omit_layout_form then return 1 end
			return 1, options.layout_form or "ansi"
		end,
	}
	package.loaded["platform.remap.generator"] = {
		build_karabiner_json = function(...)
			local binding = (select(1, ...)).tap_hold_config.left_shift or {}
			calls.built_bindings[#calls.built_bindings + 1] = { tap = binding.tap, hold = binding.hold }
			calls.build_forms[#calls.build_forms + 1] = (select(1, ...)).virtual_keyboard_type or "missing"
			calls.builds = calls.builds + 1
			calls.build_phases[#calls.build_phases + 1] = calls.phase
			calls.build_tokens[#calls.build_tokens + 1] = select(7, ...)
			calls.build_nav_layers[#calls.build_nav_layers + 1] = (select(1, ...)).nav_layer
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
		start_input_source_watcher = function() return true end,
		stop_input_source_watcher = function() return true end,
	}
	package.loaded["adapters.hotkey_registrar"] = { unbind = function() return true end }
	package.loaded["modules.keystats.kc_bridge"] = {
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
	-- layers.toml, read at every regeneration, lives in get_config_dir(); none
	-- unless the test hands a folder of its own.
	package.loaded["infra.config_paths"] = {
		get = function() return "tests/unit/platform/remap/active-regeneration.toml" end,
		get_config_dir = function() return options.config_dir or "tests/unit/platform/remap/no-layers-toml" end,
	}
	-- The real layer reader, loaded afresh, unless the test replaces it.
	package.loaded["platform.remap.nav_layer"] = options.nav_layer_module
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
	calls.build_nav_layers = {}
	calls.resolve_phases = {}
	calls.build_phases = {}
	calls.deploy_phases = {}
	calls.classifier_phases = {}
	calls.saved_bindings = {}
	calls.built_bindings = {}
	calls.build_forms = {}
	calls.errors = {}

	function calls.record_result(ok, reason)
		calls.results[#calls.results + 1] = { ok = ok, reason = reason }
	end

	return remap, calls
end

--- Runs the actual action-picker callbacks over one exact active remap facade.
--- The slot row opens the shared action picker, replaced here by a recorder
--- whose confirmation is the user's pick.
--- The deployment port records its input; it does not acknowledge native reload.
--- @param run function Receives remap, protocol observations and a menu pick function.
local function with_live_picker(run)
	helpers.with_fresh_modules({ "ui.menu.menu_tap_holds", "ui.menu.menu_utils", "ui.action_picker" }, function()
		local remap, calls = load_active_remap({ actions = {
			{ id = "none", label = "None", category = "Spécial", holdable = true, tappable = true },
			{ id = "escape", label = "Escape", category = "Spécial", holdable = false, tappable = true },
			{ id = "shift", label = "Shift", category = "Spécial", holdable = true, tappable = true },
		} })
		local menu = require("ui.menu.menu_tap_holds")
		local refreshes = 0
		local update = function() refreshes = refreshes + 1 end
		local function pick(slot, title)
			local trees = menu._build_picker_trees(remap, update, true)
			local key = assert(trees.left[1], "the active fixture key must be offered")
			local slot_title = "tap_hold.picker." .. slot
			for _, row in ipairs(key.items) do
				if row.label == slot_title then
					helpers.assert_eq(type(row.action), "function")
					local offered, confirm = nil, nil
					package.loaded["ui.action_picker"] = {
						open = function(opts, on_confirm) offered, confirm = opts, on_confirm; return true end,
					}
					helpers.assert_true(row.action(), "the slot row opens the shared action picker")
					for _, choice in ipairs(offered.items) do
						if choice.label == title then return confirm(choice.id) end
					end
				end
			end
			error("the actual menu did not offer " .. slot .. ": " .. title)
		end
		run(remap, calls, pick, function() return refreshes end)
	end)
end

helpers.describe("live menu mutations during exact lease transitions", function()
	for _, phase in ipairs({ "recovering", "resuming", "pausing", "fencing", "stopping" }) do
		helpers.it("(live-tap-hold-transition) preserves the old choice during " .. phase .. " and retries ACTIVE", function()
			with_live_picker(function(remap, calls, pick, refreshes)
				calls.phase = phase
				helpers.assert_eq(pick("hold", "Shift"), false)
				helpers.assert_eq(remap.get_hold_action("left_shift"), "none",
					"a rejected live choice must not remain saved until reload")
				helpers.assert_eq(#calls.saved_bindings, 0, "the refusal must precede persistence")
				helpers.assert_eq(calls.builds, 0)
				helpers.assert_eq(calls.deploys, 0)
				helpers.assert_eq(refreshes(), 0, "a refused choice does not publish a menu refresh")
				helpers.assert_true(#calls.errors > 0, "the refusal must be visible through the central logger")
				calls.phase = "active"
				helpers.assert_true(pick("hold", "Shift"))
				helpers.assert_true(pick("tap", "Escape"))
				helpers.assert_eq(calls.saved_bindings[2].hold, "shift")
				helpers.assert_eq(calls.saved_bindings[2].tap, "escape")
				helpers.assert_eq(calls.built_bindings[2].hold, "shift")
				helpers.assert_eq(calls.built_bindings[2].tap, "escape")
				helpers.assert_eq(calls.builds, 2)
				helpers.assert_eq(calls.deploys, 2)
				helpers.assert_eq(calls.pause_requests, 0)
				helpers.assert_eq(calls.resume_requests, 0)
				helpers.assert_eq(calls.stop_exact_requests, 0, "no personal or managed process restart is needed")
			end)
		end)
	end

	helpers.it("(live-tap-hold-transition) refuses a pending Stop before saving into the still ACTIVE lease", function()
		with_live_picker(function(remap, calls, pick)
			-- Retain the phase while the exact controller has already accepted Stop.
			local controller = package.loaded["platform.remap.lease_controller"]
			local status = controller.status
			controller.status = function()
				local phase, snapshot = status()
				snapshot.activation_blocked = true
				return phase, snapshot
			end
			helpers.assert_eq(pick("tap", "Escape"), false)
			helpers.assert_eq(remap.get_tap_action("left_shift"), "none")
			helpers.assert_eq(#calls.saved_bindings, 0)
			helpers.assert_eq(calls.deploys, 0)
		end)
	end)

	helpers.it("(live-tap-hold-transition) refuses an unavailable exact lease status before saving", function()
		with_live_picker(function(remap, calls, pick)
			package.loaded["platform.remap.lease_controller"].status = function()
				error("the actual status port is unavailable")
			end
			helpers.assert_eq(pick("tap", "Escape"), false)
			helpers.assert_eq(remap.get_tap_action("left_shift"), "none")
			helpers.assert_eq(#calls.saved_bindings, 0)
			helpers.assert_eq(calls.builds, 0)
			helpers.assert_true(#calls.errors > 0)
		end)
	end)
end)

helpers.describe("karabiner active-lease regeneration", function()
	for _, form in ipairs({ "ansi", "iso" }) do
		helpers.it("(layout-form-generation) carries the resolved " .. form .. " convention into the same build", function()
			local remap, calls = load_active_remap({ layout_form = form })
			helpers.assert_true(remap.regenerate(calls.record_result))
			helpers.assert_eq(calls.build_forms[1], form,
				"logical action keycodes and virtual HID must use one captured keyboard form")
		end)
	end

	for _, case in ipairs({ { label = "missing" }, { label = "invalid", layout_form = "invalid" } }) do
		helpers.it("(layout-form-generation) refuses the " .. case.label .. " resolved convention before building", function()
			local remap, calls = load_active_remap()
			package.loaded["platform.remap.config"].resolve_layout_actions = function()
				return 1, case.layout_form
			end
			helpers.assert_eq(remap.regenerate(calls.record_result), false)
			helpers.assert_eq(calls.builds, 0)
			helpers.assert_eq(calls.deploys, 0)
			helpers.assert_eq(#calls.results, 1)
			helpers.assert_eq(calls.results[1].reason, "layout-resolution-failed")
		end)
	end

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

-- A layers.toml binding KeyT to one function key.
local LAYER_FILE = '[_meta]\nschema_version = 1\n\n[layers.nav.all]\n"KeyT" = "keystroke:%s"\n'

--- Writes a whole file; raises when it cannot.
local function write_file(path, content)
	local fh = assert(io.open(path, "wb"))
	fh:write(content)
	fh:close()
end

--- The key the layer sends for one physical key, nil when it is unbound.
local function sent_key(nav_layer, code)
	local binding = nav_layer and nav_layer.bindings[code]
	return binding and binding.chords[1].key
end

helpers.describe("karabiner regeneration reads the navigation layer", function()
	helpers.it("builds from the configuration folder's layers.toml, read again at every regeneration (nav-layer-generated)",
		function()
			local dir = helpers.temp_dir() .. "/ergopti_regenerate_nav_layer_" .. tostring(os.time()) .. "_"
				.. tostring(math.random(100000, 999999))
			local ok_mkdir = os.execute('mkdir "' .. dir .. '"')
			helpers.assert_true(ok_mkdir == true or ok_mkdir == 0, "sandbox directory must exist")
			local ok, err = pcall(function()
				write_file(dir .. "/layers.toml", LAYER_FILE:format("F3"))
				local remap, calls = load_active_remap({ config_dir = dir })
				helpers.assert_true(remap.regenerate(calls.record_result))
				helpers.assert_eq(sent_key(calls.build_nav_layers[1], "KeyT"), "F3",
					"the generator must receive the layer of the configuration folder's layers.toml")
				write_file(dir .. "/layers.toml", LAYER_FILE:format("F4"))
				helpers.assert_true(remap.regenerate(calls.record_result))
				helpers.assert_eq(sent_key(calls.build_nav_layers[2], "KeyT"), "F4",
					"an edited layers.toml applies with the next regeneration")
			end)
			os.remove(dir .. "/layers.toml")
			os.execute('rmdir "' .. dir .. '"')
			if not ok then error(err, 0) end
		end)

	helpers.it("hands the generator an empty layer without a layers.toml (nav-layer-generated)", function()
		local remap, calls = load_active_remap()
		helpers.assert_true(remap.regenerate(calls.record_result))
		local nav_layer = calls.build_nav_layers[1]
		helpers.assert_not_nil(nav_layer, "the generator must receive the navigation layer")
		helpers.assert_nil(next(nav_layer.bindings), "no layers.toml binds no key")
	end)

	helpers.it("fails before any build when the navigation layer cannot be read", function()
		local reader = { fail = false }
		function reader.load()
			if reader.fail then error("the physical-key registry is unreadable") end
			return { bindings = {}, registry = { keys = {} } }
		end
		local ok, err = pcall(function()
			local remap, calls = load_active_remap({ nav_layer_module = reader })
			reader.fail = true
			helpers.assert_true(remap.regenerate(calls.record_result) == false)
			helpers.assert_eq(calls.builds, 0, "a layer that cannot be read must not be built around")
			helpers.assert_eq(calls.deploys, 0)
			helpers.assert_eq(#calls.results, 1)
			helpers.assert_eq(calls.results[1].reason, "nav-layer-unavailable")
		end)
		-- Later files load the real reader through the generator.
		package.loaded["platform.remap.nav_layer"] = nil
		if not ok then error(err, 0) end
	end)
end)
