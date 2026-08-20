--- tests/unit/ui/menu/test_disable_all_external_save_gate.lua

--- ==============================================================================
--- MODULE: Disable-All External Preference Gate Regression
--- DESCRIPTION:
--- Captures the real disable-all action from ui.menu.start and proves a rejected
--- config write never clears Karabiner or keyboard-shortcut external stores.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("menu disable-all: external bindings wait for preference commit", function()
	helpers.it("does not mutate Karabiner or keyboard settings on writer false", function()
		local noop = function() end
		local actions = nil
		local external = { karabiner = 0, keyboard = 0, settings_scan = 0 }
		local state = {
			trigger_char = "★",
			hotstrings = { common = true },
			terminator_states = {},
			script_control_shortcuts = {
				return_key = "script_pause_toggle",
				backspace = "script_reload",
				escape = "script_quit",
			},
			keymap = true,
			gestures = true,
			shortcuts = true,
			llm_enabled = true,
			keylogger_enabled = true,
			script_control_enabled = true,
			personal_info = true,
			update_channel = "dev",
			update_check_interval_seconds = 3600,
		}

		local hs_stub = helpers.load_with_stubs("infra.logger") and _G.hs
		local original_get_keys = hs_stub.settings.getKeys
		hs_stub.settings.getKeys = function()
			external.settings_scan = external.settings_scan + 1
			return { "keyboard_shortcut_test" }
		end
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.notifications"] = { notify = noop }
		package.loaded["ui.hotstring_editor"] = { set_update_menu = noop }
		package.loaded["infra.text_utils"] = {
			escape_gsub_replacement = function(value) return value end,
			shell_quote = function(value) return value end,
		}
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.ui_restore"] = {}
		package.loaded["infra.preferences"] = {
			build_initial_state = function() return state end,
			load = function() return {}, "ok" end,
			merge_saved_data = noop,
			snapshot = function() return state end,
			save = function() return false end,
			get_group_name = function() return "common" end,
		}
		package.loaded["ui.menu.builder"] = {
			generate = function() return {} end,
			invalidate_cache = noop,
		}
		package.loaded["ui.menu.hotstring_counter"] = { invalidate_cache = noop }
		package.loaded["ui.menu.menu_paths"] = {
			is_initialized = function() return true end,
			get = function() return "/virtual/config.toml" end,
			get_config_dir = function() return "/virtual" end,
			open_editor = noop,
		}
		package.loaded["ui.menu.menu_state"] = {
			sync_state_to_modules = function() return true end,
		}
		package.loaded["ui.menu.keymap_lifecycle"] = {
			ensure_started = function() return true end,
		}
		package.loaded["ui.menu.menu_watchers"] = {
			start_config_watcher = function() return { stop = noop } end,
			start_theme_watcher = function() return { stop = noop } end,
		}
		package.loaded["modules.updater"] = {
			get_check_interval = function() return 3600 end,
			start_background_checks = noop,
		}
		package.loaded["adapters.tray_menu"] = { adopt = noop, setMenu = noop }
		package.loaded["chord"] = { format = function() return "ctrl+x" end }
		package.loaded["adapters.hotkey_registrar"] = {
			bind = function() return {} end,
			setEnabled = function() return true end,
			unbind = function() return true end,
		}
		package.loaded["infra.termination_coordinator"] = { request_exit = function() return true end }

		for _, module_name in ipairs({
			"ui.menu.menu_gestures", "ui.menu.menu_shortcuts", "ui.menu.menu_keyboard_layout",
			"ui.menu.menu_hotstrings", "ui.menu.menu_metrics", "ui.menu.menu_remap",
			"ui.menu.menu_apps", "ui.menu.menu_about",
		}) do
			package.loaded[module_name] = {}
		end
		package.loaded["ui.menu.menu_llm"] = { create = function() return {} end }
		package.loaded["modules.llm"] = { set_backend = noop }
		package.loaded["modules.keylogger"] = {}
		local shortcuts = {
			is_paused = function() return false end,
			set_on_pause_change = noop,
			set_shortcut_action = noop,
			set_extras = function(candidate)
				if type(candidate) == "table" and type(candidate.disable_all) == "function" then
					actions = candidate
				end
			end,
			list_shortcuts = function() return {} end,
			disable = noop,
			set_keyboard_action = function() external.keyboard = external.keyboard + 1 end,
		}
		package.loaded["modules.shortcuts"] = shortcuts
		package.loaded["modules.dynamic_hotstrings"] = {}
		package.loaded["modules.gestures"] = { SINGLE_SLOTS = { "swipe_left" } }
		package.loaded["infra.personal_shortcuts"] = { load = noop }
		package.loaded["ui.menu.preferences_transaction"] = nil

		local gestures = { set_action = noop }
		local keymap = {
			get_sections = function() return {} end,
			get_terminator_defs = function() return {} end,
			set_preview_star_enabled = noop,
			set_preview_autocorrect_enabled = noop,
			set_preview_ai_enabled = noop,
		}
		local karabiner = {
			TAP_HOLD_KEYS = { { id = "caps" } },
			MOD_COMBOS = { { id = "combo" } },
			set_tap_action = function() external.karabiner = external.karabiner + 1 end,
			set_hold_action = function() external.karabiner = external.karabiner + 1 end,
			set_combo_combo_action = function() external.karabiner = external.karabiner + 1 end,
			set_combo_tap_action = function() external.karabiner = external.karabiner + 1 end,
			set_combo_hold_action = function() external.karabiner = external.karabiner + 1 end,
			regenerate = function() external.karabiner = external.karabiner + 1 end,
		}

		package.loaded["ui.menu.init"] = nil
		local Menu = require("ui.menu.init")
		Menu.start("/virtual/", {}, gestures, keymap, {}, {}, karabiner, {})
		helpers.assert_type(actions and actions.disable_all, "function",
			"ui.menu.start must expose the real disable-all action through shortcut extras")

		external.karabiner = 0
		external.keyboard = 0
		external.settings_scan = 0
		actions.disable_all()

		helpers.assert_eq(external.karabiner, 0,
			"a rejected config write must not clear the external Karabiner config")
		helpers.assert_eq(external.keyboard, 0,
			"a rejected config write must not clear keyboard actions")
		helpers.assert_eq(external.settings_scan, 0,
			"the external keyboard settings store must not even be enumerated")

		hs_stub.settings.getKeys = original_get_keys
	end)
end)

return true
