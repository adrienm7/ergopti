--- tests/unit/modules/shortcuts/test_start_starts_keyboard_shortcuts.lua

--- ==============================================================================
--- MODULE: Regression — shortcuts.start() starts the configurable keyboard shortcuts
--- DESCRIPTION:
--- modules/shortcuts/init.lua proxied M.start straight to Bindings.start, but
--- stop() and resume_bindings() BOTH also manage KeyboardShortcuts. So on a fresh
--- boot — where sync_state_to_modules calls shortcuts_mod.start() — only the
--- static Bindings were started; the configurable Cmd/Ctrl/Option keyboard
--- shortcuts were NEVER bound until the user paused and resumed (the only path
--- that called KeyboardShortcuts.start). The field log showed the symptom:
--- "[shortcuts.keyboard_shortcuts] stop() called before start() — nothing to stop"
--- at shutdown, proving start() never ran for that module.
---
--- Fix: M.start() is a real function that starts Bindings AND KeyboardShortcuts,
--- symmetric with stop() and resume_bindings(). This test drives M.start() with
--- stubbed sub-modules and asserts both are started.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("shortcuts.start() starts both bindings and keyboard shortcuts", function()
	helpers.it("M.start() invokes Bindings.start AND KeyboardShortcuts.start", function()
		local calls = { bindings = 0, keyboard = 0, script_control = 0 }

		-- Stub the three sub-modules so we can count lifecycle calls. init.lua reads
		-- Bindings.DEFAULT_CHATGPT_URL at load; every other field is proxied and may
		-- be nil without crashing.
		package.loaded["modules.shortcuts.bindings"] = {
			DEFAULT_CHATGPT_URL = "",
			start       = function() calls.bindings = calls.bindings + 1; return true end,
			stop        = function() return true end,
			is_started  = function() return true end,
		}
		package.loaded["modules.shortcuts.script_control"] = {
			ACTIONS = {}, ACTION_LABELS = {},
			start = function() calls.script_control = calls.script_control + 1; return true end,
			stop  = function() return true end,
			is_paused = function() return false end,
		}
		package.loaded["modules.shortcuts.keyboard_shortcuts"] = {
			start = function() calls.keyboard = calls.keyboard + 1; return true end,
			stop  = function() return true end,
		}

		local Shortcuts = helpers.load_with_stubs("modules.shortcuts")
		Shortcuts.start()

		helpers.assert_eq(calls.bindings, 1)
		-- The regression: this was 0 because M.start was a bare Bindings.start proxy.
		helpers.assert_eq(calls.keyboard, 1)
		-- start() must NOT start script_control — it has its own dedicated start so
		-- its pause/quit/reload tap survives a bindings toggle.
		helpers.assert_eq(calls.script_control, 0)

		-- Cleanup so the stubbed sub-modules never leak into a later test file.
		package.loaded["modules.shortcuts.bindings"]        = nil
		package.loaded["modules.shortcuts.script_control"]  = nil
		package.loaded["modules.shortcuts.keyboard_shortcuts"] = nil
		package.loaded["modules.shortcuts"]                 = nil
	end)
end)
