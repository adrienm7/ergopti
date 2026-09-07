--- tests/unit/modules/shortcuts/pause_owners/test_shortcut_facade.lua

--- ==============================================================================
--- MODULE: Pause Owner shortcut facade Regressions
--- DESCRIPTION:
--- Preserves the behavioral pause-owner regression scenarios with a focused
--- fixture boundary. Shared fixtures create fresh runtime state per invocation.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixtures = require("tests.unit.modules.shortcuts.pause_owners.fixtures")
local OWNER_IDS = fixtures.OWNER_IDS
local reset_module = fixtures.reset_module

helpers.describe("HS-012 real shortcuts facade wiring", function()
	helpers.it("carries pause epoch and both runtime owners through the injected facade", function()
		local epoch = 41
		local transition_pending = true
		local registrations = {}
		local requirement_capabilities = {}
		local models_mgr = {
			create_requirement_owner = function(label)
				local capability = { label = label }
				requirement_capabilities[#requirement_capabilities + 1] = capability
				return capability
			end,
			pause_requirements = function(capability)
				return type(capability) == "table"
			end,
		}
		package.loaded["modules.shortcuts.bindings"] = {
			DEFAULT_CHATGPT_URL = "https://example.test",
			list_shortcuts = function() return {} end,
			enable = function() return true end,
			disable = function() return true end,
			is_enabled = function() return true end,
			set_wrap_pairs_getter = function() return true end,
			set_chatgpt_url = function() return true end,
			start = function() return true end,
			stop = function() return true end,
			is_started = function() return false end,
			rebind = function() return true end,
		}
		package.loaded["modules.shortcuts.script_control"] = {
			ACTIONS = {},
			ACTION_LABELS = {},
			PAUSE_OWNER_IDS = OWNER_IDS,
			start = function() return true end,
			stop = function() return true end,
			is_paused = function() return false end,
			is_pause_transition_pending = function() return transition_pending end,
			get_pause_epoch = function() return epoch end,
			register_pause_owner = function(name, owner)
				registrations[#registrations + 1] = { name = name, owner = owner }
				return true
			end,
			set_shortcut_action = function() return true end,
			set_on_pause_change = function() return true end,
			set_extras = function() return true end,
			toggle = function() return true end,
		}
		package.loaded["modules.shortcuts.keyboard_shortcuts"] = setmetatable({
			start = function() return true end,
			stop = function() return true end,
		}, { __index = function() return function() return true end end })
		package.loaded["adapters.hotkey_registrar"] = {
			set_delivery_guard = function(guard)
				helpers.assert_true(guard())
				return true
			end,
		}
		package.loaded["infra.startup_transaction"] = {
			run = function() return true end,
		}
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		local shortcuts = helpers.load_with_stubs("modules.shortcuts")
		helpers.assert_true(shortcuts.is_pause_transition_pending(),
			"the real facade must expose the live ScriptControl transition owner")
		transition_pending = false
		helpers.assert_eq(shortcuts.is_pause_transition_pending(), false,
			"the facade must not snapshot transition state at module construction")
		helpers.assert_eq(shortcuts.get_pause_epoch(), 41,
			"the real facade must expose the exact ScriptControl epoch")
		epoch = 42
		helpers.assert_eq(shortcuts.get_pause_epoch(), 42,
			"the facade must not snapshot the epoch at module construction")

		-- Drive the real root menu controller far enough to cross its dependency
		-- injection boundary. A source scan for the field name passed while the
		-- facade itself forgot the proxy, which is the topology regression HS-012
		-- needs to make impossible.
		local injected_control = nil
		local injected_update_menu = nil
		local noop = function() end
		local state = {
			trigger_char = "*",
			hotstrings = {},
			terminator_states = {},
			script_control_shortcuts = {},
			keymap = true,
			gestures = true,
			shortcuts = true,
			llm_enabled = false,
			keylogger_enabled = false,
			script_control_enabled = true,
			personal_info = false,
			update_channel = "dev",
			update_check_interval_seconds = 3600,
		}
		package.loaded["infra.notifications"] = { notify = function() return true end }
		package.loaded["ui.hotstring_editor"] = { set_update_menu = noop }
		package.loaded["infra.text_utils"] = {
			escape_gsub_replacement = function(value) return value end,
			shell_quote = function(value) return value end,
		}
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.ui_restore"] = {}
		package.loaded["infra.preferences"] = {
			build_initial_state = function() return state end,
			load = function() return {}, "present" end,
			merge_saved_data = noop,
			snapshot = function() return {} end,
			save = function() return true end,
			get_group_name = function() return "test" end,
		}
		package.loaded["ui.menu.preferences_transaction"] = {
			clone = function(value)
				local copy = {}
				for key, item in pairs(value) do copy[key] = item end
				return copy
			end,
			restore_table = function() return true end,
			bind = function() return function() return true end end,
		}
		package.loaded["ui.menu.global_actions_transaction"] = {
			create = function()
				return {
					disable_all = function() return true end,
					reset_defaults = function() return true end,
				}
			end,
		}
		package.loaded["ui.menu.recoverable_file_moves"] = {
			create = function() return {} end,
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
		package.loaded["infra.factory_reset_journal"] = {
			path_for = function(config_path)
				if type(config_path) ~= "string" or config_path == "" then return nil end
				return config_path .. ".ergopti-reset-journal-v1.json"
			end,
			create = function(journal_path)
				if type(journal_path) ~= "string" or journal_path == "" then
					return nil, "journal path must be a non-empty string"
				end
				return {
					prepare = function() return true end,
					mark_commit = function() return true end,
					mark_prepared = function() return true end,
					clear = function() return true end,
				}
			end,
		}
		package.loaded["ui.menu.menu_state"] = {
			sync_state_to_modules = function() return true end,
		}
		package.loaded["ui.menu.keymap_lifecycle"] = {
			ensure_started = function() return true end,
		}
		package.loaded["ui.menu.menu_watchers"] = {
			start_config_watcher = function()
				return { stop = function() return true end }
			end,
			start_theme_watcher = function()
				return { stop = function() return true end }
			end,
		}
		package.loaded["modules.updater"] = {
			get_check_interval = function() return 3600 end,
			start_background_checks = noop,
		}
		package.loaded["adapters.tray_menu"] = {
			adopt = function() return true end,
			setMenu = function() return true end,
			destroy = noop,
		}
		package.loaded["chord"] = { format = function() return "ctrl+x" end }
		package.loaded["adapters.hotkey_registrar"] = {
			bind = function() return {} end,
			setEnabled = function() return true end,
			unbind = function() return true end,
		}
		package.loaded["infra.termination_coordinator"] = {
			request_exit = function() return true end,
			request_reload = function() return true end,
		}
		for _, module_name in ipairs({
			"ui.menu.menu_gestures",
			"ui.menu.menu_shortcuts",
			"ui.menu.menu_keyboard_layout",
			"ui.menu.menu_hotstrings",
			"ui.menu.menu_metrics",
			"ui.menu.menu_remap",
			"ui.menu.menu_apps",
			"ui.menu.menu_about",
		}) do
			package.loaded[module_name] = {}
		end
		package.loaded["ui.menu.menu_llm"] = {
			create = function(deps)
				injected_control = deps.script_control
				injected_update_menu = deps.update_menu
				return {}
			end,
		}
		package.loaded["modules.llm"] = { set_backend = function() return true end }
		package.loaded["modules.keylogger"] = {}
		package.loaded["modules.shortcuts"] = shortcuts
		package.loaded["modules.dynamic_hotstrings"] = {}
		package.loaded["modules.gestures"] = { SINGLE_SLOTS = {}, DEFAULT_GESTURES = {} }
		package.loaded["infra.personal_shortcuts"] = { load = noop }
		package.loaded["ui.menu.init"] = nil
		local Menu = require("ui.menu.init")
		local menu = Menu.start("/virtual/", {}, {}, {}, {}, {}, nil, {})
		helpers.assert_not_nil(menu,
			"the real root menu must reach its LLM dependency-injection boundary")
		helpers.assert_true(injected_control == shortcuts,
			"ui.menu must inject the real shortcuts facade, not ScriptControl or a snapshot")
		helpers.assert_eq(injected_update_menu(), true,
			"the root adapter must acknowledge an exact menu publication")
		epoch = 43
		helpers.assert_eq(injected_control.get_pause_epoch(), 43,
			"the root-injected facade must expose the live ScriptControl epoch")
		transition_pending = true
		helpers.assert_true(injected_control.is_pause_transition_pending(),
			"the root-injected facade must expose the live transition owner")

		package.loaded["modules.llm"] = {
			BUILTIN_PROFILES = {},
			DEFAULT_STATE = { llm_num_predictions = 1 },
		}
		package.loaded["ui.menu.menu_llm.startup_controller"] = nil
		local StartupController = require("ui.menu.menu_llm.startup_controller")
		StartupController.new({
			state = {},
			keymap = {},
			models_mgr = models_mgr,
			guarded_check_requirements = function() return true end,
			save_prefs = function() return true end,
			update_menu = function() return true end,
			apply_llm_shortcut = function() return true end,
			apply_llm_profile_shortcut = function() return true end,
			activate_hotkey = function() return true end,
			mlx_deps_checker = {},
			deps = { script_control = shortcuts },
			get_startup_silence = function() return false end,
			set_startup_silence = function() return true end,
			get_trigger_hk = function() return nil end,
			get_profile_hks = function() return {} end,
		})

		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.dialog_util"] = {}
		package.loaded["infra.notifications"] = { notify = function() return true end }
		package.loaded["ui.menu.menu_llm.profile_label"] = {
			format = function(label) return label end,
		}
		package.loaded["ui.menu.menu_llm.model_switcher"] = nil
		local ModelSwitcher = require("ui.menu.menu_llm.model_switcher")
		ModelSwitcher.new({
			state = { llm_enabled = false },
			models_mgr = models_mgr,
			keymap = {},
			script_control = shortcuts,
			save_prefs = function() return true end,
			update_menu = function() return true end,
		})

		helpers.assert_eq(#requirement_capabilities, 2,
			"startup and model switching must each own a distinct manager capability")
		helpers.assert_true(requirement_capabilities[1] ~= requirement_capabilities[2])
		helpers.assert_eq(requirement_capabilities[1].label, "startup")
		helpers.assert_eq(requirement_capabilities[2].label, "model_switcher")
		helpers.assert_eq(#registrations, 2)
		helpers.assert_eq(registrations[1].name, "llm_startup")
		helpers.assert_eq(registrations[2].name, "llm_model_switcher")
		helpers.assert_eq(type(registrations[1].owner.pause), "function")
		helpers.assert_eq(type(registrations[2].owner.resume), "function")

	end)

	helpers.it("injects one registry identity into real menu startup and switch wiring", function()
		local noop = function() return true end
		local sentinel = {
			apply_preference = noop,
		}
		local facade = {}
		local switch_ctx = nil
		local startup_ctx = nil
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.notifications"] = { notify = noop }
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["ui.menu.shortcut_utils"] = {}
		package.loaded["modules.llm"] = {
			DEFAULT_STATE = {
				llm_enabled = false,
				llm_backend = "ollama",
				llm_model_ollama = "",
				llm_model_mlx = "",
				llm_num_predictions = 1,
			},
			BUILTIN_PROFILES = {},
			get_backend = function() return "ollama" end,
			get_current_model = function() return "" end,
			set_backend = function() return true end,
			set_llm_model_mlx = function() return true end,
			set_llm_model_ollama = function() return true end,
		}
		package.loaded["ui.menu.menu_llm.models_manager"] = {
			new = function()
				return {
					get_presets = function() return {} end,
					get_actual_model_name = function(value) return value end,
					get_model_info = function() return {} end,
				}
			end,
		}
		package.loaded["ui.menu.menu_llm.profiles_manager"] = {
			new = function() return { get_menu_item = function() return {} end } end,
		}
		package.loaded["ui.menu.menu_llm.settings_manager"] = {
			new = function() return {} end,
		}
		for _, name in ipairs({
			"ui.menu.menu_llm.temperature_panel",
			"ui.menu.menu_llm.streaming_panel",
			"ui.menu.menu_llm.trigger_panel",
			"ui.menu.menu_llm.api_panel",
			"ui.menu.menu_llm.models_selector",
		}) do
			package.loaded[name] = { build = function() return {} end }
		end
		package.loaded["ui.menu.menu_llm.api_panel"].build_model_picker = function() return {} end
		package.loaded["ui.menu.menu_llm.warmup_controller"] = {}
		package.loaded["ui.menu.menu_llm.backend_panel"] = {
			is_apple_silicon = function() return false end,
			build = function() return "backend", {} end,
		}
		package.loaded["ui.menu.menu_llm.model_switcher"] = {
			new = function(ctx)
				switch_ctx = ctx
				return {
					switch_model = noop,
					disable_model = noop,
					set_llm_profile = noop,
					settle_recovery_debts = noop,
					apply_recommended_prompt_profile = noop,
					get_display_model_name = function(value) return value end,
					get_model_power_level = function() return 1 end,
					guarded_check_requirements = noop,
				}
			end,
		}
		package.loaded["ui.menu.menu_llm.prediction_lock_registry"] = {
			new = function() return sentinel end,
		}
		package.loaded["modules.llm.api_mlx"] = { get_base_url = function() return "" end }
		package.loaded["ui.menu.menu_llm.startup_controller"] = {
			new = function(ctx) startup_ctx = ctx; return noop end,
		}
		package.loaded["ui.menu.menu_llm.trigger_orchestrator"] = {
			new = function()
				return {
					bind_hotkey = noop,
					activate_hotkey = noop,
					apply_llm_shortcut = noop,
					apply_llm_profile_shortcut = noop,
					restore_shortcuts = noop,
				}
			end,
		}
		package.loaded["ui.menu.menu_llm.menu_layout"] = {
			row_ids = function() return {} end,
			row_disabled = function() return false end,
			has_health_dot = function() return false end,
		}
		package.loaded["infra.manifest_menu"] = {
			render_rows = function(rows) return rows end,
			build = function() return {} end,
		}
		package.loaded["modules.llm.mlx_deps_checker"] = { check_and_install_deps = noop }
		package.loaded["modules.llm.ollama_deps_checker"] = { check_and_install_deps = noop }
		reset_module("ui.menu.menu_llm")
		local MenuLLM = require("ui.menu.menu_llm")
		local handler = MenuLLM.create({
			state = {
				llm_enabled = false,
				llm_backend = "ollama",
				llm_model = "",
				llm_profile_shortcuts = {},
			},
			keymap = {
				set_llm_model = function() return true end,
				set_llm_display_model_name = noop,
			},
			save_prefs = noop,
			update_menu = noop,
			active_tasks = {},
			script_control = facade,
		})
		helpers.assert_not_nil(handler)
		helpers.assert_true(switch_ctx.prediction_locks == sentinel)
		helpers.assert_true(startup_ctx.prediction_locks == sentinel,
			"both real factory injections must share the exact registry table")
		helpers.assert_true(switch_ctx.script_control == facade,
			"the menu must pass the exact ScriptControl facade into ModelSwitcher")
		helpers.assert_true(startup_ctx.deps.script_control == facade,
			"the menu must pass the exact ScriptControl facade into StartupController")
	end)
end)
