--- tests/unit/ui/menu/test_boot_shortcuts_sync_transaction.lua

--- ==============================================================================
--- MODULE: Boot Shortcut Preference Synchronization Transaction Regression
--- DESCRIPTION:
--- Drives ui.menu.start through a persisted Shortcuts=OFF request whose runtime
--- pause partially applies and returns false. Boot must restore the pre-load ON
--- state before snapshotting or rendering, never publish an OFF/runtime-ON lie.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Installs in-memory menu boundaries around the real ui.menu.start controller.
--- @param opts table|nil Failure-plan overrides.
--- @return table fixture Runtime state and boot observations.
local function load_fixture(opts)
	opts = opts or {}
	local noop = function() end
	local hs_stub = helpers.load_with_stubs("infra.logger") and _G.hs
	hs_stub.__reset()
	local runtime = { bindings = true, keyboard = true }
	local sync_states = {}
	local snapshotted_shortcuts = nil
	local destroyed = 0
	local state = {
		trigger_char = "â˜…",
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
		load = function() return { shortcuts = false }, "present" end,
		merge_saved_data = function(live, saved)
			live.shortcuts = saved.shortcuts
		end,
		snapshot = function(live)
			snapshotted_shortcuts = live.shortcuts
			return { shortcuts = live.shortcuts }
		end,
		save = function() return true end,
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
	package.loaded["ui.menu.keymap_lifecycle"] = {
		ensure_started = function() return true end,
	}
	package.loaded["ui.menu.menu_watchers"] = {
		start_config_watcher = function() return { stop = function() return true end } end,
		start_theme_watcher = function() return { stop = function() return true end } end,
	}
	package.loaded["modules.updater"] = {
		get_check_interval = function() return 3600 end,
		start_background_checks = noop,
	}
	package.loaded["adapters.tray_menu"] = {
		adopt = function() return true end,
		setMenu = noop,
		destroy = function() destroyed = destroyed + 1 end,
	}
	package.loaded["chord"] = { format = function() return "ctrl+x" end }
	package.loaded["adapters.hotkey_registrar"] = {
		bind = function() return {} end,
		setEnabled = function() return true end,
		unbind = function() return true end,
	}
	package.loaded["infra.termination_coordinator"] = {
		request_exit = function() return true end,
	}

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
		set_extras = noop,
		list_shortcuts = function() return {} end,
		pause_bindings = function()
			runtime.bindings = false
			-- The second child remains live: this is the exact partial-stop failure.
			return false
		end,
		resume_bindings = function()
			runtime.bindings = true
			runtime.keyboard = true
			return opts.rollback_result ~= false
		end,
	}
	package.loaded["modules.shortcuts"] = shortcuts
	package.loaded["modules.dynamic_hotstrings"] = {}
	package.loaded["modules.gestures"] = { SINGLE_SLOTS = { "swipe_left" } }
	package.loaded["infra.personal_shortcuts"] = { load = noop }
	package.loaded["ui.menu.menu_state"] = {
		sync_state_to_modules = function(live, _saved, _absent, deps)
			sync_states[#sync_states + 1] = live.shortcuts
			if live.shortcuts then return deps.core_mods.shortcuts_mod.resume_bindings() end
			return deps.core_mods.shortcuts_mod.pause_bindings()
		end,
	}

	package.loaded["ui.menu.init"] = nil
	local Menu = require("ui.menu.init")
	local menu = Menu.start("/virtual/", {}, {}, {}, {}, {}, nil, {})
	return {
		menu = menu,
		state = state,
		runtime = runtime,
		sync_states = sync_states,
		destroyed = function() return destroyed end,
		snapshotted_shortcuts = function() return snapshotted_shortcuts end,
	}
end





-- =============================================
-- =============================================
-- ======= 1/ Boot Sync Failure Rollback =======
-- =============================================
-- =============================================

helpers.describe("menu boot preference synchronization is transactional", function()
	helpers.it("restores runtime and menu state when persisted Shortcuts OFF is refused", function()
		local fixture = load_fixture()
		helpers.assert_not_nil(fixture.menu,
			"a successful rollback may keep the truthful menu available")
		helpers.assert_eq(fixture.sync_states, { false, true },
			"boot must re-synchronize the pre-load state after exact false")
		helpers.assert_true(fixture.runtime.bindings and fixture.runtime.keyboard,
			"partial pause effects must be reversed before startup continues")
		helpers.assert_eq(fixture.state.shortcuts, true,
			"the menu state must describe the restored live runtime")
		helpers.assert_eq(fixture.snapshotted_shortcuts(), true,
			"the preference transaction must never seed itself from rejected OFF state")
	end)

	helpers.it("aborts the menubar when even the pre-load runtime cannot be restored", function()
		local fixture = load_fixture({ rollback_result = false })
		helpers.assert_nil(fixture.menu,
			"an unverified runtime posture must not publish a potentially lying menu")
		helpers.assert_eq(fixture.sync_states, { false, true })
		helpers.assert_eq(fixture.destroyed(), 1,
			"startup abort must release the menubar capability it already adopted")
		helpers.assert_nil(fixture.snapshotted_shortcuts(),
			"no preference transaction may be seeded after rollback refusal")
	end)
end)

return true
