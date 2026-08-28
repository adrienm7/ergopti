--- tests/unit/ui/menu/test_global_reset_transaction.lua

--- ==============================================================================
--- MODULE: Global Disable and Factory Reset Transaction Regression
--- DESCRIPTION:
--- Exercises the real global actions exported by ui.menu.start and proves every
--- runtime, preference, settings, file, Karabiner, and reload boundary belongs
--- to one exact transaction with reverse compensation and retained retry debt.
---
--- FEATURES & RATIONALE:
--- 1. Faithful Refusals: False, nil, throws, and synchronous callbacks followed
---    by request refusal remain distinct from exact terminal commitment.
--- 2. Observable Rollback: Mutable doubles expose every store so partial state
---    cannot hide behind a successful pcall or a permissive stub.
--- 3. Real Wiring: Both subjects are captured from ui.menu.start, not invoked
---    through a test-only transaction factory.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULE_KEYS = {
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
	"ui.menu.menu_remap",
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
	"ui.menu.init",
}

local SCRIPT_SLOTS = { "return_key", "backspace", "escape" }

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

--- Counts one exact notification label.
--- @param observations table Fixture observations.
--- @param label string Exact i18n key.
--- @return integer count
local function count_notification(observations, label)
	local count = 0
	for _, notification in ipairs(observations.notifications) do
		if notification.label == label then count = count + 1 end
	end
	return count
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
			return_key = "script_pause_toggle",
			backspace = "script_reload",
			escape = "script_quit",
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
			snapshot.shortcut_keys = { alpha = candidate.shortcuts == true }
			return snapshot
		end,
		save = function(_, candidate)
			local result = perform(observations, "preferences", function()
				observations.persisted = clone(candidate)
			end)
			if result ~= true then return result end
			local snapshot = clone(candidate)
			snapshot.gesture_actions = clone(observations.gestures)
			snapshot.shortcut_keys = { alpha = candidate.shortcuts == true }
			return true, snapshot
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
		sync_state_to_modules = function(_, saved)
			return perform(observations, "runtime-sync", function()
				if type(saved) == "table" and type(saved.shortcut_keys) == "table" then
					observations.named_shortcut = saved.shortcut_keys.alpha == true
				end
			end)
		end,
	}
	package.loaded["ui.menu.keymap_lifecycle"] = {
		ensure_started = function()
			return perform(observations, "ensure-started", function()
				observations.enable_preflight_calls = observations.enable_preflight_calls + 1
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
		request_exit = function()
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
		"ui.menu.menu_hotstrings", "ui.menu.menu_metrics", "ui.menu.menu_remap",
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

	local shortcuts = {
		DEFAULT_STATE = {
			script_control_shortcuts = {
				return_key = "script_pause_toggle",
				backspace = "script_reload",
				escape = "script_quit",
			},
		},
		is_paused = function() return false end,
		set_on_pause_change = noop,
		set_extras = function(candidate)
			if type(candidate) == "table" and type(candidate.disable_all) == "function" then
				observations.actions = candidate
			end
			return true
		end,
		list_shortcuts = function()
			return { { id = "alpha", enabled = observations.named_shortcut ~= false } }
		end,
		disable = function()
			return perform(observations, "named-shortcut:alpha", function()
				observations.named_shortcut = false
			end)
		end,
		enable = function()
			return perform(observations, "named-shortcut:alpha", function()
				observations.named_shortcut = true
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
		helpers.assert_type(observations.actions and observations.actions.disable_all, "function")
		helpers.assert_type(observations.actions and observations.actions.reset_defaults, "function")
		helpers.assert_type(observations.actions and observations.actions.enable_all, "function")
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
	helpers.assert_eq(observations.persisted, observations.initial_state)
	helpers.assert_eq(observations.named_shortcut, true)
	helpers.assert_eq(count_notification(observations, "notify.all_features_disabled"), 0)
	helpers.assert_eq(count_notification(observations, "notify.defaults_reset"), 0)
end





-- ===========================================================
-- ===========================================================
-- ======= 1/ Disable-All Exact Transaction Boundaries =======
-- ===========================================================
-- ===========================================================

helpers.describe("HS-022 disable-all is one exact global transaction", function()
	helpers.it("holds one writer capability across the Enable All preflight", function()
		with_menu_fixture({}, function(observations)
			local nested_result = nil
			observations.hooks["ensure-started:before"] = function()
				nested_result = observations.actions.reset_defaults()
			end

			helpers.assert_eq(observations.actions.enable_all(), true)
			helpers.assert_eq(nested_result, false,
				"a nested bulk writer cannot publish inside the opaque keymap preflight")
			helpers.assert_eq(observations.enable_preflight_calls, 1)
			helpers.assert_eq(observations.calls["karabiner-reset"] or 0, 0)
			helpers.assert_eq(observations.calls.reload or 0, 0)
			helpers.assert_eq(observations.files, observations.initial_files)
		end)
	end)

	helpers.it("owns the snapshot window before any reentrant global action", function()
		with_menu_fixture({}, function(observations)
			local nested_result = nil
			observations.hooks["preferences-snapshot:after-clone"] = function()
				nested_result = observations.actions.reset_defaults()
			end

			helpers.assert_true(observations.actions.disable_all())
			helpers.assert_eq(nested_result, false,
				"a nested reset cannot commit over a partially captured snapshot")
			helpers.assert_eq(observations.reload_commits, 0)
			helpers.assert_eq(count_notification(observations, "notify.all_features_disabled"), 1)
			helpers.assert_eq(count_notification(observations, "notify.defaults_reset"), 0)
		end)
	end)

	helpers.it("compensates false, nil, and throw from every configurable sibling", function()
		for _, boundary in ipairs({
			"runtime-sync",
			"gesture-master",
			"gesture:swipe_left",
			"gesture:swipe_right",
			"script:return_key",
			"script:backspace",
			"script:escape",
			"named-shortcut:alpha",
			"preferences",
			"keyboard:alt_v",
			"keyboard:cmd_x",
		}) do
			for _, mode in ipairs({ "false", "nil", "throw" }) do
				with_menu_fixture({ failures = { [boundary] = fail(mode) } }, function(observations)
					helpers.assert_eq(observations.actions.disable_all(), false,
						boundary .. " " .. mode .. " must refuse the real action")
					assert_fully_restored(observations)
					helpers.assert_eq(observations.calls["karabiner-clear"] or 0, 0,
						"a synchronous refusal must stop before Karabiner")
				end)
			end
		end
	end)

	helpers.it("rejects every Karabiner request shape and compensates exact old stores", function()
		for _, mode in ipairs({ "false", "nil", "throw", "sync-success-false", "sync-success-nil" }) do
			with_menu_fixture({ failures = { ["karabiner-clear"] = fail(mode) } }, function(observations)
				helpers.assert_eq(observations.actions.disable_all(), false)
				assert_fully_restored(observations)
				helpers.assert_eq(observations.calls["karabiner-restore"], 1)
			end)
		end
	end)

	helpers.it("waits for one terminal, gates siblings, and ignores duplicate callbacks", function()
		with_menu_fixture({ failures = { ["karabiner-clear"] = fail("pending") } }, function(observations)
			helpers.assert_eq(observations.actions.disable_all(), true)
			helpers.assert_eq(observations.actions.disable_all(), false,
				"a pending global owner must gate a second action")
			helpers.assert_eq(count_notification(observations, "notify.all_features_disabled"), 0)
			local terminal = observations.terminals["karabiner-clear"]
			helpers.assert_type(terminal, "function")
			terminal(true, "ready")
			terminal(false, "duplicate")
			helpers.assert_eq(count_notification(observations, "notify.all_features_disabled"), 1)
			helpers.assert_eq(observations.karabiner_state.profile, "disabled")
		end)
	end)

	helpers.it("compensates a negative terminal before publishing success", function()
		with_menu_fixture({ failures = { ["karabiner-clear"] = fail("pending") } }, function(observations)
			helpers.assert_eq(observations.actions.disable_all(), true)
			observations.terminals["karabiner-clear"](false, "deployment-refused")
			assert_fully_restored(observations)
			helpers.assert_eq(observations.calls["karabiner-restore"], 1)
		end)
	end)
end)





-- ==========================================================
-- ==========================================================
-- ======= 2/ Enable-All Exact Transaction Boundaries =======
-- ==========================================================
-- ==========================================================

helpers.describe("HS-050 enable-all is one exact global transaction", function()
	helpers.it("refuses shortcut enable failures before persistence", function()
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			with_menu_fixture({ failures = { ["named-shortcut:alpha"] = fail(mode) } },
				function(observations)
					observations.named_shortcut = false
					helpers.assert_eq(observations.actions.enable_all(), false,
						"a named shortcut " .. mode .. " must refuse Enable All")
					helpers.assert_eq(observations.named_shortcut, false)
					helpers.assert_eq(observations.calls.preferences or 0, 0,
						"preferences must stay untouched until every enable commits")
					helpers.assert_eq(
						count_notification(observations, "notify.all_features_enabled"),
						0
					)
				end)
		end
	end)

	helpers.it("rolls back runtime sync failures before persistence", function()
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			with_menu_fixture({ failures = { ["runtime-sync"] = fail(mode) } },
				function(observations)
					observations.named_shortcut = false
					helpers.assert_eq(observations.actions.enable_all(), false,
						"a runtime sync " .. mode .. " must refuse Enable All")
					helpers.assert_eq(observations.named_shortcut, false)
					helpers.assert_eq(observations.persisted, observations.initial_state)
					helpers.assert_eq(observations.calls.preferences or 0, 0,
						"runtime commitment must precede preference publication")
					helpers.assert_eq(
						count_notification(observations, "notify.all_features_enabled"),
						0
					)
				end)
		end
	end)

	helpers.it("compensates exact keymap feature refusals before persistence", function()
		for _, case in ipairs({
			{ boundary = "keymap-group:common", modes = { "false", "nil", "throw" } },
			{ boundary = "preview-star", modes = { "false", "nil", "throw" } },
			{ boundary = "terminator:space", modes = { "false", "throw" } },
		}) do
			for _, mode in ipairs(case.modes) do
				with_menu_fixture({ failures = { [case.boundary] = fail(mode) } },
					function(observations)
						helpers.assert_eq(observations.actions.enable_all(), false,
							case.boundary .. " " .. mode .. " must refuse Enable All")
						helpers.assert_eq(observations.calls.preferences or 0, 0)
						helpers.assert_eq(
							count_notification(observations, "notify.all_features_enabled"),
							0
						)
					end)
			end
		end
	end)

	helpers.it("restores every runtime after preference publication refuses", function()
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			with_menu_fixture({ failures = { preferences = fail(mode) } },
				function(observations)
					observations.named_shortcut = false
					helpers.assert_eq(observations.actions.enable_all(), false)
					helpers.assert_eq(observations.state, observations.initial_state)
					helpers.assert_eq(observations.named_shortcut, false)
					helpers.assert_eq(observations.persisted, observations.initial_state)
					helpers.assert_eq(
						count_notification(observations, "notify.all_features_enabled"),
						0
					)
				end)
		end
	end)

	helpers.it("publishes success only after the final preference commit", function()
		with_menu_fixture({}, function(observations)
			observations.named_shortcut = false
			helpers.assert_eq(observations.actions.enable_all(), true)
			helpers.assert_eq(observations.named_shortcut, true)
			helpers.assert_eq(observations.calls.preferences, 1)
			helpers.assert_eq(observations.persisted.shortcuts, true)
			helpers.assert_eq(observations.calls["karabiner-clear"] or 0, 0)
			helpers.assert_eq(observations.calls["karabiner-reset"] or 0, 0)
			helpers.assert_eq(
				count_notification(observations, "notify.all_features_enabled"),
				1
			)
		end)
	end)
end)





-- =============================================================
-- =============================================================
-- ======= 3/ Factory Reset Exact Transaction Boundaries =======
-- =============================================================
-- =============================================================

helpers.describe("HS-022 factory reset owns settings, files, deployment, and reload", function()
	helpers.it("refuses bulk mutation behind every live manual termination owner", function()
		for _, case in ipairs({
			{
				label = "menu reload",
				start = function(observations) return observations.actions.reload() end,
			},
			{
				label = "watcher reload",
				start = function(observations)
					helpers.assert_type(observations.config_watcher_callback, "function")
					return observations.config_watcher_callback()
				end,
			},
			{
				label = "quit",
				start = function(observations) return observations.actions.quit() end,
			},
		}) do
			with_menu_fixture({}, function(observations)
				helpers.assert_eq(case.start(observations), true, case.label .. " must be accepted")
				helpers.assert_true(observations.termination_pending)
				helpers.assert_eq(observations.actions.reset_defaults(), false,
					case.label .. " must fence a later factory reset")
				helpers.assert_eq(observations.calls["karabiner-reset"] or 0, 0)
				helpers.assert_eq(observations.files, observations.initial_files)
			end)
		end
	end)

	helpers.it("refuses a reentrant action while synchronous rollback is on-stack", function()
		with_menu_fixture({ failures = { reload = fail("false") } }, function(observations)
			local nested_result = nil
			observations.hooks[
				"file-restore:/virtual/config_karabiner.toml:after"
			] = function()
				nested_result = observations.actions.disable_all()
			end

			helpers.assert_eq(observations.actions.reset_defaults(), false)
			helpers.assert_eq(nested_result, false,
				"rollback owns its inverse until the mutating boundary returns")
			assert_fully_restored(observations)
			helpers.assert_eq(
				observations.calls["file-restore:/virtual/config_karabiner.toml"],
				1,
				"the same inverse must not recurse while it is on-stack"
			)
		end)
	end)

	helpers.it("compensates settings and recoverable file move refusal shapes", function()
		for _, boundary in ipairs({
			"setting:llm_api_entries",
			"setting:llm_api_entry_id",
			"file-move:/virtual/config.toml",
			"file-move:/virtual/config_karabiner.toml",
		}) do
			local modes = boundary:sub(1, #"setting:") == "setting:"
				and { "false", "nil", "throw", "false-after", "throw-after" }
				or { "false", "nil", "throw", "false-after", "nil-after", "throw-after" }
			for _, mode in ipairs(modes) do
				with_menu_fixture({ failures = { [boundary] = fail(mode) } }, function(observations)
					helpers.assert_eq(observations.actions.reset_defaults(), false)
					assert_fully_restored(observations)
					helpers.assert_eq(observations.reload_commits, 0)
				end)
			end
		end
	end)

	helpers.it("requires exact Karabiner deployment before requesting reload", function()
		for _, mode in ipairs({ "false", "nil", "throw", "sync-success-false", "sync-success-nil" }) do
			with_menu_fixture({ failures = { ["karabiner-reset"] = fail(mode) } }, function(observations)
				helpers.assert_eq(observations.actions.reset_defaults(), false)
				assert_fully_restored(observations)
				helpers.assert_eq(observations.calls.reload or 0, 0)
			end)
		end
	end)

	helpers.it("compensates a negative reset deployment terminal before reload", function()
		with_menu_fixture({ failures = { ["karabiner-reset"] = fail("pending") } }, function(observations)
			helpers.assert_eq(observations.actions.reset_defaults(), true)
			observations.terminals["karabiner-reset"](false, "regeneration-refused")
			assert_fully_restored(observations)
			helpers.assert_eq(observations.calls.reload or 0, 0)
		end)
	end)

	helpers.it("compensates every reload handoff refusal without a success claim", function()
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			with_menu_fixture({ failures = { reload = fail(mode) } }, function(observations)
				helpers.assert_eq(observations.actions.reset_defaults(), false)
				assert_fully_restored(observations)
				helpers.assert_eq(observations.reset_journal_phase, "cleared",
					"a refused reload must settle the restored journal")
				helpers.assert_eq(observations.calls["karabiner-restore"], 1)
				helpers.assert_eq(observations.reload_commits, 0)
			end)
		end
	end)

	helpers.it("rolls back every durable journal boundary refusal", function()
		for _, label in ipairs({ "reset-journal:prepared", "reset-journal:commit" }) do
			for _, mode in ipairs({ "false", "nil", "throw", "false-after", "throw-after" }) do
				with_menu_fixture({ failures = { [label] = fail(mode) } }, function(observations)
					helpers.assert_eq(observations.actions.reset_defaults(), false,
						label .. " " .. mode .. " must refuse the reset")
					assert_fully_restored(observations)
					helpers.assert_eq(observations.reset_journal_phase, "cleared",
						"the restored transaction must durably settle its journal")
					helpers.assert_eq(observations.reload_commits, 0)
				end)
			end
		end
	end)

	helpers.it("retains compensation debt and lets one retry commit exactly once", function()
		with_menu_fixture({ failures = {
			reload = fail("false"),
			["file-restore:/virtual/config_karabiner.toml"] = fail("false"),
		} }, function(observations)
			helpers.assert_eq(observations.actions.reset_defaults(), false)
			helpers.assert_nil(observations.files["/virtual/config_karabiner.toml"],
				"the refused inverse remains owned as cleanup debt")
			helpers.assert_eq(observations.actions.reset_defaults(), true,
				"the retry must finish debt before starting one new candidate")
			helpers.assert_eq(observations.reload_commits, 1)
			helpers.assert_eq(count_notification(observations, "notify.defaults_reset"), 0,
				"reload handoff has no post-finalization notification tail")
			helpers.assert_eq(observations.post_reload_effects, 0)
			helpers.assert_eq(observations.calls.reload, 2,
				"one rejected handoff and one committed retry are expected")
		end)
	end)

	helpers.it("keeps reset fenced through a returning reload with no post-reload tail", function()
		with_menu_fixture({ failures = { ["karabiner-reset"] = fail("pending") } }, function(observations)
			helpers.assert_eq(observations.actions.reset_defaults(), true)
			helpers.assert_eq(observations.actions.disable_all(), false,
				"both global actions share one pending owner")
			helpers.assert_eq(observations.reload_commits, 0)
			local terminal = observations.terminals["karabiner-reset"]
			terminal(true, "ready")
			terminal(true, "duplicate")
			helpers.assert_eq(observations.reload_commits, 1)
			helpers.assert_eq(count_notification(observations, "notify.defaults_reset"), 0)
			helpers.assert_eq(observations.post_reload_effects, 0,
				"no UI or logger capability may run after the coordinator returned from hs.reload")
			helpers.assert_eq(observations.actions.enable_all(), false,
				"the global mutation owner remains fenced until the Lua state is replaced")
			helpers.assert_nil(observations.files["/virtual/config.toml"])
			helpers.assert_not_nil(observations.files[
				"/virtual/config.toml.ergopti-reset-backup"])
			helpers.assert_eq(observations.reset_journal_phase, "commit",
				"the accepted reload must leave one durable commit decision")
			helpers.assert_eq(#observations.reset_journal_entries, 2,
				"the journal must own every reset pathname")
			for _, entry in ipairs(observations.reset_journal_entries) do
				helpers.assert_true(entry.existed == true and type(entry.identity) == "table",
					"each existing reset file must retain its inode identity")
			end
		end)
	end)

	helpers.it("rolls back an accepted reload whose exact lease later aborts", function()
		with_menu_fixture({ failures = { reload = fail("pending") } }, function(observations)
			helpers.assert_eq(observations.actions.reset_defaults(), true)
			helpers.assert_type(observations.reload_abort, "function")
			helpers.assert_type(observations.builder_ctx, "table")
			helpers.assert_eq(observations.actions.enable_all(), false,
				"an accepted reload handoff still owns every overlapping writer")
			helpers.assert_eq(observations.actions.reload(), false,
				"a manual reload cannot supersede the reset handoff")
			helpers.assert_eq(observations.builder_ctx.do_reload("menu"), false,
				"indirect menu callers must share the same reload capability")
			helpers.assert_eq(observations.actions.quit(), false,
				"a quit cannot upgrade the reset's exclusive reload owner")
			helpers.assert_eq(observations.enable_preflight_calls, 0)
			helpers.assert_eq(observations.calls.manual_reload or 0, 0)
			helpers.assert_eq(observations.calls.exit or 0, 0)
			helpers.assert_eq(count_notification(observations, "notify.defaults_reset"), 0)

			local abort = observations.reload_abort
			observations.reload_abort = nil
			abort("native fence refused")
			assert_fully_restored(observations)
			helpers.assert_eq(observations.reset_journal_phase, "cleared",
				"an aborted reload lease must settle the restored journal")
			helpers.assert_eq(observations.reload_commits, 0)
		end)
	end)
end)





-- ========================================================
-- ========================================================
-- ======= 4/ Recoverable File Move Native Contract =======
-- ========================================================
-- ========================================================

helpers.describe("HS-022 recoverable config moves retain exact inverse evidence", function()
	helpers.it("records a throw-after-move and restores the original bytes on retry", function()
		local files = { ["/config.toml"] = "old bytes" }
		local rename_calls = 0
		local mover = helpers.load_with_stubs("ui.menu.recoverable_file_moves").create({
			read_with_status = function(path)
				if files[path] == nil then return nil, "absent" end
				return files[path], "ok"
			end,
			rename = function(source, destination)
				rename_calls = rename_calls + 1
				files[destination] = files[source]
				files[source] = nil
				if rename_calls == 1 then error("synthetic late rename throw") end
				return true
			end,
			backup_path = function(path) return path .. ".backup" end,
		})
		local entry = mover.capture("/config.toml")
		helpers.assert_type(entry, "table")
		helpers.assert_eq(mover.move(entry), false)
		helpers.assert_nil(files["/config.toml"])
		helpers.assert_eq(files["/config.toml.backup"], "old bytes")
		helpers.assert_eq(mover.restore(entry), true)
		helpers.assert_eq(files["/config.toml"], "old bytes")
		helpers.assert_nil(files["/config.toml.backup"])
	end)

	helpers.it("recognizes every pre-mutation move refusal as already restored", function()
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			local files = { ["/config.toml"] = "old bytes" }
			local move_calls = 0
			local mover = helpers.load_with_stubs("ui.menu.recoverable_file_moves").create({
				read_with_status = function(path)
					if files[path] == nil then return nil, "absent" end
					return files[path], "ok"
				end,
				move_no_replace = function()
					move_calls = move_calls + 1
					if mode == "throw" then error("synthetic no-replace move throw") end
					if mode == "nil" then return nil end
					return false
				end,
				backup_path = function(path) return path .. ".backup" end,
			})
			local entry = mover.capture("/config.toml")
			helpers.assert_eq(mover.move(entry), false)
			helpers.assert_eq(mover.restore(entry), true,
				mode .. " before mutation is already the exact inverse posture")
			helpers.assert_eq(files["/config.toml"], "old bytes")
			helpers.assert_nil(files["/config.toml.backup"])
			helpers.assert_eq(move_calls, 1,
				"rollback must not invoke a second native move when nothing changed")
		end
	end)

	helpers.it("refuses an absent snapshot after a file appears", function()
		local files = {}
		local mover = helpers.load_with_stubs("ui.menu.recoverable_file_moves").create({
			read_with_status = function(path)
				if files[path] == nil then return nil, "absent" end
				return files[path], "ok"
			end,
			move_no_replace = function() error("native move must stay unreachable") end,
			backup_path = function(path) return path .. ".backup" end,
		})
		local entry = mover.capture("/config.toml")
		files["/config.toml"] = "concurrent writer"
		helpers.assert_eq(mover.move(entry), false)
		helpers.assert_eq(mover.restore(entry), false)
		helpers.assert_eq(files["/config.toml"], "concurrent writer")
	end)

	helpers.it("never overwrites a destination created inside the forward move", function()
		local files = { ["/config.toml"] = "old bytes" }
		local mover = helpers.load_with_stubs("ui.menu.recoverable_file_moves").create({
			read_with_status = function(path)
				if files[path] == nil then return nil, "absent" end
				return files[path], "ok"
			end,
			move_no_replace = function(_source, destination)
				files[destination] = "foreign backup"
				return true
			end,
			backup_path = function(path) return path .. ".backup" end,
		})
		local entry = mover.capture("/config.toml")
		helpers.assert_eq(mover.move(entry), false)
		helpers.assert_eq(files["/config.toml"], "old bytes")
		helpers.assert_eq(files["/config.toml.backup"], "foreign backup")
		helpers.assert_eq(mover.restore(entry), false,
			"a foreign destination remains retained evidence, never rollback fodder")
		helpers.assert_eq(files["/config.toml.backup"], "foreign backup")
	end)

	helpers.it("never overwrites a source recreated inside the inverse move", function()
		local files = { ["/config.toml"] = "old bytes" }
		local calls = 0
		local mover = helpers.load_with_stubs("ui.menu.recoverable_file_moves").create({
			read_with_status = function(path)
				if files[path] == nil then return nil, "absent" end
				return files[path], "ok"
			end,
			move_no_replace = function(source, destination)
				calls = calls + 1
				if calls == 1 then
					files[destination] = files[source]
					files[source] = nil
				else
					files[destination] = "concurrent writer"
				end
				return true
			end,
			backup_path = function(path) return path .. ".backup" end,
		})
		local entry = mover.capture("/config.toml")
		helpers.assert_eq(mover.move(entry), true)
		helpers.assert_eq(mover.restore(entry), false)
		helpers.assert_eq(files["/config.toml"], "concurrent writer")
		helpers.assert_eq(files["/config.toml.backup"], "old bytes",
			"the exact inverse remains recoverable after a no-clobber refusal")
	end)

	helpers.it("rejects a split postcondition changed between its two reads", function()
		local files = { ["/config.toml"] = "old bytes" }
		local mutate_during_postcondition = false
		local mover = helpers.load_with_stubs("ui.menu.recoverable_file_moves").create({
			read_with_status = function(path)
				local content = files[path]
				if mutate_during_postcondition and path == "/config.toml.backup" then
					mutate_during_postcondition = false
					files["/config.toml"] = "concurrent writer"
				end
				if content == nil then return nil, "absent" end
				return content, "ok"
			end,
			move_no_replace = function(source, destination)
				files[destination] = files[source]
				files[source] = nil
				mutate_during_postcondition = true
				return true
			end,
			backup_path = function(path) return path .. ".backup" end,
		})
		local entry = mover.capture("/config.toml")
		helpers.assert_eq(mover.move(entry), false)
		helpers.assert_eq(files["/config.toml"], "concurrent writer")
		helpers.assert_eq(files["/config.toml.backup"], "old bytes")
	end)
end)

return true
