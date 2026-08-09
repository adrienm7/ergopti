--- tests/unit/platform/remap/test_disabled_legacy_cleanup.lua

--- ==============================================================================
--- MODULE: Disabled Karabiner Legacy Cleanup Regression Tests
--- DESCRIPTION:
--- Proves that a persisted off state can remove a fully proven pre-lease
--- ErgoptiPlus graph without starting a lease/watchdog or touching any stock
--- Karabiner process. An ambiguous graph must stop before deployment.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads the remap orchestrator over observable lifecycle and generator doubles.
--- @param merge_succeeds boolean Whether ownership proof succeeds.
--- @return table calls Recorded external effects.
local function run_disabled_init(merge_succeeds)
	local calls = {
		build = 0,
		merge = 0,
		deploy = 0,
		lease_start = 0,
		execute = 0,
	}
	package.loaded["platform.remap.defaults"] = {
		tap_hold_timeout_ms = 200,
		sticky_timeout_ms = 1000,
		simultaneous_threshold_ms = 50,
		combo_symmetric = false,
	}
	package.loaded["platform.remap.config"] = {
		load_available_actions = function() return { { id = "none", label = "None" } } end,
		load_tap_hold_keys = function()
			return { { id = "left_shift", label = "Left Shift", from = { key_code = "left_shift" } } }
		end,
		load_mod_combos = function()
			return {
				{
					id = "left_shift+right_shift",
					label = "Shift pair",
					from = {
						simultaneous = {
							{ key_code = "left_shift" },
							{ key_code = "right_shift" },
						},
					},
				},
			}
		end,
		compute_non_canonical_combos = function() return {} end,
		load_user_config = function()
			return {
				enabled = false,
				tap_hold_config = { left_shift = { tap = "none", hold = "none" } },
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
			calls.build = calls.build + 1
			return {
				profiles = {
					{
						selected = true,
						complex_modifications = { rules = { { description = "new B" } } },
					},
				},
			}, nil, { { description = "old B fingerprint" } }, { proof = "catalogues" }
		end,
		merge_and_deploy_config = function(generated, _, legacy_rules, legacy_context)
			calls.merge = calls.merge + 1
			calls.incoming_rule_count = #generated.profiles[1].complex_modifications.rules
			calls.legacy_rules = legacy_rules
			calls.legacy_context = legacy_context
			if not merge_succeeds then return false, "ambiguous legacy ErgoptiPlus rule" end
			calls.deploy = calls.deploy + 1
			return true, "ok"
		end,
		KE_PHYSICAL_KC_LOG = nil,
	}
	package.loaded["platform.remap.lease_controller"] = {
		init = function() return true end,
		token = function() return "0123456789abcdef0123456789abcdef" end,
		start = function()
			calls.lease_start = calls.lease_start + 1
			return true
		end,
		stop = function() return true end,
		pause = function() return true end,
		resume = function() return true end,
		status = function() return "idle", { phase = "idle" } end,
	}
	package.loaded["platform.remap.ke_lifecycle"] = {
		open_gui = function() return true end,
		stop = function() end,
		notify_ready = function() end,
	}
	package.loaded["platform.remap.watchers"] = {
		start_gesture_watcher = function() return nil end,
		start_cycle_windows_hotkey = function() return nil end,
		start_alt_tab_windows_hotkey = function() return nil end,
		start_alt_tab_apps_hotkey = function() return nil end,
		start_alt_tab_monitor_hotkey = function() return nil end,
		start_input_source_watcher = function() end,
		stop_input_source_watcher = function() return true end,
		stop_alt_tab_apps_tracker = function() return true end,
	}
	package.loaded["adapters.hotkey_registrar"] = { unbind = function() end }
	package.loaded["infra.timings"] = { sec = function() return 0.01 end }
	package.loaded["infra.config_paths"] = { get = function() return "existing-config.toml" end }
	package.loaded["modules.keylogger.kc_bridge"] = {
		refresh_managed_set = function() return true end,
	}
	package.loaded["modules.gestures.engine"] = {}
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
			doAfter = function() return { stop = function() end } end,
			doEvery = function() return { stop = function() end } end,
			secondsSinceEpoch = function() return 1000 end,
			absoluteTime = function() return 0 end,
			usleep = function() end,
		},
	})
	remap.init({
		expand_path = function(path) return path end,
		read = function() return [[{"description":"old","name":"ke_held_left_shift"}]] end,
	})
	return calls
end





-- ===============================================
-- ===============================================
-- ======= 1/ Disabled Legacy Rule Cleanup =======
-- ===============================================
-- ===============================================

helpers.describe("disabled Karabiner legacy cleanup", function()
	helpers.it("deploys only an empty proven cleanup without starting anything (disabled-legacy-cleanup-inert)", function()
		local calls = run_disabled_init(true)
		helpers.assert_eq(calls.build, 1)
		helpers.assert_eq(calls.merge, 1)
		helpers.assert_eq(calls.incoming_rule_count, 0,
			"disabled cleanup must erase the newly built B block before merge")
		helpers.assert_eq(calls.deploy, 1)
		helpers.assert_eq(calls.lease_start, 0,
			"disabled migration must not start the watchdog or activate a lease")
		helpers.assert_eq(calls.execute, 0,
			"disabled migration must not probe, launch, stop, or signal stock Karabiner")
		helpers.assert_eq(calls.legacy_rules[1].description, "old B fingerprint")
		helpers.assert_eq(calls.legacy_context.proof, "catalogues")
	end)

	helpers.it("does not deploy when ownership remains ambiguous (disabled-legacy-cleanup-ambiguous)", function()
		local calls = run_disabled_init(false)
		helpers.assert_eq(calls.build, 1)
		helpers.assert_eq(calls.merge, 1)
		helpers.assert_eq(calls.deploy, 0,
			"an ambiguous personal/legacy graph must leave karabiner.json untouched")
		helpers.assert_eq(calls.lease_start, 0)
		helpers.assert_eq(calls.execute, 0)
	end)
end)
