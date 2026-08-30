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
local function load_fixture()
	local noop = function() end
	local dynamic_menu_callback = nil
	local captured_context = nil
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
		"ui.menu.menu_hotstrings", "ui.menu.menu_metrics", "ui.menu.menu_remap",
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
		set_extras = noop,
		list_shortcuts = function() return {} end,
	}
	package.loaded["modules.dynamic_hotstrings"] = {}
	package.loaded["modules.gestures"] = { SINGLE_SLOTS = { "swipe_left" } }
	package.loaded["infra.personal_shortcuts"] = { load = noop }

	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["ui.menu.init"] = nil
	local Menu = require("ui.menu.init")
	local menu = Menu.start("/virtual/", {}, {}, {}, {}, {}, nil, {})
	helpers.assert_not_nil(menu)
	helpers.assert_type(dynamic_menu_callback, "function")
	dynamic_menu_callback()
	helpers.assert_type(captured_context, "table")

	return {
		bindings = bindings,
		allow_unbind = function(handle) unbind_refusals[handle] = nil end,
		context = captured_context,
		refuse_bind = function(refused) bind_refused = refused == true end,
		refuse_unbind = function(handle) unbind_refusals[handle] = true end,
		state = state,
	}
end

local function only_handle(bindings)
	local found = nil
	for handle in pairs(bindings) do
		if found ~= nil then return nil end
		found = handle
	end
	return found
end





-- =========================================
-- =========================================
-- ======= 2/ Replacement Transactions ====
-- =========================================
-- =========================================

helpers.describe("menu metric hotkeys replace exact native owners transactionally", function()
	helpers.it("keeps the metrics shortcut acknowledged when old-owner release is refused", function()
		local fixture = load_fixture()
		helpers.assert_eq(fixture.context.apply_metrics_shortcut({ "ctrl" }, "m", false), true)
		local previous = only_handle(fixture.bindings)
		helpers.assert_not_nil(previous)
		fixture.refuse_unbind(previous)

		helpers.assert_eq(fixture.context.apply_metrics_shortcut({ "alt" }, "n", false), false,
			"a refused old-owner release must reject the replacement")
		helpers.assert_eq(fixture.state.metrics_shortcut.key, "m",
			"rejected replacement state must not be published")
		helpers.assert_eq(only_handle(fixture.bindings), previous,
			"the candidate must be rolled back instead of leaking beside the prior owner")
		helpers.assert_eq(fixture.bindings[previous].enabled, true,
			"the registrar-fenced prior owner must be re-enabled after rollback")
	end)

	helpers.it("keeps the application-time shortcut live when candidate bind is refused", function()
		local fixture = load_fixture()
		helpers.assert_eq(fixture.context.apply_apps_time_shortcut({ "ctrl" }, "a", false), true)
		local previous = only_handle(fixture.bindings)
		helpers.assert_not_nil(previous)
		fixture.refuse_bind(true)

		helpers.assert_eq(fixture.context.apply_apps_time_shortcut({ "alt" }, "b", false), false,
			"candidate refusal must reject the replacement")
		helpers.assert_eq(fixture.state.apps_time_shortcut.key, "a",
			"the acknowledged preference must remain unchanged")
		helpers.assert_eq(only_handle(fixture.bindings), previous)
		helpers.assert_eq(fixture.bindings[previous].enabled, true,
			"candidate acquisition must precede retirement of the live owner")
	end)

	helpers.it("retries the exact candidate when replacement rollback is refused", function()
		local fixture = load_fixture()
		helpers.assert_eq(fixture.context.apply_metrics_shortcut({ "ctrl" }, "m", false), true)
		local previous = only_handle(fixture.bindings)
		fixture.refuse_unbind(previous)
		fixture.refuse_unbind("hotkey#2")

		helpers.assert_eq(fixture.context.apply_metrics_shortcut({ "alt" }, "n", false), false)
		helpers.assert_not_nil(fixture.bindings["hotkey#2"],
			"a refused candidate rollback must retain that exact facade")
		helpers.assert_eq(fixture.bindings["hotkey#2"].enabled, false,
			"the retained candidate must remain delivery-fenced")

		fixture.allow_unbind("hotkey#2")
		fixture.allow_unbind(previous)
		helpers.assert_eq(fixture.context.apply_metrics_shortcut({ "alt" }, "n", false), true,
			"the next attempt must settle retained cleanup before replacing again")
		helpers.assert_nil(fixture.bindings["hotkey#2"])
		helpers.assert_nil(fixture.bindings[previous])
		helpers.assert_eq(fixture.state.metrics_shortcut.key, "n")
	end)
end)





-- ========================================
-- ========================================
-- ======= 3/ Dashboard Close Owner =======
-- ========================================
-- ========================================

helpers.describe("menu metric shortcuts preserve dashboard close ownership", function()
	helpers.it("routes both shortcut closes through their dashboard transaction", function()
		local fixture = load_fixture()
		local direct_deletes = 0
		local typing_closes = 0
		local apps_closes = 0
		local typing_owner = {
			delete = function()
				direct_deletes = direct_deletes + 1
				return false
			end,
		}
		local apps_owner = {
			delete = function()
				direct_deletes = direct_deletes + 1
				return false
			end,
		}
		local typing = {
			_wv = typing_owner,
			close = function()
				typing_closes = typing_closes + 1
				return false
			end,
		}
		local apps = {
			_wv = apps_owner,
			close = function()
				apps_closes = apps_closes + 1
				return false
			end,
		}
		package.loaded["ui.metrics_typing.init"] = typing
		package.loaded["ui.metrics_typing"] = nil
		package.loaded["ui.metrics_apps"] = apps
		package.loaded["ui.metrics_apps.init"] = nil

		helpers.assert_eq(fixture.context.apply_metrics_shortcut({ "ctrl" }, "m", false), true)
		local metrics_handle = only_handle(fixture.bindings)
		helpers.assert_not_nil(metrics_handle)
		fixture.bindings[metrics_handle].callback()

		helpers.assert_eq(fixture.context.apply_apps_time_shortcut({ "ctrl" }, "a", false), true)
		local apps_binding = nil
		for _, binding in pairs(fixture.bindings) do
			if binding.chord == "ctrl+a" then apps_binding = binding end
		end
		helpers.assert_not_nil(apps_binding)
		apps_binding.callback()

		helpers.assert_eq(typing_closes, 1,
			"the typing-dashboard shortcut must delegate to its close transaction")
		helpers.assert_eq(apps_closes, 1,
			"the apps-dashboard shortcut must delegate to its close transaction")
		helpers.assert_eq(direct_deletes, 0,
			"the menu must never bypass module-owned native cleanup")
		helpers.assert_eq(typing._wv, typing_owner,
			"a refused typing close must retain its exact owner")
		helpers.assert_eq(apps._wv, apps_owner,
			"a refused apps close must retain its exact owner")
	end)
end)
