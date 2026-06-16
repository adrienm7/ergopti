--- tests/unit/modules/gestures/test_script_quit_kills_karabiner.lua

--- ==============================================================================
--- MODULE: script_quit Kills Karabiner Before Exit (regression)
--- DESCRIPTION:
--- Locks down that the `script_quit` action (bound to rcmd+Escape) tears down
--- Karabiner-Elements BEFORE quitting Hammerspoon.
---
--- ROOT CAUSE ENCODED: `script_quit` quits HS via os.exit(0), which terminates
--- the Lua VM abruptly and BYPASSES hs.shutdownCallback — where the normal KE
--- kill lives. So on the quit-shortcut path KE kept running with the Ergopti
--- rules and the physical keyboard stayed remapped after HS was gone. The action
--- must call karabiner.kill() itself. If a future edit drops that call, the spy
--- assertion below fails.
---
--- SAFETY: os.exit and hs.timer.doAfter are overridden so the action cannot
--- actually terminate the test runner; the stub timer never auto-fires anyway.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

local Actions = helpers.load_with_stubs("modules.gestures.actions")

helpers.describe("gestures.actions: script_quit tears down Karabiner before exit", function()
	helpers.it("calls karabiner.kill() when the quit action runs", function()
		-- Spy Karabiner module, injected via the action's lazy require.
		local killed = { count = 0 }
		package.loaded["modules.karabiner"] = {
			kill = function() killed.count = killed.count + 1 end,
		}

		-- Neutralise the process-exit path so the action is safe to run inline.
		local saved_exit    = os.exit
		local saved_doAfter = _G.hs.timer.doAfter
		local exit_scheduled = false
		os.exit = function() error("os.exit must not run during the test") end
		_G.hs.timer.doAfter = function(_delay, _fn) exit_scheduled = true end  -- record, never fire

		local ok = pcall(Actions.execute_single, "script_quit")

		os.exit = saved_exit
		_G.hs.timer.doAfter = saved_doAfter
		package.loaded["modules.karabiner"] = nil

		helpers.assert_true(ok, "executing script_quit must not raise")
		helpers.assert_eq(killed.count, 1)  -- Karabiner torn down exactly once
		helpers.assert_true(exit_scheduled, "the quit must still schedule the process exit afterwards")
	end)
end)
