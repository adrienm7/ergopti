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
	file_system.read_with_status = file_system.read_with_status or function()
		return "", "ok"
	end
	file_system.write_if_unchanged = file_system.write_if_unchanged or
		function(path, content, _expected_source)
			return file_system.write(path, content)
		end
	package.loaded["adapters.file_system"] = file_system
	package.loaded["infra.preferences"] = nil
	return require("infra.preferences")
end

local function minimal_save(preferences)
	preferences.load("/virtual/config.toml")
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

	helpers.it("preserves an external winner and lets the menu roll its live state back", function()
		local path = "/virtual/config.toml"
		local initial = "[features]\npreview_star_enabled = false\n"
		local external = "[features]\npreview_star_enabled = true\n"
		local disk = initial
		local publications = 0
		local preferences = load_preferences({
			read_with_status = function(read_path)
				helpers.assert_eq(read_path, path)
				return disk, "ok"
			end,
			-- Causal old-code seam: the unconditional writer loses B and reports a
			-- false success. The fixed code must never call it.
			write = function(_write_path, content)
				publications = publications + 1
				disk = external
				disk = content
				return true
			end,
			write_if_unchanged = function(write_path, _content, expected_source)
				publications = publications + 1
				helpers.assert_eq(write_path, path)
				helpers.assert_eq(expected_source,
					{ status = "ok", content = initial },
					"the exact boot bytes must cross the menu publication boundary")
				disk = external
				if expected_source.status ~= "ok" or disk ~= expected_source.content then
					return false, "source changed"
				end
				return true
			end,
		})
		local loaded, load_status = preferences.load(path)
		helpers.assert_eq(load_status, "ok")
		helpers.assert_type(loaded, "table")

		local transaction = require("ui.menu.preferences_transaction")
		local state = { preview_star_enabled = false }
		local restores = 0
		local save = transaction.bind(preferences, {
			path = path,
			state = state,
			hotfiles = {},
			core_modules = {},
			initial_state = state,
			initial_preferences = state,
			restore_runtime = function(snapshot)
				restores = restores + 1
				helpers.assert_eq(snapshot.preview_star_enabled, false)
				return true
			end,
		})
		state.preview_star_enabled = true

		helpers.assert_eq(save(), false,
			"a stale full-document menu save must be rejected")
		helpers.assert_eq(publications, 1)
		helpers.assert_eq(disk, external,
			"the external winner must survive byte-for-byte")
		helpers.assert_eq(state.preview_star_enabled, false,
			"the menu must roll the rejected runtime mutation back")
		helpers.assert_eq(restores, 1,
			"runtime restoration must run exactly once after the conflict")
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
	helpers.it("returns false only when a synchronous runtime setter raises", function()
		local warnings = {}
		local logger = helpers.make_logger_stub()
		logger.warn = function(_, fmt, ...)
			warnings[#warnings + 1] = string.format(fmt, ...)
		end
		package.loaded["infra.logger"] = logger
		local MenuState = helpers.load_with_stubs("ui.menu.menu_state")

		local function sync_with(setter)
			return MenuState.sync_state_to_modules({
				hotstrings = {},
				keymap = false,
				preview_star_enabled = false,
				keylogger_enabled = false,
			}, {}, false, {
				keymap = {
					set_preview_star_enabled = setter,
				},
				hotstring_editor = {},
				core_mods = {},
				apply_metrics_shortcut = function() return true end,
				apply_apps_time_shortcut = function() return true end,
				save_prefs = function() return true end,
			})
		end

		local nil_result = sync_with(function() end)
		local throw_result = sync_with(function() error("runtime setter failure", 0) end)
		package.loaded["infra.logger"] = nil
		package.loaded["ui.menu.menu_state"] = nil

		helpers.assert_eq(nil_result, true,
			"a successful setter's nil return must not be confused with failure")
		helpers.assert_eq(throw_result, false,
			"a contained setter exception must make runtime synchronization fail")
		helpers.assert_eq(#warnings, 1)
		helpers.assert_contains(warnings[1], "keymap.set_preview_star_enabled failed")
		helpers.assert_contains(warnings[1], "runtime setter failure")
	end)

	helpers.it("does not report rollback success when runtime restoration raises", function()
		local warnings, errors = {}, {}
		local logger = helpers.make_logger_stub()
		logger.warn = function(_, fmt, ...)
			warnings[#warnings + 1] = string.format(fmt, ...)
		end
		logger.error = function(_, fmt, ...)
			errors[#errors + 1] = string.format(fmt, ...)
		end
		package.loaded["infra.logger"] = logger
		local MenuState = helpers.load_with_stubs("ui.menu.menu_state")
		local transaction = require("ui.menu.preferences_transaction")
		local state = {
			hotstrings = {},
			keymap = false,
			preview_star_enabled = false,
			keylogger_enabled = false,
		}
		local rollback_successes = 0
		local save = transaction.bind({ save = function() return false end }, {
			path = "/virtual/config.toml",
			state = state,
			hotfiles = {},
			core_modules = {},
			initial_state = state,
			initial_preferences = {},
			restore_runtime = function(saved)
				return MenuState.sync_state_to_modules(state, saved, false, {
					keymap = {
						set_preview_star_enabled = function()
							error("rollback setter failure", 0)
						end,
					},
					hotstring_editor = {},
					core_mods = {},
					apply_metrics_shortcut = function() return true end,
					apply_apps_time_shortcut = function() return true end,
					save_prefs = function() return true end,
				})
			end,
			on_rollback = function() rollback_successes = rollback_successes + 1 end,
		})

		state.preview_star_enabled = true
		local committed = save()
		package.loaded["infra.logger"] = nil
		package.loaded["ui.menu.menu_state"] = nil
		package.loaded["ui.menu.preferences_transaction"] = nil

		helpers.assert_eq(committed, false)
		helpers.assert_eq(state.preview_star_enabled, false)
		helpers.assert_eq(rollback_successes, 0,
			"on_rollback must run only after every runtime setter completes")
		helpers.assert_eq(#warnings, 1)
		helpers.assert_contains(warnings[1], "rollback setter failure")
		helpers.assert_eq(#errors, 2)
		helpers.assert_contains(errors[2], "Preference rollback did not commit: false.")
	end)

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
