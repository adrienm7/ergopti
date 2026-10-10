--- tests/support/runtime_recovery_menu_fixture.lua

--- ==============================================================================
--- MODULE: Native Runtime Recovery Menu Boot Fixture
--- DESCRIPTION:
--- Boots the real ui.menu.start, MenuState, preference transaction and session
--- demotions over in-memory boundaries: a Preferences double that records every
--- save, a deferred-work queue, and runtime owners whose refusal each case can
--- inject. Tests read the live state, the saved payloads, the ERROR lines and
--- the save_prefs the menu hands to its rows.
--- ==============================================================================

local helpers = require("tests.helpers")
local M = {}





-- ====================================
-- ====================================
-- ======= 1/ Boot Over Doubles =======
-- ====================================
-- ====================================

-- Production modules this fixture runs for real; each boot reloads them so no
-- case inherits the previous case's session state.
local REAL_MODULES = {
	"ui.menu.init",
	"ui.menu.menu_state",
	"ui.menu.preferences_transaction",
	"ui.menu.session_demotions",
	"ui.menu.keymap_lifecycle",
	"ui.menu.global_actions_transaction",
	"ui.menu.recoverable_file_moves",
}

--- Deep-copies plain Lua data so fixture snapshots cannot alias live state.
--- @param value any Value to copy.
--- @return any copy
local function clone(value)
	if type(value) ~= "table" then return value end
	local copy = {}
	for key, child in pairs(value) do copy[key] = clone(child) end
	return copy
end

--- Formats one logger call the way the production logger does.
--- @param fmt any Format string or message.
--- @param ... any Format arguments.
--- @return string message
local function format_message(fmt, ...)
	if select("#", ...) == 0 then return tostring(fmt) end
	local ok, message = pcall(string.format, tostring(fmt), ...)
	return ok and message or tostring(fmt)
end

--- Returns the saved config.toml flat state every case starts from.
--- @return table saved Every feature ON, with a hotstring-editor chord.
local function saved_config()
	return {
		gestures = true,
		keylogger_enabled = true,
		llm_enabled = true,
		shortcuts = true,
		custom_editor_shortcut = { mods = { "ctrl" }, key = "k" },
	}
end

--- Boots ui.menu.start once over in-memory boundaries.
--- @param opts table Failure plan: load_status (ok, corrupt, absent), saved, editor_bind, gestures_enable,
--- gestures_query, keylogger_start.
--- @return table fixture Live state, saves, log records and the menu ctx.
function M.boot(opts)
	opts = opts or {}
	local noop = function() end
	local hs_stub = _G.hs
	-- The real Remap/configuration constructors already captured this disposable
	-- host and their exact local owners. Reinitializing them would invalidate the
	-- genuine recovery capability; presentation ports alone are supplied below.
	helpers.assert_type(hs_stub, "table")
	local retained_registrar = package.loaded["adapters.hotkey_registrar"]

	local logs = { errors = {}, warns = {} }
	local logger = helpers.make_logger_stub()
	logger.error = function(_, fmt, ...) logs.errors[#logs.errors + 1] = format_message(fmt, ...) end
	logger.warn = function(_, fmt, ...) logs.warns[#logs.warns + 1] = format_message(fmt, ...) end

	-- Pre-load defaults, as Preferences.build_initial_state produces them.
	local state = {
		trigger_char = "★",
		hotstrings = {},
		terminator_states = {},
		script_control_shortcuts = {
			return_key = "script_pause_toggle",
			backspace = "script_reload",
			escape = "script_quit",
		},
		keymap = true,
		gestures = false,
		shortcuts = true,
		llm_enabled = false,
		keylogger_enabled = false,
		script_control_enabled = true,
	}
	local saves = {}
	local deferred = {}
	local fixture = { state = state, saves = saves, logs = logs, deferred = deferred }
	-- Number of upcoming Preferences.save calls that fail to write config.toml.
	local refused_saves = 0

	for _, name in ipairs(REAL_MODULES) do package.loaded[name] = nil end
	package.loaded["infra.logger"] = logger
	package.loaded["infra.notifications"] = { notify = noop }
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["infra.ui_restore"] = {}
	package.loaded["infra.text_utils"] = {
		escape_gsub_replacement = function(value) return value end,
		shell_quote = function(value) return value end,
	}
	package.loaded["infra.deferred_work"] = {
		after = function(_delay, callback)
			deferred[#deferred + 1] = callback
			return true
		end,
	}
	package.loaded["infra.preferences"] = {
		build_initial_state = function() return state end,
		load = function()
			if opts.load_status == "corrupt" then return {}, "corrupt" end
			if opts.load_status == "absent" then return {}, "absent" end
			return clone(opts.saved or saved_config()), "ok"
		end,
		merge_saved_data = function(live, saved)
			for key, value in pairs(saved) do live[key] = clone(value) end
		end,
		snapshot = function(live) return clone(live) end,
		save = function(_path, live, _hotfiles, _core, snapshot_view)
			if refused_saves > 0 then
				refused_saves = refused_saves - 1
				return false
			end
			local snapshot = clone(live)
			if snapshot_view then snapshot = snapshot_view(snapshot) end
			saves[#saves + 1] = clone(snapshot)
			return true, snapshot, clone(live)
		end,
		get_group_name = function() return "common" end,
	}
	package.loaded["ui.hotstring_editor"] = {
		set_update_menu = noop,
		set_shortcut = function()
			if opts.editor_bind == false then return false end
			return true
		end,
		clear_shortcut = function() return true end,
	}
	package.loaded["ui.menu.builder"] = {
		generate = function(ctx, _menu_mods, actions)
			fixture.ctx = ctx
			fixture.actions = actions
			return {}
		end,
		invalidate_cache = noop,
	}
	package.loaded["ui.menu.hotstring_counter"] = { invalidate_cache = noop }
	package.loaded["ui.menu.menu_paths"] = {
		is_initialized = function() return true end,
		get = function(name)
			if name == "KarabinerConfigPath" then return opts.runtime_path() end
			return "/virtual/config.toml"
		end,
		get_config_dir = function() return "/virtual" end,
		open_editor = noop,
	}
	package.loaded["infra.factory_reset_journal"] = {
		path_for = function(config_path) return config_path .. ".ergopti-reset-journal-v1.json" end,
		create = function()
			return {
				prepare = function() return true end,
				mark_commit = function() return true end,
				mark_prepared = function() return true end,
				clear = function() return true end,
			}
		end,
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
		setMenu = function(provider)
			if type(provider) == "function" then fixture.menu_provider = provider end
			return true
		end,
		destroy = noop,
	}
	-- Keep the exact Remap-bound unbind port and owner. Menu-only registration
	-- doubles cannot replace the constructor's genuine retirement boundary.
	helpers.assert_type(retained_registrar, "table")
	retained_registrar.bind = retained_registrar.bind or function() return {} end
	retained_registrar.setEnabled = retained_registrar.setEnabled or function() return true end
	package.loaded["adapters.hotkey_registrar"] = retained_registrar
	package.loaded["infra.termination_coordinator"] = opts.terminal
	for _, module_name in ipairs({
		"ui.menu.menu_gestures", "ui.menu.menu_shortcuts", "ui.menu.menu_keyboard_layout",
		"ui.menu.menu_hotstrings", "ui.menu.menu_metrics", "ui.menu.menu_tap_holds",
		"ui.menu.menu_apps", "ui.menu.menu_about",
	}) do
		package.loaded[module_name] = {}
	end
	package.loaded["ui.menu.menu_llm"] = { create = function() return {} end }
	package.loaded["infra.personal_shortcuts"] = { load = noop }
	package.loaded["modules.dynamic_hotstrings"] = {}
	package.loaded["modules.gestures"] = {
		SINGLE_SLOTS = { "swipe_left" }, DEFAULT_GESTURES = { swipe_left = "none" },
	}
	package.loaded["modules.keylogger.text_cipher"] = { set_enabled = function() return true end }

	local identity = function() return true end
	package.loaded["modules.llm"] = {
		set_backend = identity,
		set_user_profiles = identity,
		set_active_profile = identity,
		set_llm_model_ollama = identity,
		set_llm_model_mlx = identity,
	}
	package.loaded["modules.keylogger"] = {
		set_options = noop,
		set_disabled_apps = noop,
		start = function()
			if opts.keylogger_start == false then return false end
			return true
		end,
		stop = function() return true end,
	}
	package.loaded["modules.shortcuts"] = {
		DEFAULT_STATE = { script_control_shortcuts = clone(state.script_control_shortcuts) },
		is_paused = function() return false end,
		set_on_pause_change = noop,
		set_shortcut_action = function() return true end,
		set_extras = noop,
		set_wrap_pairs_getter = function(getter) fixture.wrap_pairs_getter = getter end,
		set_chatgpt_url = noop,
		list_shortcuts = function() return {} end,
		pause_bindings = function() return true end,
		resume_bindings = function() return true end,
		enable = function() return true end,
		disable = function() return true end,
		get_keyboard_action = function() return nil end,
		set_keyboard_action = function() return true end,
		get_keyboard_assignments = function() return {} end,
	}

	local runtime = { gestures = false }
	fixture.runtime = runtime
	local refuse_gesture_assignment_at = nil
	fixture.gesture_assignment_refusals = 0
	fixture.gesture_assignment_calls = 0
	--- Refuses one setter boundary after a controlled number of calls.
	--- @param count number Calls until refusal, including the refused call.
	function fixture.refuse_gesture_assignment_after(count)
		refuse_gesture_assignment_at = fixture.gesture_assignment_calls + count
	end
	local gestures = {
		configure_program_admission = function(callback)
			helpers.assert_type(callback, "function")
			fixture.program_admission = callback
			return true
		end,
		-- `runtime.refuse_enable` lets a case refuse ON after a successful boot.
		enable_all = function()
			if opts.gestures_enable == false or runtime.refuse_enable == true then return false end
			runtime.gestures = true
			return true
		end,
		disable_all = function()
			runtime.gestures = false
			return true
		end,
		is_enabled = function()
			if opts.gestures_query == "throw" then error("gesture state query refused", 0) end
			return runtime.gestures
		end,
		get_action = function() return "none" end,
		set_action = function()
			fixture.gesture_assignment_calls = fixture.gesture_assignment_calls + 1
			if fixture.gesture_assignment_calls == refuse_gesture_assignment_at then
				refuse_gesture_assignment_at = nil
				fixture.gesture_assignment_refusals = fixture.gesture_assignment_refusals + 1
				return false
			end
			return true
		end,
	}
	local keymap = {
		start = function() return true end,
		set_llm_model = function() return true end,
		set_llm_enabled = function() return true end,
		is_processing_paused = function() return false end,
		-- Enable All requires the preview switches to commit exactly.
		set_preview_star_enabled = function() return true end,
		set_preview_autocorrect_enabled = function() return true end,
		set_preview_ai_enabled = function() return true end,
	}

	local Menu = require("ui.menu.init")
	-- Tap-Holds owner with the surface the global actions require.
	local karabiner = opts.karabiner or {
		snapshot_settings = function() return {} end,
		reset_to_defaults = function() return true end,
		get_tap_holds_enabled = function() return false end,
		set_tap_holds_enabled = function() return true end,
		get_mod_combos_enabled = function() return false end,
		set_mod_combos_enabled = function() return true end,
		regenerate = function(callback)
			if type(callback) == "function" then callback(true) end
			return true
		end,
		restore_settings = function() return true end,
	}
	-- The two presentation warm-up acquisitions are separate observations from
	-- Remap's first-run acquisitions. Retain the shared host owner and its exact
	-- cancel role; the temporary after double records only this Menu.start call.
	local timers = package.loaded["adapters.timer_scheduler"]
	local original_after = timers.after
	fixture.presentation_timers = {}
	timers.after = function(delay, callback)
		local timer = { delay = delay, callback = callback, committed = true, timer = {} }
		fixture.presentation_timers[#fixture.presentation_timers + 1] = timer
		deferred[#deferred + 1] = callback
		return timer, true
	end
	local started, menu_or_error = pcall(Menu.start, "/virtual/", {}, gestures, keymap, {}, {}, karabiner, {})
	timers.after = original_after
	if not started then error(menu_or_error, 0) end
	fixture.menu = menu_or_error
	helpers.assert_type(fixture.program_admission, "function", "menu startup registers its required program admission owner")
	fixture.boot_saves = #saves

	--- Returns the transactional save the menu hands to every row callback.
	--- @return function save_prefs
	function fixture.save_prefs()
		if not fixture.ctx then
			helpers.assert_true(type(fixture.menu_provider) == "function",
				"the fixture must capture the dynamic menu provider")
			fixture.menu_provider()
		end
		helpers.assert_true(fixture.ctx ~= nil and type(fixture.ctx.save_prefs) == "function",
			"the menu builder context must expose save_prefs")
		return fixture.ctx.save_prefs()
	end

	--- Makes the next Preferences.save fail, as a full disk or a lost volume does.
	function fixture.refuse_next_save()
		refused_saves = refused_saves + 1
	end

	--- Returns the global actions table the menu hands to its builder.
	--- @return table actions
	function fixture.global_actions()
		if not fixture.actions then fixture.menu_provider() end
		helpers.assert_true(type(fixture.actions) == "table",
			"the menu builder must receive the global actions")
		return fixture.actions
	end

	--- Runs every deferred sync callback (hotkey warm-up, keylogger start).
	function fixture.flush_deferred()
		local pending = {}
		for index, callback in ipairs(deferred) do pending[index] = callback end
		for index = #deferred, 1, -1 do deferred[index] = nil end
		for _, callback in ipairs(pending) do callback() end
	end

	--- Returns whether any ERROR line contains every given plain fragment.
	--- @param ... string Plain-text fragments.
	--- @return boolean found
	function fixture.has_error(...)
		local fragments = { ... }
		for _, message in ipairs(logs.errors) do
			local all = true
			for _, fragment in ipairs(fragments) do
				if not message:find(fragment, 1, true) then all = false; break end
			end
			if all then return true end
		end
		return false
	end

	return fixture
end

return M
