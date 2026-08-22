--- tests/unit/ui/menu/test_shortcuts_runtime_transaction.lua

--- ==============================================================================
--- MODULE: Shortcuts Menu Runtime Transaction Regression
--- DESCRIPTION:
--- Drives the real Shortcuts master menu action and menu-state synchronizer.
--- A returned/raised binding lifecycle failure must restore runtime and state,
--- and must never persist or announce a preference the runtime did not commit.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Loads the real menu builder around one controllable shortcut lifecycle.
--- @param shortcuts table Runtime shortcut double.
--- @param enabled boolean Initial persisted state.
--- @return table fixture Built action and side-effect counters.
local function load_menu_fixture(shortcuts, enabled, options)
	options = options or {}
	local noop = function() end
	package.loaded["infra.logger"] = helpers.make_logger_stub()
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
	package.loaded["infra.manifest_menu"] = { build = function() return {} end }
	package.loaded["ui.menu.shortcut_utils"] = {}
	package.loaded["ui.menu.menu_keyboard_slots"] = { provide_rows = function() return {} end }
	package.loaded["infra.manifest_reader"] = { default_for = function() return "★" end }
	package.loaded["ui.menu.menu_shortcuts"] = nil
	local MenuShortcuts = helpers.load_with_stubs("ui.menu.menu_shortcuts")

	local state = {
		shortcuts = enabled,
		chatgpt_url = "https://example.test",
		wrap_symbol_states = {},
		custom_wrap_symbols = {},
	}
	local counters = { saves = 0, notifications = 0, updates = 0 }
	local item = MenuShortcuts.build({
		shortcuts = shortcuts,
		state = state,
		paused = false,
		applyTriggerChar = function(value) return value end,
		save_prefs = function()
			counters.saves = counters.saves + 1
			if options.save_mode == "false" then return false end
			if options.save_mode == "nil" then return nil end
			if options.save_mode == "throw" then error("synthetic save refusal") end
			return true
		end,
		notify_feature = function() counters.notifications = counters.notifications + 1 end,
		updateMenu = function() counters.updates = counters.updates + 1 end,
		commands = {},
		state_getters = {},
	})
	helpers.assert_type(item.action, "function", "the real master toggle action must be reachable")
	return { action = item.action, state = state, counters = counters, noop = noop }
end


--- Minimal dependency bag for exercising the real menu-state synchronizer.
--- @param shortcuts table Shortcut lifecycle double.
--- @return table deps
local function state_sync_deps(shortcuts)
	return {
		keymap = {},
		hotstring_editor = {},
		core_mods = { shortcuts_mod = shortcuts },
		apply_metrics_shortcut = function() return true end,
		apply_apps_time_shortcut = function() return true end,
		save_prefs = function() return true end,
	}
end





-- ============================================
-- ============================================
-- ======= 1/ Master Toggle Transaction =======
-- ============================================
-- ============================================

helpers.describe("Shortcuts master menu toggle commits runtime before persistence", function()
	helpers.it("rolls back activate-then-false without saving or announcing success", function()
		local running = false
		local calls = {}
		local fixture = load_menu_fixture({
			resume_bindings = function()
				calls[#calls + 1] = "resume"
				running = true
				return false
			end,
			pause_bindings = function()
				calls[#calls + 1] = "pause"
				running = false
				return true
			end,
		}, false)

		local call_ok, committed = pcall(fixture.action)
		helpers.assert_true(call_ok, "native refusal must remain inside the menu callback")
		helpers.assert_eq(committed, false)
		helpers.assert_eq(calls, { "resume", "pause" },
			"the inverse lifecycle must roll a partially activated runtime back")
		helpers.assert_true(not running)
		helpers.assert_eq(fixture.state.shortcuts, false,
			"menu state must still describe the committed runtime")
		helpers.assert_eq(fixture.counters.saves, 0,
			"persistence is forbidden before exact runtime commitment")
		helpers.assert_eq(fixture.counters.notifications, 0)
		helpers.assert_eq(fixture.counters.updates, 0)
	end)

	helpers.it("contains activate-then-throw and applies the same rollback", function()
		local running = false
		local calls = {}
		local fixture = load_menu_fixture({
			resume_bindings = function()
				calls[#calls + 1] = "resume"
				running = true
				error("RESUME_THROW", 0)
			end,
			pause_bindings = function()
				calls[#calls + 1] = "pause"
				running = false
				return true
			end,
		}, false)

		local call_ok, committed = pcall(fixture.action)
		helpers.assert_true(call_ok)
		helpers.assert_eq(committed, false)
		helpers.assert_eq(calls, { "resume", "pause" })
		helpers.assert_true(not running)
		helpers.assert_eq(fixture.state.shortcuts, false)
		helpers.assert_eq(fixture.counters.saves, 0)
	end)

	helpers.it("persists and publishes only after exact runtime success", function()
		local calls = {}
		local fixture = load_menu_fixture({
			resume_bindings = function() calls[#calls + 1] = "resume"; return true end,
			pause_bindings = function() calls[#calls + 1] = "pause"; return true end,
		}, false)

		helpers.assert_eq(fixture.action(), true)
		helpers.assert_eq(calls, { "resume" })
		helpers.assert_eq(fixture.state.shortcuts, true)
		helpers.assert_eq(fixture.counters.saves, 1)
		helpers.assert_eq(fixture.counters.notifications, 1)
		helpers.assert_eq(fixture.counters.updates, 1)
	end)

	for _, previous in ipairs({ false, true }) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("rolls back a mutate-then-" .. mode .. " shortcut edge", function()
				local running = previous
				local calls = {}
				local function boundary(name, desired, result_mode)
					return function(claim)
						calls[#calls + 1] = { name = name, claim = claim }
						running = desired
						if result_mode == "false" then return false end
						if result_mode == "nil" then return nil end
						if result_mode == "throw" then error("synthetic lifecycle refusal") end
						return true
					end
				end
				local fixture = load_menu_fixture({
					resume_bindings = boundary("resume", true,
						previous and "true" or mode),
					pause_bindings = boundary("pause", false,
						previous and mode or "true"),
				}, previous)
				helpers.assert_eq(fixture.action(), false)
				helpers.assert_eq(running, previous)
				helpers.assert_eq(fixture.state.shortcuts, previous)
				helpers.assert_eq(#calls, 2)
				for _, call in ipairs(calls) do
					helpers.assert_eq(call.claim, "feature_toggle")
				end
				helpers.assert_eq(fixture.counters.saves, 0)
				helpers.assert_eq(fixture.counters.notifications, 0)
			end)
		end

		for _, inverse_mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("blocks on shortcut inverse " .. inverse_mode .. " debt", function()
				local running = previous
				local calls = {}
				local call_index = 0
				local function edge(name, desired)
					return function(claim)
						call_index = call_index + 1
						calls[#calls + 1] = { name = name, claim = claim }
						if call_index == 1 then running = desired; return false end
						if inverse_mode == "throw" then error("inverse refusal") end
						if inverse_mode == "nil" then return nil end
						return false
					end
				end
				local fixture = load_menu_fixture({
					resume_bindings = edge("resume", true),
					pause_bindings = edge("pause", false),
				}, previous)
				helpers.assert_eq(fixture.action(), false)
				helpers.assert_eq(fixture.action(), false,
					"the next click must retry only the retained inverse")
				helpers.assert_eq(#calls, 3)
				for _, call in ipairs(calls) do
					helpers.assert_eq(call.claim, "feature_toggle")
				end
				helpers.assert_eq(fixture.state.shortcuts, previous)
				helpers.assert_eq(fixture.counters.saves, 0)
			end)
		end

		for _, save_mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("rolls runtime back when shortcut save returns " .. save_mode, function()
				local running = previous
				local calls = {}
				local fixture = load_menu_fixture({
					resume_bindings = function(claim)
						calls[#calls + 1] = claim; running = true; return true
					end,
					pause_bindings = function(claim)
						calls[#calls + 1] = claim; running = false; return true
					end,
				}, previous, { save_mode = save_mode })
				helpers.assert_eq(fixture.action(), false)
				helpers.assert_eq(running, previous)
				helpers.assert_eq(fixture.state.shortcuts, previous)
				helpers.assert_eq(calls, { "feature_toggle", "feature_toggle" })
				helpers.assert_eq(fixture.counters.notifications, 0)
				helpers.assert_eq(fixture.counters.updates, 0)
			end)

			for _, inverse_mode in ipairs({ "false", "nil", "throw" }) do
				helpers.it("retains shortcut debt when save " .. save_mode
					.. " and inverse " .. inverse_mode, function()
					local running = previous
					local calls = {}
					local call_index = 0
					local function edge(name, desired)
						return function(claim)
							call_index = call_index + 1
							calls[#calls + 1] = { name = name, claim = claim }
							if call_index == 1 then running = desired; return true end
							if inverse_mode == "throw" then error("inverse refusal") end
							if inverse_mode == "nil" then return nil end
							return false
						end
					end
					local fixture = load_menu_fixture({
						resume_bindings = edge("resume", true),
						pause_bindings = edge("pause", false),
					}, previous, { save_mode = save_mode })
					helpers.assert_eq(fixture.action(), false)
					helpers.assert_eq(fixture.state.shortcuts, previous)
					helpers.assert_eq(running, not previous,
						"the adverse inverse remains explicit runtime debt")
					helpers.assert_eq(fixture.action(), false,
						"the next click retries only retained save rollback debt")
					helpers.assert_eq(#calls, 3)
					for _, call in ipairs(calls) do
						helpers.assert_eq(call.claim, "feature_toggle")
					end
					helpers.assert_eq(fixture.counters.saves, 1,
						"debt settlement may not repeat the failed preference write")
					helpers.assert_eq(fixture.counters.notifications, 0)
					helpers.assert_eq(fixture.counters.updates, 0)
				end)
			end
		end
	end
end)





-- ===============================================
-- ===============================================
-- ======= 2/ Menu-State Exact Result Gate =======
-- ===============================================
-- ===============================================

helpers.describe("menu-state shortcut synchronization requires exact lifecycle success", function()
	helpers.it("returns false when resume_bindings returns false", function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["ui.menu.keymap_lifecycle"] = {
			ensure_started = function() return true end,
		}
		package.loaded["modules.keylogger.text_cipher"] = { set_enabled = function() end }
		package.loaded["ui.menu.menu_state"] = nil
		local MenuState = helpers.load_with_stubs("ui.menu.menu_state")

		local state = {
			shortcuts = true,
			hotstrings = {},
			keymap = false,
			keylogger_enabled = false,
		}
		local result = MenuState.sync_state_to_modules(state, {}, false,
			state_sync_deps({ resume_bindings = function() return false end }))
		helpers.assert_eq(result, false,
			"a contained native refusal is still a failed runtime synchronization")
	end)

	helpers.it("returns true only for an exact true pause result", function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["ui.menu.keymap_lifecycle"] = {
			ensure_started = function() return true end,
		}
		package.loaded["modules.keylogger.text_cipher"] = { set_enabled = function() end }
		package.loaded["ui.menu.menu_state"] = nil
		local MenuState = helpers.load_with_stubs("ui.menu.menu_state")

		local state = {
			shortcuts = false,
			hotstrings = {},
			keymap = false,
			keylogger_enabled = false,
		}
		local result = MenuState.sync_state_to_modules(state, {}, false,
			state_sync_deps({ pause_bindings = function() return true end }))
		helpers.assert_eq(result, true)
	end)
end)

return true
