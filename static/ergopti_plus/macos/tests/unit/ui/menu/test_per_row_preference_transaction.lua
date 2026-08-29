--- tests/unit/ui/menu/test_per_row_preference_transaction.lua

--- ==============================================================================
--- MODULE: Per-Row Preference Transaction Regression
--- DESCRIPTION:
--- Drives the real gesture sensitivity/mode and shortcut toggle menu actions.
--- Runtime mutations must roll back when preference publication refuses.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===========================================
-- ===========================================
-- ======= 1/ Shortcut Row Transaction =======
-- ===========================================
-- ===========================================

local function exercise_shortcut_transaction(save_mode, mutation_mode)
	helpers.with_fresh_modules({
		"ui.menu.menu_shortcuts",
		"infra.logger",
		"infra.deferred_work",
		"infra.fs_dir",
		"infra.dialog_util",
		"modules.shortcuts",
		"modules.shortcuts.actions.text",
		"infra.i18n",
		"ui.menu.menu_utils",
		"infra.manifest_menu",
		"ui.menu.shortcut_utils",
		"ui.menu.menu_keyboard_slots",
		"infra.manifest_reader",
	}, function()
		local enabled = true
		local updates = 0
		local notifications = 0
		local saves = 0
		local mutation_calls = 0
		local function set_enabled(value)
			mutation_calls = mutation_calls + 1
			enabled = value
			if mutation_calls == 1 then
				if mutation_mode == "false" then return false end
				if mutation_mode == "nil" then return nil end
				if mutation_mode == "throw" then error("synthetic runtime refusal") end
			end
			return true
		end
		local shortcuts = {
			list_shortcuts = function()
				return { { id = "ctrl_a", label = "Alpha", enabled = true } }
			end,
			is_enabled = function() return enabled end,
			enable = function() return set_enabled(true) end,
			disable = function() return set_enabled(false) end,
			resume_bindings = function() return true end,
			pause_bindings = function() return true end,
		}
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.deferred_work"] = { after = function() return true end }
		package.loaded["infra.fs_dir"] = { entries = function() return {} end }
		package.loaded["infra.dialog_util"] = {}
		package.loaded["modules.shortcuts"] = {
			DEFAULT_STATE = { chatgpt_url = "https://example.test", shortcuts = true },
		}
		package.loaded["modules.shortcuts.actions.text"] = {
			WRAP_GROUPS = {},
			build_active_wrap_pairs = function() return {} end,
		}
		package.loaded["infra.i18n"] = {
			get = function(key) return key end,
			decorate_section = function(value) return value end,
		}
		package.loaded["ui.menu.menu_utils"] = {}
		package.loaded["infra.manifest_menu"] = {
			build = function(_, _, _, groups)
				return groups.ctrl_shortcuts().items
			end,
		}
		package.loaded["ui.menu.shortcut_utils"] = {}
		package.loaded["ui.menu.menu_keyboard_slots"] = {
			provide_rows = function() return {} end,
		}
		package.loaded["infra.manifest_reader"] = { default_for = function() return "star" end }

		local Menu = require("ui.menu.menu_shortcuts")
		local item = Menu.build({
			shortcuts = shortcuts,
			state = {
				shortcuts = true,
				chatgpt_url = "https://example.test",
				wrap_symbol_states = {},
				custom_wrap_symbols = {},
			},
			paused = false,
			applyTriggerChar = function(value) return value end,
			save_prefs = function()
				saves = saves + 1
				if save_mode == "true" then return true end
				if save_mode == "false" then return false end
				if save_mode == "nil" then return nil end
				error("synthetic preference refusal")
			end,
			notify_feature = function() notifications = notifications + 1 end,
			updateMenu = function() updates = updates + 1 end,
			commands = {},
			state_getters = {},
		})
		local call_ok, committed = pcall(item.submenu[1].action)
		helpers.assert_true(call_ok, "runtime and preference refusals must stay inside the row action")
		local expected_commit = save_mode == "true" and mutation_mode == "true"
		local expected_enabled = true
		if expected_commit then expected_enabled = false end
		helpers.assert_eq(committed, expected_commit)
		helpers.assert_eq(enabled, expected_enabled,
			"the exact shortcut posture must either commit or roll back")
		helpers.assert_eq(saves, mutation_mode == "true" and 1 or 0,
			"persistence must not run after a runtime refusal")
		helpers.assert_eq(notifications, expected_commit and 1 or 0)
		helpers.assert_eq(updates, expected_commit and 1 or 0)
	end)
end

helpers.describe("menu_shortcuts: per-row toggles are preference transactions", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("rolls runtime back after save " .. mode, function()
			exercise_shortcut_transaction(mode, "true")
		end)
	end
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("rolls an ambiguous runtime " .. mode .. " back before saving", function()
			exercise_shortcut_transaction("true", mode)
		end)
	end
	helpers.it("publishes only after runtime and persistence both commit", function()
		exercise_shortcut_transaction("true", "true")
	end)
end)





-- ==========================================
-- ==========================================
-- ======= 2/ Gesture Row Transaction =======
-- ==========================================
-- ==========================================

local function exercise_gesture_transaction(save_mode, target, mutation_mode)
	helpers.with_fresh_modules({
		"ui.menu.menu_gestures",
		"modules.gestures",
		"ui.menu.menu_utils",
		"infra.dialog_util",
		"infra.i18n",
		"infra.manifest_menu",
		"ui.action_picker",
		"ui.menu.shortcut_utils",
		"infra.logger",
		"infra.deferred_work",
	}, function()
		local sensitivity = 3.5
		local mode = "incremental"
		local updates = 0
		local saves = 0
		local mutation_calls = 0
		local function set_target(kind, value)
			if kind == target then mutation_calls = mutation_calls + 1 end
			if kind == "mode" then mode = value else sensitivity = value end
			if kind == target and mutation_calls == 1 then
				if mutation_mode == "false" then return false end
				if mutation_mode == "nil" then return nil end
				if mutation_mode == "throw" then error("synthetic runtime refusal") end
			end
			return true
		end
		local gestures = {
			get_action = function() return "none" end,
			get_action_label = function(value) return value end,
			get_action_parameter = function() return "" end,
			get_sg_names = function() return {} end,
			get_mode = function() return mode end,
			set_mode = function(_, value) return set_target("mode", value) end,
			get_sensitivity = function() return sensitivity end,
			set_sensitivity = function(_, value) return set_target("sensitivity", value) end,
			enable_all = function() return true end,
			disable_all = function() return true end,
		}
		package.loaded["modules.gestures"] = {
			DEFAULT_STATE = { gestures = true },
			DEFAULT_GESTURES = {},
			SINGLE_SLOTS = { "swipe_2_left" },
		}
		package.loaded["ui.menu.menu_utils"] = {}
		package.loaded["infra.dialog_util"] = {}
		package.loaded["infra.i18n"] = {
			get = function(key) return key end,
			section = function(key) return key end,
		}
		package.loaded["infra.manifest_menu"] = {
			get_root = function()
				return { gesture_slots = { ["2"] = { "swipe_2_left" } } }
			end,
			build = function(_, _, _, _, _, providers)
				return providers.gesture_slots_2()
			end,
		}
		package.loaded["ui.action_picker"] = { open = function() return true end }
		package.loaded["ui.menu.shortcut_utils"] = {}
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.deferred_work"] = { after = function() return true end }

		local Menu = require("ui.menu.menu_gestures")
		local item = Menu.build({
			gestures = gestures,
			state = { gestures = true },
			paused = false,
			save_prefs = function()
				saves = saves + 1
				if save_mode == "true" then return true end
				if save_mode == "false" then return false end
				if save_mode == "nil" then return nil end
				error("synthetic preference refusal")
			end,
			updateMenu = function() updates = updates + 1 end,
			notify_feature = function() end,
		})
		local slot = item.submenu[1]
		local action = target == "sensitivity"
			and slot.items[4].items[6].action
			or slot.items[3].items[1].action
		local call_ok, committed = pcall(action)
		helpers.assert_true(call_ok, "runtime and preference refusals must stay inside the row action")
		local expected_commit = save_mode == "true" and mutation_mode == "true"
		helpers.assert_eq(committed, expected_commit)
		helpers.assert_eq(sensitivity,
			expected_commit and target == "sensitivity" and 2.0 or 3.5)
		helpers.assert_eq(mode,
			expected_commit and target == "mode" and "x1" or "incremental")
		helpers.assert_eq(saves, mutation_mode == "true" and 1 or 0,
			"persistence must not run after a runtime refusal")
		helpers.assert_eq(updates, expected_commit and 1 or 0)
	end)
end

helpers.describe("menu_gestures: per-slot values are preference transactions", function()
	for _, target in ipairs({ "sensitivity", "mode" }) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("rolls " .. target .. " back after save " .. mode, function()
				exercise_gesture_transaction(mode, target, "true")
			end)
		end
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("rolls " .. target .. " back after runtime " .. mode, function()
				exercise_gesture_transaction("true", target, mode)
			end)
		end
		helpers.it("publishes " .. target .. " only after both commitments", function()
			exercise_gesture_transaction("true", target, "true")
		end)
	end
end)
