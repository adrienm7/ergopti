--- tests/unit/shortcuts/engine/keyboard/test_stop_guard.lua

--- ==============================================================================
--- MODULE: Keyboard Shortcuts Idle-stop Regression
--- DESCRIPTION:
--- Proves an owner with neither a committed start nor cleanup debt returns exact
--- success without emitting a misleading lifecycle start/success pair.
---
--- The former source-spelling test required `if not _started then`, which made
--- the suite reject the necessary partial-ownership cleanup guard. This test
--- drives observable behaviour so both invariants can coexist.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ======================================
-- ======================================
-- ======= 1/ Idle Stop Behaviour =======
-- ======================================
-- ======================================

helpers.describe("keyboard shortcuts: idle stop guard", function()
	helpers.it("returns exact true without opening a lifecycle log pair", function()
		local starts = 0
		local successes = 0
		local logger = helpers.make_logger_stub()
		logger.start = function() starts = starts + 1 end
		logger.success = function() successes = successes + 1 end

		package.loaded["core.logger.engine.logger"] = logger
		package.loaded["platform.input.hotkey_registrar"] = {
			bind = function() return nil end,
			unbind = function() return true end,
		}
		package.loaded["core.fs.adapters.file_system"] = {read = function() return nil end}
		package.loaded["core.fs.engine.paths"] = {shared = function() return "catalogue.json" end}
		package.loaded["gestures.engine.actions"] = {execute_single = function() end}
		package.loaded["shortcuts.engine.keyboard_shortcuts"] = nil

		local subject = helpers.load_with_stubs("shortcuts.engine.keyboard_shortcuts")
		helpers.assert_eq(subject.stop(), true,
			"an idle owner has no cleanup debt and must settle exactly")
		helpers.assert_eq(starts, 0,
			"idle stop must not log a lifecycle start for work it did not perform")
		helpers.assert_eq(successes, 0,
			"idle stop must not log a matching but equally misleading success")
	end)
end)

return true
