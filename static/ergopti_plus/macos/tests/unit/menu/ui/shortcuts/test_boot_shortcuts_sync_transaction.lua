--- tests/unit/menu/ui/shortcuts/test_boot_shortcuts_sync_transaction.lua

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
	local hs_stub = helpers.load_with_stubs("core.logger.engine.logger") and _G.hs
	hs_stub.__reset()
	local runtime = { bindings = true, keyboard = true }
	local script_actions = { return_key = "script_pause_toggle", backspace = "script_reload", escape = "script_quit" }
	local menu_context
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
		keystats_enabled = true,
		script_control_enabled = true,
		personal_info = true,
		update_channel = "dev",
		update_check_interval_seconds = 3600,
	}

	package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
	package.loaded["core.ui.engine.notifications"] = { notify = noop }
	package.loaded["hotstrings.ui.hotstring_editor"] = { set_update_menu = noop }
	package.loaded["core.text.engine.utils"] = {
		escape_gsub_replacement = function(value) return value end,
		shell_quote = function(value) return value end,
	}
	package.loaded["core.i18n.engine.i18n"] = { get = function(key) return key end }
	package.loaded["menu.engine.ui_restore"] = {}
	package.loaded["settings.engine.preferences.preferences"] = {
		build_initial_state = function() return state end,
		load = function() return { shortcuts = opts.script_rollback == true }, "present" end,
		merge_saved_data = function(live, saved)
			live.shortcuts = saved.shortcuts
		end,
		snapshot = function(live)
			snapshotted_shortcuts = live.shortcuts
			return { shortcuts = live.shortcuts }
		end,
		save = function()
			if opts.script_rollback then script_actions.return_key = "foreign"; return false end
			return true
		end,
		get_group_name = function() return "common" end,
	}
	package.loaded["menu.ui.builder.builder"] = {
		generate = function(ctx) menu_context = ctx; return {} end,
		get_last_item_timings = function() return {} end,
		invalidate_cache = noop,
	}
	package.loaded["hotstrings.ui.menu.counter"] = { invalidate_cache = noop }
	package.loaded["settings.ui.menu.paths"] = {
		is_initialized = function() return true end,
		get = function() return "/virtual/config.toml" end,
		get_config_dir = function() return "/virtual" end,
		open_editor = noop,
	}
	package.loaded["settings.engine.factory_reset_journal"] = {
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
	package.loaded["menu.ui.keyboard.keymap_lifecycle"] = {
		ensure_started = function() return true end,
	}
	package.loaded["menu.ui.builder.watchers"] = {
		start_config_watcher = function() return { stop = function() return true end } end,
		start_theme_watcher = function() return { stop = function() return true end } end,
	}
	package.loaded["modules.updater"] = {
		get_check_interval = function() return 3600 end,
		start_background_checks = noop,
	}
	package.loaded["tray.adapters.menu"] = {
		adopt = function() return true end,
		setMenu = function() return true end,
		destroy = function() destroyed = destroyed + 1 end,
	}
	package.loaded["keyboard.engine.chord"] = { format = function() return "ctrl+x" end }
	package.loaded["platform.input.hotkey_registrar"] = {
		bind = function() return {} end,
		setEnabled = function() return true end,
		unbind = function() return true end,
	}
	package.loaded["core.lifecycle.engine.shutdown.termination_coordinator"] = {
		request_exit = function() return true end,
	}

	for _, module_name in ipairs({
		"gestures.ui.menu.gestures", "ui.menu.menu_shortcuts", "layouts.ui.menu.keyboard_layout",
		"hotstrings.ui.menu.hotstrings", "metrics.ui.menu.metrics", "ui.menu.menu_tap_holds",
		"apps.ui.menu.apps", "ui.menu.menu_about",
	}) do
		package.loaded[module_name] = {}
	end
	package.loaded["ai.ui.menu"] = { create = function() return {} end }
	package.loaded["ai.engine"] = { set_backend = noop }
	package.loaded["metrics.engine"] = {}
	local shortcuts = {
		is_paused = function() return false end,
		set_on_pause_change = noop,
		get_shortcut_actions = function() return script_actions end,
		set_shortcut_action = function(slot, value) script_actions[slot] = value; return true end,
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
	package.loaded["hotstrings.engine.dynamic"] = {}
	package.loaded["gestures.engine"] = { SINGLE_SLOTS = { "swipe_left" } }
	package.loaded["infra.personal_shortcuts"] = { load = noop }
	package.loaded["menu.ui.builder.state"] = {
		sync_state_to_modules = function(live, _saved, _absent, deps)
			sync_states[#sync_states + 1] = live.shortcuts
			if live.shortcuts then
				if opts.script_rollback and deps.restoring then
					deps.core_mods.shortcuts_mod.set_shortcut_action("return_key", live.script_control_shortcuts.return_key)
				end
				return deps.core_mods.shortcuts_mod.resume_bindings()
			end
			return deps.core_mods.shortcuts_mod.pause_bindings()
		end,
	}

	if opts.script_rollback then
		package.loaded["menu.ui.transactions.global_actions_transaction"] = { create = function() return {
			run_exclusive = function(_, callback) return callback() end,
			is_pending = function() return false end,
			is_exclusive_blocked = function() return false end,
		} end }
	end
	package.loaded["ui.menu.init"] = nil
	local Menu = require("ui.menu.init")
	local program_admission
	local gestures = { configure_program_admission = function(callback)
		helpers.assert_type(callback, "function")
		program_admission = callback
		return true
	end }
	local menu = Menu.start("/virtual/", {}, gestures, {}, {}, {}, nil, {})
	helpers.assert_type(program_admission, "function", "startup registers its required program admission owner")
	return {
		menu = menu,
		controller = Menu,
		menu_context = function() return menu_context end,
		script_actions = script_actions,
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
	helpers.it("preserves a foreign script action when a menu save is refused", function()
		helpers.with_stub_scope({ "menu.ui.transactions.global_actions_transaction", "ui.menu.init" }, function()
			local fixture = load_fixture({ script_rollback = true })
			pcall(fixture.controller.timed_rebuild)
			local ctx = assert(fixture.menu_context(), "menu builder must receive its real context")
			helpers.assert_eq(ctx.commit_script_action("return_key", "script_reload"), false)
			helpers.assert_eq(fixture.script_actions.return_key, "foreign")
		end)
	end)
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
