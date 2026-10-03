--- tests/unit/infra/test_empty_config_defaults.lua

local helpers = require("tests.helpers")

helpers.describe("empty configuration boot projection", function()
	helpers.it("keeps the AI menu neutral and takes privacy parameters from the shared owner", function()
		helpers.with_fresh_modules({ "modules.keylogger.kc_bridge" }, function()
		package.loaded["modules.keylogger.kc_bridge"] = { init = function() return true end }
		local menu = helpers.load_with_stubs("ui.menu.menu_llm")
		local manifest = require("infra.manifest_reader")
		helpers.assert_eq(menu.DEFAULT_STATE.llm_enabled, false)
		-- The dedicated trigger shortcut is retired: a prediction on demand is the
		-- llm_generate_prediction action in a keyboard slot, never an AI-menu hotkey.
		helpers.assert_eq(menu.DEFAULT_STATE.llm_trigger_shortcut, nil)
		helpers.assert_true(not pcall(manifest.default_for, "llm.trigger.shortcut"),
			"the manifest must no longer declare llm.trigger.shortcut")
		helpers.assert_eq(menu.DEFAULT_STATE.llm_url_bar_filter_enabled, manifest.default_for("llm.trigger.url_bar_filter_enabled"))
		helpers.assert_eq(menu.DEFAULT_STATE.llm_secure_field_filter_enabled, manifest.default_for("llm.trigger.secure_filter_enabled"))
		end)
	end)

	helpers.it("declares every metrics and input-source default in the shared manifest", function()
		helpers.with_fresh_modules({ "modules.keylogger.kc_bridge" }, function()
		package.loaded["modules.keylogger.kc_bridge"] = { init = function() return true end }
		local metrics = helpers.load_with_stubs("ui.menu.menu_metrics").DEFAULT_STATE
		local layout = helpers.load_with_stubs("ui.menu.menu_keyboard_layout").DEFAULT_STATE
		local manifest = require("infra.manifest_reader")
		for _, field in ipairs({ "enabled", "disabled_apps", "encrypt", "menubar_wpm", "menubar_colors",
			"float_wpm", "float_graph", "float_colors", "private_filter_enabled", "secure_filter_enabled",
			"system_auth_filter_enabled" }) do
			helpers.assert_eq(metrics["keylogger_" .. field], manifest.default_for("metrics." .. field))
		end
		helpers.assert_nil(metrics.metrics_shortcut)
		helpers.assert_nil(metrics.apps_time_shortcut)
		for _, field in ipairs({ "pause_switch_enabled", "on_pause", "on_resume" }) do
			helpers.assert_eq(layout["layout_" .. field], manifest.default_for("layout." .. field))
		end
		end)
	end)

	helpers.it("does not seed missing remap children or an absent master in an existing file", function()
		helpers.with_fresh_modules({ "platform.remap.config", "adapters.file_system" }, function()
			package.loaded["adapters.file_system"] = {
				read_with_status = function() return "[tap_holds.config]\n[mod_combos.config]\n", "ok" end,
			}
			local config = helpers.load_with_stubs("platform.remap.config")
			local state, status = config.load_user_config({ { id = "left_shift" } },
				{ { id = "lcmd_rcmd" } }, "/neutral/remap.toml")
			helpers.assert_eq(status, "ok")
			helpers.assert_eq(state.tap_holds_enabled, false)
			helpers.assert_eq(state.tap_hold_config.left_shift.tap, "none")
			helpers.assert_eq(state.mod_combos_config.lcmd_rcmd.combo, "none")
		end)
	end)

	helpers.it("keeps the real remap owner neutral without discarding its explicit recommended preset", function()
		local config = helpers.load_with_stubs("platform.remap.config")
		local state = config.build_default_state({ { id = "left_shift" } }, { { id = "lcmd_rcmd" } })
		helpers.assert_eq(state.tap_holds_enabled, false)
		helpers.assert_eq(state.tap_hold_config.left_shift.tap, "none")
		helpers.assert_eq(state.tap_hold_config.left_shift.hold, "none")
		helpers.assert_eq(state.mod_combos_config.lcmd_rcmd.combo, "none")
		local recommended = config.build_recommended_state({ { id = "left_shift" } }, {})
		helpers.assert_eq(recommended.tap_holds_enabled, true)
		helpers.assert_eq(recommended.tap_hold_config.left_shift.tap, "copy")
	end)

	helpers.it("keeps every real input module neutral without importing its recommended children", function()
		helpers.with_fresh_modules({ "modules.keylogger.kc_bridge" }, function()
		-- The native bridge acquires producers at module load; this projection
		-- fixture supplies only that boundary, never any feature/default values.
		package.loaded["modules.keylogger.kc_bridge"] = { init = function() return true end }
		local modules = {}
		for _, name in ipairs({ "keymap", "dynamic_hotstrings", "shortcuts", "gestures", "keylogger" }) do
			modules[name] = helpers.load_with_stubs("modules." .. name)
		end
		local preferences = helpers.load_with_stubs("infra.preferences")
		local state = preferences.build_initial_state({ "french_autocorrection.toml" }, {}, modules)
		for _, key in ipairs({ "keymap", "shortcuts", "gestures", "keylogger_enabled",
			"dynamichotstrings_enabled", "preview_ai_enabled",
			"preview_autocorrect_enabled", "preview_star_enabled" }) do
			helpers.assert_eq(state[key], false, "empty configuration must leave " .. key .. " off")
		end
		-- The declared exception (script-chords-three-os-2026-09-30): the script
		-- chords are no typing feature and start with their preset.
		helpers.assert_eq(state.script_control_enabled, true)
		helpers.assert_eq(state.script_control_shortcuts.script_altgr_enter, "script_pause_toggle")
		helpers.assert_eq(state.script_control_shortcuts.script_altgr_delete, "open_personal_shortcuts")
		helpers.assert_eq(state.hotstrings.french_autocorrection, false)
		for _, action in pairs(modules.gestures.DEFAULT_GESTURES) do
			helpers.assert_eq(action, "none", "a master switch must not implicitly import gesture bindings")
		end
		end)
	end)
end)
