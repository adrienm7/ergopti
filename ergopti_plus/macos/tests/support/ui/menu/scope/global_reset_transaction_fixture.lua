--- tests/support/ui/menu/scope/global_reset_transaction_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_global_reset_transaction
--- DESCRIPTION:
--- Prelude shared by the test_global_reset_transaction_* test files: their modules, default
--- state and scenario fixture. Each test file loads it fresh, so no state
--- leaks from one file to the next.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULE_KEYS = {
	"ui.menu.metrics_scope",
	"ui.menu.hotstrings_scope",
	"modules.hotstrings.hotstrings_config",
	"ui.menu.global_scope",
	"ui.menu.scoped_preferences",
	"ui.menu.gesture_scope",
	"infra.dialog_util",
	"infra.logger",
	"infra.notifications",
	"ui.hotstring_editor",
	"infra.text_utils",
	"infra.i18n",
	"infra.ui_restore",
	"infra.preferences",
	"ui.menu.builder",
	"ui.menu.hotstring_counter",
	"ui.menu.menu_paths",
	"ui.menu.menu_state",
	"ui.menu.keymap_lifecycle",
	"ui.menu.menu_watchers",
	"modules.updater",
	"adapters.file_system",
	"adapters.storage",
	"adapters.tray_menu",
	"chord",
	"adapters.hotkey_registrar",
	"infra.termination_coordinator",
	"infra.factory_reset_journal",
	"ui.menu.recoverable_file_moves",
	"ui.menu.global_actions_transaction",
	"ui.menu.menu_gestures",
	"ui.menu.menu_shortcuts",
	"ui.menu.menu_keyboard_layout",
	"ui.menu.menu_hotstrings",
	"ui.menu.menu_metrics",
	"ui.menu.menu_tap_holds",
	"ui.menu.menu_apps",
	"ui.menu.menu_about",
	"ui.menu.menu_llm",
	"modules.llm",
	"modules.keylogger",
	"modules.shortcuts",
	"modules.dynamic_hotstrings",
	"modules.gestures",
	"infra.personal_shortcuts",
	"ui.menu.preferences_transaction",
	"ui.menu.program_parameter_transaction",
	"ui.menu.init",
}

local SCRIPT_SLOTS = { "script_altgr_enter", "script_altgr_backspace", "script_altgr_delete", "script_altgr_escape" }

--- Clones nested test values without sharing keys or children.
--- @param value any Source value.
--- @return any clone
local function clone(value)
	if type(value) ~= "table" then return value end
	local copy = {}
	for key, child in pairs(value) do copy[clone(key)] = clone(child) end
	return copy
end

--- Returns a mutable failure descriptor consumed only once by default.
--- @param mode string Failure mode.
--- @param count integer|nil Number of calls to reject.
--- @return table descriptor
local function fail(mode, count)
	return { mode = mode, remaining = count or 1 }
end

--- Delivers one hostile reentrant hook exactly once.
--- @param observations table Fixture observations.
--- @param label string Boundary label.
--- @param phase string Boundary phase.
local function run_hook(observations, label, phase)
	local key = label .. ":" .. phase
	local hook = observations.hooks and observations.hooks[key] or nil
	if type(hook) ~= "function" then return end
	observations.hooks[key] = nil
	hook()
end

--- Invokes one faithful mutation boundary with optional refusal or late throw.
--- @param observations table Fixture observations.
--- @param label string Boundary label.
--- @param mutation function Mutation to make observable.
--- @return any result
local function perform(observations, label, mutation)
	observations.calls[label] = (observations.calls[label] or 0) + 1
	run_hook(observations, label, "before")
	local function apply_mutation()
		mutation()
		run_hook(observations, label, "after")
	end
	local descriptor = observations.armed and observations.failures[label] or nil
	if descriptor and descriptor.remaining > 0 then
		descriptor.remaining = descriptor.remaining - 1
		if descriptor.mode == "throw" then error("synthetic " .. label .. " throw") end
		if descriptor.mode == "throw-after" then
			apply_mutation()
			error("synthetic " .. label .. " throw after mutation")
		end
		if descriptor.mode == "false-after" then
			apply_mutation()
			return false
		end
		if descriptor.mode == "nil-after" then
			apply_mutation()
			return nil
		end
		if descriptor.mode == "false" then return false end
		if descriptor.mode == "nil" then return nil end
	end
	apply_mutation()
	return true
end

--- Dispatches a faithful asynchronous Karabiner request.
--- @param observations table Fixture observations.
--- @param label string Request boundary label.
--- @param mutation function Candidate publication.
--- @param on_done function Exact terminal callback.
--- @return any accepted
local function dispatch_karabiner(observations, label, mutation, on_done)
	observations.calls[label] = (observations.calls[label] or 0) + 1
	local descriptor = observations.armed and observations.failures[label] or nil
	local mode = descriptor and descriptor.remaining > 0 and descriptor.mode or "sync-success"
	if descriptor and descriptor.remaining > 0 then descriptor.remaining = descriptor.remaining - 1 end
	if mode == "throw" then error("synthetic " .. label .. " throw") end
	if mode == "false" then return false end
	if mode == "nil" then return nil end
	mutation()
	if mode == "pending" then
		observations.terminals[label] = on_done
		return true
	end
	if mode == "sync-success-false" then
		on_done(true, "ready")
		return false
	end
	if mode == "sync-success-nil" then
		on_done(true, "ready")
		return nil
	end
	if mode == "sync-failure" then
		on_done(false, "synthetic-terminal-refusal")
		return true
	end
	on_done(true, "ready")
	return true
end

--- Installs one isolated ui.menu.start fixture and restores every cache entry.
--- @param options table|nil Failure and behavior overrides.
--- @param callback function Receives the live fixture.
local function with_menu_fixture(options, callback)
	options = options or {}
	local saved_modules = {}
	for _, module_name in ipairs(MODULE_KEYS) do
		saved_modules[module_name] = package.loaded[module_name]
		package.loaded[module_name] = nil
	end
	local saved_hs = _G.hs
	local saved_hs_module = package.loaded["hs"]
	local saved_hs_stub_module = package.loaded["tests.stubs.hs"]
	package.loaded["tests.stubs.hs"] = nil
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub

	local noop = function() return true end
	local state = {
		trigger_char = "★",
		hotstrings = { common = true, work = true },
		terminator_states = { space = true },
		script_control_shortcuts = {
			script_altgr_enter = "script_pause_toggle",
			script_altgr_backspace = "script_reload",
			script_altgr_delete = "open_personal_shortcuts",
			script_altgr_escape = "script_quit",
		},
		preview_star_enabled = true,
		preview_autocorrect_enabled = true,
		preview_ai_enabled = true,
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
	local observations = {
		actions = nil,
		armed = false,
		calls = {},
		failures = clone(options.failures or {}),
		hooks = {},
		terminals = {},
		notifications = {},
		state = state,
		initial_state = clone(state),
		gestures = { swipe_left = "mission_control", swipe_right = "app_switcher" },
		initial_gestures = nil,
		script = clone(state.script_control_shortcuts),
		initial_script = nil,
		keyboard = { cmd_x = "copy_selection", alt_v = "paste_plain" },
		initial_keyboard = nil,
		settings = {
			keyboard_shortcut_cmd_x = "copy_selection",
			keyboard_shortcut_alt_v = "paste_plain",
			llm_api_entries = { { id = "old", endpoint = "https://old.invalid" } },
			llm_api_entry_id = "old",
		},
		initial_settings = nil,
		files = {
			["/virtual/config.toml"] = "feature = true\n",
			["/virtual/config_karabiner.toml"] = "tap = old\n",
		},
		initial_files = nil,
		karabiner_state = { profile = "old", tap = "escape", hold = "left_control" },
		initial_karabiner = nil,
		persisted = nil,
		reload_commits = 0,
		reload_finalized = false,
		reload_abort = nil,
		termination_pending = false,
		post_reload_effects = 0,
		gesture_enabled = true,
		tap_holds_enabled = true,
		-- Named shortcut 'alpha' keeps Bindings' two axes apart: named_shortcut is
		-- the user preference, named_bound the native hotkey, bindings_paused the
		-- admission fence menu_state closes whenever Shortcuts is off.
		named_shortcut = true,
		named_bound = true,
		bindings_paused = false,
		persisted_shortcut_keys = nil,
		enable_preflight_calls = 0,
		config_watcher_callback = nil,
		builder_ctx = nil,
		dynamic_menu_callback = nil,
	}
	observations.initial_gestures = clone(observations.gestures)
	observations.initial_script = clone(observations.script)
	observations.initial_keyboard = clone(observations.keyboard)
	observations.initial_settings = clone(observations.settings)
	observations.initial_files = clone(observations.files)
	observations.initial_karabiner = clone(observations.karabiner_state)
	observations.persisted = clone(state)

	local function logger_stub()
		local logger = {}
		for _, level in ipairs({ "debug", "done", "error", "info", "start", "success", "trace", "warn" }) do
			logger[level] = function()
				if observations.reload_finalized then
					observations.post_reload_effects = observations.post_reload_effects + 1
				end
				return true
			end
		end
		return logger
	end

	-- Assigned with the other runtime doubles below. Preferences.snapshot reads
	-- [shortcuts.keys] from list_shortcuts(), so the doubles must too: deriving
	-- them from the Shortcuts master switch encoded the very bug under test.
	local shortcuts

	--- Mirrors Preferences.snapshot's [shortcuts.keys] collection.
	--- @return table keys Preference per named shortcut id.
	local function listed_shortcut_keys()
		local keys = {}
		for _, shortcut in ipairs(shortcuts.list_shortcuts()) do
			keys[shortcut.id] = shortcut.enabled
		end
		return keys
	end

	package.loaded["infra.logger"] = logger_stub()
	package.loaded["infra.notifications"] = {
		notify = function(label, _, level)
			if observations.reload_finalized then
				observations.post_reload_effects = observations.post_reload_effects + 1
			end
			observations.notifications[#observations.notifications + 1] = {
				label = label,
				level = level,
			}
			return true
		end,
	}
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
		get_group_name = function() return "common" end,
		snapshot = function(candidate)
			local snapshot = clone(candidate)
			run_hook(observations, "preferences-snapshot", "after-clone")
			snapshot.gesture_actions = clone(observations.gestures)
			snapshot.shortcut_keys = listed_shortcut_keys()
			return snapshot
		end,
		save = function(_, candidate, _hotfiles, _core, snapshot_view)
			local runtime = clone(candidate)
			runtime.gesture_actions = clone(observations.gestures)
			runtime.shortcut_keys = listed_shortcut_keys()
			local snapshot = clone(runtime)
			if snapshot_view then snapshot = snapshot_view(snapshot) end
			local result = perform(observations, "preferences", function()
				-- State and module-owned shortcuts have separate observations below.
				observations.persisted = {}
				for key in pairs(candidate) do observations.persisted[key] = clone(snapshot[key]) end
				observations.persisted_shortcut_keys = clone(snapshot.shortcut_keys)
			end)
			if result ~= true then return result end
			return true, snapshot, runtime
		end,
	}
	package.loaded["ui.menu.builder"] = {
		generate = function(ctx)
			observations.builder_ctx = ctx
			return {}
		end,
		invalidate_cache = noop,
	}
	package.loaded["ui.menu.hotstring_counter"] = { invalidate_cache = noop }
	package.loaded["ui.menu.menu_paths"] = {
		is_initialized = function() return true end,
		get = function(key)
			if key == "ConfigTomlPath" then return "/virtual/config.toml" end
			if key == "KarabinerConfigPath" then return "/virtual/config_karabiner.toml" end
			return "/virtual/unused"
		end,
		get_config_dir = function() return "/virtual" end,
		open_editor = noop,
	}
	package.loaded["ui.menu.menu_state"] = {
		metrics_start_pending = function() return false end,
		-- Same order as menu_state: the Shortcuts switch opens or closes the
		-- admission fence first, then every saved key is replayed behind it.
		sync_state_to_modules = function(live_state, saved)
			return perform(observations, "runtime-sync", function()
				observations.bindings_paused = live_state.shortcuts ~= true
				if type(saved) == "table" and type(saved.shortcut_keys) == "table" then
					observations.named_shortcut = saved.shortcut_keys.alpha == true
				end
				observations.named_bound = not observations.bindings_paused
					and observations.named_shortcut
			end)
		end,
	}
	package.loaded["ui.menu.menu_watchers"] = {
		start_config_watcher = function(_, callback)
			observations.config_watcher_callback = callback
			return { stop = noop }
		end,
		start_theme_watcher = function() return { stop = noop } end,
	}
	package.loaded["modules.updater"] = {
		get_check_interval = function() return 3600 end,
		start_background_checks = noop,
	}
	package.loaded["adapters.tray_menu"] = {
		adopt = noop,
		setMenu = function(items)
			if type(items) == "function" then observations.dynamic_menu_callback = items end
			return true
		end,
	}
	package.loaded["chord"] = { format = function() return "ctrl+x" end }
	package.loaded["adapters.hotkey_registrar"] = {
		bind = function() return {} end,
		setEnabled = function() return true end,
		unbind = function() return true end,
	}
	package.loaded["infra.termination_coordinator"] = {
		request_user_exit = function()
			observations.calls.exit = (observations.calls.exit or 0) + 1
			local descriptor = observations.armed and observations.failures.exit or nil
			local mode = descriptor and descriptor.remaining > 0 and descriptor.mode or "pending"
			if descriptor and descriptor.remaining > 0 then descriptor.remaining = descriptor.remaining - 1 end
			if mode == "throw" then error("synthetic exit throw") end
			if mode == "false" then return false end
			if mode == "nil" then return nil end
			observations.termination_pending = true
			return true
		end,
		request_reload = function(reason)
			observations.calls.manual_reload = (observations.calls.manual_reload or 0) + 1
			observations.last_reload_reason = reason
			local descriptor = observations.armed and observations.failures["manual-reload"] or nil
			local mode = descriptor and descriptor.remaining > 0 and descriptor.mode or "pending"
			if descriptor and descriptor.remaining > 0 then descriptor.remaining = descriptor.remaining - 1 end
			if mode == "throw" then error("synthetic manual reload throw") end
			if mode == "false" then return false end
			if mode == "nil" then return nil end
			if mode == "success" then
				observations.reload_commits = observations.reload_commits + 1
				observations.reload_finalized = true
				return true
			end
			observations.termination_pending = true
			return true
		end,
		request_reload_owned = function(_reason, on_aborted)
			observations.calls.reload = (observations.calls.reload or 0) + 1
			local descriptor = observations.armed and observations.failures.reload or nil
			local mode = descriptor and descriptor.remaining > 0 and descriptor.mode or "success"
			if descriptor and descriptor.remaining > 0 then
				descriptor.remaining = descriptor.remaining - 1
			end
			if mode == "throw" then error("synthetic reload throw") end
			if mode == "false" then return false end
			if mode == "nil" then return nil end
			if mode == "pending" then
				observations.termination_pending = true
				observations.reload_abort = function(detail)
					observations.termination_pending = false
					return on_aborted(detail)
				end
				return true
			end
			observations.reload_commits = observations.reload_commits + 1
			observations.reload_finalized = true
			return true
		end,
		is_pending = function()
			return observations.termination_pending or observations.reload_abort ~= nil
		end,
	}

	local file_mover = {}
	function file_mover.capture(path)
		local existed = observations.files[path] ~= nil
		return {
			path = path,
			backup = path .. ".ergopti-reset-backup",
			content = observations.files[path],
			existed = existed,
			identity = existed and {
				dev = 1,
				ino = path == "/virtual/config.toml" and 1 or 2,
			} or nil,
			moved = false,
		}
	end
	function file_mover.move(entry)
		return perform(observations, "file-move:" .. entry.path, function()
			if entry.content ~= nil then
				observations.files[entry.backup] = observations.files[entry.path]
				observations.files[entry.path] = nil
				entry.moved = true
			end
		end)
	end
	function file_mover.restore(entry)
		return perform(observations, "file-restore:" .. entry.path, function()
			if entry.moved then
				observations.files[entry.path] = observations.files[entry.backup]
				observations.files[entry.backup] = nil
				entry.moved = false
			end
		end)
	end
	package.loaded["ui.menu.recoverable_file_moves"] = {
		create = function() return file_mover end,
	}
	local reset_journal = {
		prepare = function(_, entries)
			return perform(observations, "reset-journal:prepared", function()
				observations.reset_journal_phase = "prepared"
				observations.reset_journal_entries = clone(entries)
			end)
		end,
		mark_commit = function()
			return perform(observations, "reset-journal:commit", function()
				observations.reset_journal_phase = "commit"
			end)
		end,
		mark_prepared = function()
			return perform(observations, "reset-journal:rollback", function()
				observations.reset_journal_phase = "prepared"
			end)
		end,
		clear = function()
			return perform(observations, "reset-journal:cleared", function()
				observations.reset_journal_phase = "cleared"
			end)
		end,
	}
	package.loaded["infra.factory_reset_journal"] = {
		path_for = function(path) return path .. ".ergopti-reset-journal-v1.json" end,
		create = function() return reset_journal end,
	}

	for _, module_name in ipairs({
		"ui.menu.menu_gestures", "ui.menu.menu_shortcuts", "ui.menu.menu_keyboard_layout",
		"ui.menu.menu_hotstrings", "ui.menu.menu_metrics", "ui.menu.menu_tap_holds",
		"ui.menu.menu_apps", "ui.menu.menu_about",
	}) do
		package.loaded[module_name] = {}
	end
	package.loaded["ui.menu.menu_llm"] = { create = function() return {} end }
	package.loaded["modules.llm"] = { set_backend = noop }
	package.loaded["modules.keylogger"] = {}
	package.loaded["modules.dynamic_hotstrings"] = {}
	package.loaded["infra.personal_shortcuts"] = { load = noop }
	package.loaded["modules.gestures"] = {
		SINGLE_SLOTS = { "swipe_left", "swipe_right" },
		DEFAULT_GESTURES = { swipe_left = "desktop_left", swipe_right = "desktop_right" },
	}

	shortcuts = {
		DEFAULT_STATE = {
			script_control_shortcuts = {
				script_altgr_enter = "script_pause_toggle",
				script_altgr_backspace = "script_reload",
				script_altgr_delete = "open_personal_shortcuts",
				script_altgr_escape = "script_quit",
			},
		},
		is_paused = function() return false end,
		set_on_pause_change = noop,
		set_extras = function(candidate)
			-- The menu hands its actions table here too; the reset marks it.
			if type(candidate) == "table" and type(candidate.factory_reset) == "function" then
				observations.actions = candidate
			end
			return true
		end,
		list_shortcuts = function()
			return { {
				id = "alpha",
				enabled = observations.named_shortcut == true,
				bound = observations.named_bound == true,
			} }
		end,
		disable = function()
			return perform(observations, "named-shortcut:alpha", function()
				observations.named_shortcut = false
				observations.named_bound = false
			end)
		end,
		-- Like Bindings.enable: behind the admission fence only the preference is
		-- recorded; the native hotkey appears when the layer resumes.
		enable = function()
			return perform(observations, "named-shortcut:alpha", function()
				observations.named_shortcut = true
				observations.named_bound = not observations.bindings_paused
			end)
		end,
		set_shortcut_action = function(slot, action)
			return perform(observations, "script:" .. slot, function()
				observations.script[slot] = action
			end)
		end,
		get_keyboard_assignments = function() return clone(observations.keyboard) end,
		get_keyboard_action = function(slot) return observations.keyboard[slot] or "none" end,
		set_keyboard_action = function(slot, action)
			return perform(observations, "keyboard:" .. slot, function()
				observations.keyboard[slot] = action
				observations.settings["keyboard_shortcut_" .. slot] = action
			end)
		end,
	}
	package.loaded["modules.shortcuts"] = shortcuts

	local gestures = {
		configure_program_admission = function(callback)
			if type(callback) ~= "function" or observations.program_admission ~= nil then return false end
			observations.program_admission = callback
			return true
		end,
		get_action = function(slot) return observations.gestures[slot] end,
		enable_all = function()
			return perform(observations, "gesture-master", function()
				observations.gesture_enabled = true
			end)
		end,
		disable_all = function()
			return perform(observations, "gesture-master", function()
				observations.gesture_enabled = false
			end)
		end,
		set_action = function(slot, action)
			return perform(observations, "gesture:" .. slot, function()
				observations.gestures[slot] = action
			end)
		end,
	}
	local keymap = {
		get_sections = function() return {} end,
		get_terminator_defs = function() return {} end,
		enable_group = function(name)
			return perform(observations, "keymap-group:" .. name, function() end)
		end,
		disable_group = function(name)
			return perform(observations, "keymap-group:" .. name, function() end)
		end,
		set_terminator_enabled = function(key)
			local result = perform(observations, "terminator:" .. key, function() end)
			if result ~= true then return result end
			return nil
		end,
		set_preview_star_enabled = function()
			return perform(observations, "preview-star", function() end)
		end,
		set_preview_autocorrect_enabled = function()
			return perform(observations, "preview-autocorrect", function() end)
		end,
		set_preview_ai_enabled = function()
			return perform(observations, "preview-ai", function() end)
		end,
	}
	observations.keymap = keymap
	local karabiner = {
		snapshot_settings = function() return clone(observations.karabiner_state) end,
		clear_all_bindings = function(on_done)
			return dispatch_karabiner(observations, "karabiner-clear", function()
				observations.karabiner_state = { profile = "disabled" }
			end, on_done)
		end,
		reset_to_defaults = function(on_done)
			return dispatch_karabiner(observations, "karabiner-reset", function()
				observations.karabiner_state = { profile = "factory" }
			end, on_done)
		end,
		restore_settings = function(snapshot, on_done)
			return dispatch_karabiner(observations, "karabiner-restore", function()
				observations.karabiner_state = clone(snapshot)
			end, on_done)
		end,
		get_tap_holds_enabled = function() return observations.tap_holds_enabled end,
		set_tap_holds_enabled = function(enabled)
			return perform(observations, "tap-holds-switch", function()
				observations.tap_holds_enabled = enabled
			end)
		end,
		regenerate = function(on_done)
			observations.calls.regenerate = (observations.calls.regenerate or 0) + 1
			if on_done then on_done(true, "ready") end
			return true
		end,
	}

	local original_get = hs_stub.settings.get
	local original_set = hs_stub.settings.set
	local original_get_keys = hs_stub.settings.getKeys
	hs_stub.settings.get = function(key)
		local logical_key = key:gsub("^ergopti%.", "")
		return clone(observations.settings[logical_key])
	end
	hs_stub.settings.getKeys = function()
		local keys = {}
		for key in pairs(observations.settings) do keys[#keys + 1] = "ergopti." .. key end
		table.sort(keys)
		return keys
	end
	hs_stub.settings.set = function(key, value)
		local logical_key = key:gsub("^ergopti%.", "")
		local result = perform(observations, "setting:" .. logical_key, function()
			observations.settings[logical_key] = clone(value)
		end)
		if result == false then return false end
		-- The native settings setter is void; exactness comes from read-back
		return nil
	end

	local setup_ok, setup_result = xpcall(function()
		local Menu = require("ui.menu.init")
		local menu = Menu.start("/virtual/", {}, gestures, keymap, {}, {}, karabiner, {})
		helpers.assert_not_nil(menu)
		helpers.assert_type(observations.dynamic_menu_callback, "function")
		observations.dynamic_menu_callback()
		helpers.assert_type(observations.actions and observations.actions.factory_reset, "function")
		-- Retired on every driver: no menu row and no action may reach them.
		helpers.assert_nil(observations.actions.enable_all, "Enable All is retired")
		helpers.assert_nil(observations.actions.disable_all, "Disable All is retired")
		helpers.assert_type(observations.actions and observations.actions.reload, "function")
		helpers.assert_type(observations.actions and observations.actions.quit, "function")
		observations.calls = {}
		observations.notifications = {}
		observations.armed = true
		return callback(observations)
	end, debug.traceback)

	hs_stub.settings.get = original_get
	hs_stub.settings.set = original_set
	hs_stub.settings.getKeys = original_get_keys
	for _, module_name in ipairs(MODULE_KEYS) do package.loaded[module_name] = saved_modules[module_name] end
	_G.hs = saved_hs
	package.loaded["hs"] = saved_hs_module
	package.loaded["tests.stubs.hs"] = saved_hs_stub_module
	if not setup_ok then error(setup_result, 0) end
	return setup_result
end

--- Asserts that every externally visible pre-action value was restored.
--- @param observations table Fixture observations.
local function assert_fully_restored(observations)
	helpers.assert_eq(observations.state, observations.initial_state)
	helpers.assert_eq(observations.gestures, observations.initial_gestures)
	helpers.assert_eq(observations.script, observations.initial_script)
	helpers.assert_eq(observations.keyboard, observations.initial_keyboard)
	helpers.assert_eq(observations.settings, observations.initial_settings)
	helpers.assert_eq(observations.files, observations.initial_files)
	helpers.assert_eq(observations.karabiner_state, observations.initial_karabiner)
	helpers.assert_eq(observations.gesture_enabled, true)
	helpers.assert_eq(observations.tap_holds_enabled, true)
	helpers.assert_eq(observations.persisted, observations.initial_state)
	helpers.assert_eq(observations.named_shortcut, true)
	helpers.assert_eq(observations.named_bound, true)
	-- A refused Quit tells the user so; the reset itself notifies nothing.
	for _, notification in ipairs(observations.notifications) do
		helpers.assert_eq(notification.label, "notify.quit_refused",
			"a rolled-back reset notifies nothing of its own")
	end
end

return {
	MODULE_KEYS = MODULE_KEYS,
	SCRIPT_SLOTS = SCRIPT_SLOTS,
	assert_fully_restored = assert_fully_restored,
	clone = clone,
	dispatch_karabiner = dispatch_karabiner,
	fail = fail,
	perform = perform,
	run_hook = run_hook,
	with_menu_fixture = with_menu_fixture,
}
