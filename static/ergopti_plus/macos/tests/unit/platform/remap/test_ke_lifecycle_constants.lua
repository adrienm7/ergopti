--- tests/unit/platform/remap/test_ke_lifecycle_constants.lua

--- ==============================================================================
--- MODULE: karabiner.ke_lifecycle constants smoke
--- DESCRIPTION:
--- The ke_lifecycle module talks to launchctl and pkill — so its runtime side
--- is integration-only. This file asserts the public surface exists and that
--- the exposed shell commands are non-empty strings, which is enough to catch
--- accidental constant deletions during refactors.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

local KE = helpers.load_with_stubs("platform.remap.ke_lifecycle")




-- =====================================
-- =====================================
-- ======= 1/ Public surface ===========
-- =====================================
-- =====================================

helpers.describe("KELifecycle public surface", function()
	helpers.it("exposes lifecycle functions", function()
		helpers.assert_eq(type(KE.is_grabber_running), "function")
		helpers.assert_eq(type(KE.launch_headless), "function")
		helpers.assert_eq(type(KE.open_gui), "function")
	end)

	helpers.it("exposes KILL_CMD as a non-empty string", function()
		helpers.assert_true(type(KE.KILL_CMD) == "string" and KE.KILL_CMD ~= "")
		-- Should reference launchctl bootout and pkill
		helpers.assert_true(KE.KILL_CMD:find("launchctl") ~= nil)
		helpers.assert_true(KE.KILL_CMD:find("pkill") ~= nil)
	end)
end)
