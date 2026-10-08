--- tests/unit/platform/remap/test_disabled_init_rule_removal.lua

--- ==============================================================================
--- MODULE: Disabled Karabiner Startup Rule Removal Tests
--- DESCRIPTION:
--- Proves that a persisted « Ergopti uses Karabiner » off removes the marked
--- ErgoptiPlus rules through the byte-preserving remover at startup, without
--- building a generation, allocating a lease token, starting a watchdog or
--- touching any stock Karabiner process. A refused removal leaves the file to
--- the user and startup continues.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED_MODULES = {
	"platform.remap.defaults",
	"platform.remap.config",
	"platform.remap.generator",
	"platform.remap.managed_rule_removal",
	"platform.remap.lease_controller",
	"platform.remap.ke_lifecycle",
	"platform.remap.watchers",
	"adapters.hotkey_registrar",
	"infra.timings",
	"infra.config_paths",
	"modules.keylogger.kc_bridge",
	"modules.gestures.engine",
	"platform.remap",
}

--- Loads the remap orchestrator over observable lifecycle and generator doubles.
--- @param removal_succeeds boolean Whether the byte-preserving remover succeeds.
--- @return table calls Recorded external effects.
local function run_disabled_init(removal_succeeds)
	return helpers.with_stub_scope(OWNED_MODULES, function()
		local RealConfig = helpers.load_with_stubs("platform.remap.config")
		local calls = {
			build = 0,
			merge = 0,
			token = 0,
			lease_start = 0,
			execute = 0,
			removals = {},
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
					runtime = RealConfig.build_default_state({}, {}).runtime,
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
				return nil, "a disabled startup must not build a generation"
			end,
			merge_and_deploy_config = function()
				calls.merge = calls.merge + 1
				return false, "a disabled startup must not merge through the generator"
			end,
			KE_PHYSICAL_KC_LOG = nil,
		}
		package.loaded["platform.remap.managed_rule_removal"] = {
			remove_managed_rules = function(path)
				calls.removals[#calls.removals + 1] = path
				if not removal_succeeds then return false, "unprovable karabiner.json", 0 end
				return true, "removed", 2
			end,
		}
		package.loaded["platform.remap.lease_controller"] = {
			init = function() return true end,
			token = function()
				calls.token = calls.token + 1
				return "0123456789abcdef0123456789abcdef"
			end,
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
			start_input_source_watcher = function() return true end,
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
		calls.init_result = remap.init({
			expand_path = function(path) return "/Users/me/.config/karabiner/karabiner.json" end,
		})
		calls.enabled = remap.get_enabled()
		return calls
	end)
end





-- ================================================
-- ================================================
-- ======= 1/ Disabled Startup Rule Removal =======
-- ================================================
-- ================================================

helpers.describe("disabled Karabiner startup rule removal", function()
	helpers.it("removes marked rules without any generation, token or lease (disabled-startup-inert)", function()
		local calls = run_disabled_init(true)
		helpers.assert_eq(calls.init_result, true)
		helpers.assert_eq(calls.enabled, false)
		helpers.assert_eq(#calls.removals, 1)
		helpers.assert_eq(calls.removals[1], "/Users/me/.config/karabiner/karabiner.json",
			"the remover must act on the resolved karabiner.json")
		helpers.assert_eq(calls.build, 0, "an off switch must not build a generation")
		helpers.assert_eq(calls.merge, 0, "an off switch must not re-encode karabiner.json")
		helpers.assert_eq(calls.token, 0, "an off switch must not allocate a lease token")
		helpers.assert_eq(calls.lease_start, 0,
			"an off switch must not start the watchdog or activate a lease")
		helpers.assert_eq(calls.execute, 0,
			"an off switch must not probe, launch, stop, or signal stock Karabiner")
	end)

	helpers.it("keeps starting when karabiner.json cannot be proven (disabled-startup-unprovable)", function()
		local calls = run_disabled_init(false)
		helpers.assert_eq(calls.init_result, true,
			"a file left untouched for the user is not a startup failure")
		helpers.assert_eq(#calls.removals, 1)
		helpers.assert_eq(calls.build + calls.merge + calls.token + calls.lease_start + calls.execute, 0)
	end)
end)
