--- tests/unit/ui/menu/test_metric_hotkey_replacement_transaction.lua

--- ==============================================================================
--- MODULE: Menu Metric Hotkey Replacement Transaction Regressions
--- DESCRIPTION:
--- Drives the real menu-owned metrics and application-time shortcut callbacks
--- through a stateful registrar. A replacement must acquire its candidate before
--- retiring the acknowledged owner and must roll back exactly on refusal.
--- ==============================================================================

local helpers = require("tests.helpers")





-- =====================================
-- =====================================
-- ======= 1/ Isolated Menu Fixture ====
-- =====================================
-- =====================================

--- Builds a menu and captures the real shortcut application callbacks.
--- @return table fixture Runtime state and registrar controls.
local function load_fixture(legacy)
	local noop = function() end
	local dynamic_menu_callback = nil
	local captured_context = nil
	local extras = nil
	local next_handle = 0
	local bindings = {}
	local bind_refused = false
	local unbind_refusals = {}
	local hs_stub = helpers.load_with_stubs("infra.logger") and _G.hs

	hs_stub.timer = {
		new = function(_delay, callback)
			local timer = { callback = callback, running_state = false }
			function timer:start() self.running_state = true; return self end
			function timer:stop() self.running_state = false; return self end
			function timer:running() return self.running_state end
			return timer
		end,
		doAfter = function(_delay, _callback)
			return { stop = function() return nil end }
		end,
		secondsSinceEpoch = function() return 100 end,
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

	local state = {
		metrics_shortcut = legacy,
		apps_time_shortcut = legacy,
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
	package.loaded["infra.preferences"] = {
		build_initial_state = function() return state end,
		load = function() return {}, "present" end,
		merge_saved_data = noop,
		snapshot = function() return {} end,
		save = function() return true end,
		get_group_name = function() return "common" end,
	}
	package.loaded["ui.menu.builder"] = {
		generate = function(context)
			captured_context = context
			return { { title = "menu" } }
		end,
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
		path_for = function(path) return path .. ".journal" end,
		create = function()
			return {
				prepare = function() return true end,
				mark_commit = function() return true end,
				mark_prepared = function() return true end,
				clear = function() return true end,
			}
		end,
	}
	package.loaded["ui.menu.keymap_lifecycle"] = { ensure_started = function() return true end }
	package.loaded["ui.menu.menu_state"] = { sync_state_to_modules = function() return true end }
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
		setMenu = function(items)
			if type(items) == "function" then dynamic_menu_callback = items end
			return true
		end,
		destroy = function() return true end,
	}
	package.loaded["chord"] = {
		format = function(mods, key) return table.concat(mods, "+") .. "+" .. key end,
	}
	package.loaded["adapters.hotkey_registrar"] = {
		bind = function(chord, callback)
			if bind_refused then return nil end
			next_handle = next_handle + 1
			local handle = "hotkey#" .. next_handle
			bindings[handle] = { callback = callback, chord = chord, enabled = true }
			return handle
		end,
		setEnabled = function(handle, enabled)
			local binding = bindings[handle]
			if not binding then return false end
			binding.enabled = enabled == true
			return true
		end,
		unbind = function(handle)
			local binding = bindings[handle]
			if not binding then return false end
			binding.enabled = false
			if unbind_refusals[handle] then return false end
			bindings[handle] = nil
			return true
		end,
	}
	package.loaded["infra.termination_coordinator"] = { request_exit = function() return true end }

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
	package.loaded["modules.shortcuts"] = {
		is_paused = function() return false end,
		set_on_pause_change = noop,
		set_shortcut_action = noop,
		set_extras = function(value) extras = value end,
		list_shortcuts = function() return {} end,
	}
	package.loaded["modules.dynamic_hotstrings"] = {}
	package.loaded["modules.gestures"] = { SINGLE_SLOTS = { "swipe_left" } }
	package.loaded["infra.personal_shortcuts"] = { load = noop }

	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["ui.menu.init"] = nil
	local Menu = require("ui.menu.init")
	local program_admission
	local gestures = { configure_program_admission = function(callback)
		helpers.assert_type(callback, "function")
		program_admission = callback
		return true
	end }
	local menu = Menu.start("/virtual/", {}, gestures, {}, {}, {}, nil, {})
	helpers.assert_type(program_admission, "function", "metric startup registers the required program owner")
	helpers.assert_not_nil(menu)
	helpers.assert_type(dynamic_menu_callback, "function")
	dynamic_menu_callback()
	helpers.assert_type(captured_context, "table")

	return {
		bindings = bindings,
		extras = extras,
		allow_unbind = function(handle) unbind_refusals[handle] = nil end,
		context = captured_context,
		refuse_bind = function(refused) bind_refused = refused == true end,
		refuse_unbind = function(handle) unbind_refusals[handle] = true end,
		state = state,
	}
end

helpers.describe("retired Metrics shortcuts have no native owner", function()
	for _, legacy in ipairs({ false, "unsupported", { mods = { "ctrl" }, key = "m" } }) do
		helpers.it("does not acquire a dedicated Metrics binding from " .. type(legacy) .. " data", function()
			local fixture = load_fixture(legacy)
			helpers.assert_nil(fixture.context.apply_metrics_shortcut)
			helpers.assert_nil(fixture.context.apply_apps_time_shortcut)
			helpers.assert_nil(next(fixture.bindings), "no historical dedicated field reaches the registrar")
			helpers.assert_eq(fixture.state.metrics_shortcut, legacy, "unowned source intent is never rewritten")
		end)
	end
end)

helpers.describe("ordinary Metrics actions preserve dashboard ownership", function()
	for _, kind in ipairs({ "typing", "apps" }) do
		for _, result in ipairs({ "false", "nil", "throw", "true" }) do
			helpers.it("dispatches " .. kind .. " to its dashboard owner after " .. result, function()
				local fixture = load_fixture()
				local calls, direct_deletes = 0, 0
				local native = { delete = function() direct_deletes = direct_deletes + 1 end }
				local dashboard = { _wv = native, show = function()
					calls = calls + 1
					if result == "throw" then error("synthetic dashboard refusal") end
					if result == "nil" then return nil end
					return result == "true"
				end }
				package.loaded["ui.metrics_" .. kind] = dashboard
				fixture.extras["open_metrics_" .. kind]()
				helpers.assert_eq(calls, 1, "the ordinary action delegates exactly once")
				helpers.assert_eq(direct_deletes, 0, "the action never bypasses the module's owner")
				helpers.assert_eq(dashboard._wv, native, "delivery does not discard the exact native owner")
				helpers.assert_nil(next(fixture.bindings), "actions install no dedicated shortcut")
			end)
		end
	end
end)
