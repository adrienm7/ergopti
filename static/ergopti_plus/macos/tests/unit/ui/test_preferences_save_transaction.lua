--- tests/unit/ui/test_preferences_save_transaction.lua

--- ==============================================================================
--- MODULE: Preferences Save Transaction Regression
--- DESCRIPTION:
--- Proves that Preferences.save reports exact publication success and that the
--- menu invalidates caches only after that success. Returned/raised adapter
--- failures must remain false and preserve the caller's success-only effects.
--- ==============================================================================

local helpers = require("tests.helpers")

local function load_preferences(file_system)
	package.loaded["adapters.file_system"] = file_system
	package.loaded["infra.preferences"] = nil
	return require("infra.preferences")
end

local function minimal_save(preferences)
	return preferences.save("/virtual/config.toml", {}, {}, {})
end

helpers.describe("Preferences.save: exact atomic publication result", function()
	helpers.it("returns false when the atomic writer returns false", function()
		local calls = 0
		local preferences = load_preferences({
			write = function(path, content)
				calls = calls + 1
				helpers.assert_eq(path, "/virtual/config.toml")
				helpers.assert_type(content, "string")
				return false
			end,
		})
		helpers.assert_eq(minimal_save(preferences), false,
			"a returned write failure must never look like a successful preference save")
		helpers.assert_eq(calls, 1)
	end)

	helpers.it("contains a raised writer failure and returns false", function()
		local preferences = load_preferences({
			write = function() error("disk failure", 0) end,
		})
		local call_ok, committed = pcall(minimal_save, preferences)
		helpers.assert_true(call_ok, "an adapter error must not escape a user action callback")
		helpers.assert_eq(committed, false)
	end)

	helpers.it("returns true only after the writer confirms publication", function()
		local preferences = load_preferences({ write = function() return true end })
		helpers.assert_eq(minimal_save(preferences), true)
	end)

end)

helpers.describe("menu preference side effects are success-gated", function()
	local transaction = require("ui.menu.preferences_transaction")

	helpers.it("leaves every cache untouched on false, nil, or raise", function()
		for _, save in ipairs({
			function() return false end,
			function() return nil end,
			function() error("save raised", 0) end,
		}) do
			local effects = 0
			local committed = transaction.commit(
				{ save = save },
				"/virtual/config.toml",
				{},
				{},
				{},
				{ invalidate_cache = function() effects = effects + 1 end },
				{ invalidate_cache = function() effects = effects + 1 end },
				function() effects = effects + 1 end
			)
			helpers.assert_eq(committed, false)
			helpers.assert_eq(effects, 0,
				"cache invalidation and dirty publication must require exact save success")
		end
	end)

	helpers.it("runs each success-only effect once after a confirmed save", function()
		local effects = 0
		local committed = transaction.commit(
			{ save = function() return true end },
			"/virtual/config.toml",
			{},
			{},
			{},
			{ invalidate_cache = function() effects = effects + 1 end },
			{ invalidate_cache = function() effects = effects + 1 end },
			function() effects = effects + 1 end
		)
		helpers.assert_eq(committed, true)
		helpers.assert_eq(effects, 3)
	end)
end)

helpers.describe("menu preferences: first-click rollback", function()
	helpers.it("preserves retained nested table identities during rollback", function()
		local transaction = require("ui.menu.preferences_transaction")
		local state = { nested = { enabled = true, values = { 1, 2 } } }
		local nested_ref = state.nested
		local values_ref = state.nested.values
		state.nested.enabled = false
		state.nested.values[1] = 99
		state.nested.values[3] = 3
		helpers.assert_eq(transaction.restore_table(state, {
			nested = { enabled = true, values = { 1, 2 } },
		}), true)
		helpers.assert_true(state.nested == nested_ref)
		helpers.assert_true(state.nested.values == values_ref)
		helpers.assert_eq(state.nested, { enabled = true, values = { 1, 2 } })
	end)

	helpers.it("restores a real menu callback when its first boot-session save returns false", function()
		-- Seed the same headless environment used by production menu modules, then
		-- replace only the expensive About dependencies with behavior-recording doubles.
		helpers.load_with_stubs("infra.logger")
		local restarts = 0
		package.loaded["modules.updater"] = {
			INTERVAL_PRESETS = {},
			get_check_interval = function() return 3600 end,
			is_local_source = function() return true end,
			current_version = function() return "local" end,
			restart_background_checks = function() restarts = restarts + 1 end,
		}
		package.loaded["ui.changelog"] = {}
		package.loaded["infra.dialog_util"] = {}
		package.loaded["infra.manifest_menu"] = {
			build = function(_, _, _, _, _, providers)
				return providers.about_updates()
			end,
		}
		package.loaded["ui.menu.menu_about"] = nil
		local About = require("ui.menu.menu_about")
		package.loaded["ui.menu.preferences_transaction"] = nil
		local transaction = require("ui.menu.preferences_transaction")

		local state = {
			update_channel = "dev",
			update_check_interval_seconds = 3600,
		}
		local writes, restores, updates = 0, 0, 0
		local save = transaction.bind({
			save = function()
				writes = writes + 1
				return false
			end,
		}, {
			path = "/virtual/config.toml",
			state = state,
			hotfiles = {},
			core_modules = {},
			initial_state = state,
			initial_preferences = state,
			restore_runtime = function(snapshot)
				restores = restores + 1
				helpers.assert_eq(snapshot.update_channel, "dev")
				return true
			end,
		})

		local about = About.build({
			state = state,
			save_prefs = save,
			updateMenu = function() updates = updates + 1 end,
		})
		local channel_menu = about.submenu[3]
		helpers.assert_type(channel_menu.items[1].action, "function")
		channel_menu.items[1].action()

		helpers.assert_eq(writes, 1, "the first click must reach the failing writer")
		helpers.assert_eq(restores, 1, "boot-seeded rollback must run before any successful save")
		helpers.assert_eq(state.update_channel, "dev", "live state must match the existing config")
		helpers.assert_eq(restarts, 0, "success-only updater work must not run after save failure")
		helpers.assert_eq(updates, 0, "the menu must not publish the rejected value")
	end)

	helpers.it("restores the keylogger cipher posture without starting migration", function()
		helpers.load_with_stubs("infra.logger")
		local cipher_values = {}
		package.loaded["modules.keylogger.text_cipher"] = {
			set_enabled = function(value) cipher_values[#cipher_values + 1] = value end,
		}
		package.loaded["ui.menu.menu_state"] = nil
		local MenuState = require("ui.menu.menu_state")
		local result = MenuState.sync_state_to_modules({
			hotstrings = {},
			keylogger_encrypt = false,
			keylogger_enabled = false,
		}, {}, false, {
			keymap = {},
			hotstring_editor = {},
			core_mods = {},
			apply_metrics_shortcut = function() return true end,
			apply_apps_time_shortcut = function() return true end,
			save_prefs = function() return true end,
		})
		helpers.assert_eq(result, true)
		helpers.assert_eq(cipher_values, { false },
			"rollback must restore TextCipher's live posture from the acknowledged state")
	end)

	helpers.it("restores gesture registries owned outside the flat state", function()
		helpers.load_with_stubs("infra.logger")
		package.loaded["ui.menu.menu_state"] = nil
		local MenuState = require("ui.menu.menu_state")
		local observed = {}
		local result = MenuState.sync_state_to_modules({ hotstrings = {}, gestures = true }, {
			gesture_modes = { swipe_left = "continuous" },
			gesture_sensitivities = { swipe_left = 1.25 },
			gesture_space_wrap = false,
		}, false, {
			keymap = {},
			gestures = {
				enable_all = function() end,
				set_mode = function(_, value) observed.mode = value end,
				set_sensitivity = function(_, value) observed.sensitivity = value end,
				set_space_wrap = function(value) observed.space_wrap = value end,
			},
			hotstring_editor = {},
			core_mods = {},
			apply_metrics_shortcut = function() return true end,
			apply_apps_time_shortcut = function() return true end,
			save_prefs = function() return true end,
		})
		helpers.assert_eq(result, true)
		helpers.assert_eq(observed, {
			mode = "continuous",
			sensitivity = 1.25,
			space_wrap = false,
		})
	end)
end)

-- Do not leak the final FileSystem double into later test modules in the same
-- Lua process; those modules intentionally exercise the real atomic adapter.
package.loaded["adapters.file_system"] = nil
package.loaded["infra.preferences"] = nil

return true
