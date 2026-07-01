--- tests/meta/test_init_onboarding_before_prestart.lua

--- ==============================================================================
--- MODULE: Regression — onboarding short-circuit fires before gestures pre-start (M-14)
--- DESCRIPTION:
--- Before M-14, init.lua ran gestures.start() and shortcuts.start() (Section 1
--- Module Pre-start) BEFORE the onboarding early-return check in Section 3.
--- On first launch (no config.toml), the wizard ran with gestures active:
--- CoreState.enabled=true meant 3-finger taps fired synthetic clicks and swipes
--- sent Alt+arrow keys to the focused window — all before the user consented.
---
--- Fix: the onboarding should_run/return block was moved to BEFORE Section 1,
--- so gestures and shortcuts are never pre-started during the wizard.
---
--- Test: source scan — assert the onboarding guard byte-position is strictly
--- before both gestures.start() and require("modules.llm.boot_cleanup").
--- ==============================================================================

local helpers = require("tests.helpers")





-- ==================================================================================
-- =================================================================================
-- ======= 1/ init.lua: onboarding check is before gestures pre-start (M-14) =======
-- =================================================================================
-- ==================================================================================

helpers.describe("M-14: onboarding short-circuit before module pre-start", function()

	helpers.it("onboarding.should_run appears before gestures.start() in init.lua", function()
		local path = helpers.driver_root() .. "init.lua"
		local fh   = io.open(path, "r")
		helpers.assert_true(fh ~= nil, "init.lua must be readable")
		local src  = fh:read("*a"); fh:close()

		local ob_pos      = src:find("should_run", 1, true)
		local gesture_pos = src:find("gestures.start()", 1, true)

		helpers.assert_true(ob_pos ~= nil,
			"init.lua must call onboarding.should_run() to guard first-launch")
		helpers.assert_true(gesture_pos ~= nil,
			"init.lua must call gestures.start()")
		helpers.assert_true(ob_pos < gesture_pos,
			"onboarding.should_run() must appear BEFORE gestures.start() in init.lua — " ..
			"gestures must not arm before the user has completed the wizard (M-14)")
	end)

	helpers.it("onboarding.should_run appears before boot_cleanup in init.lua", function()
		local path = helpers.driver_root() .. "init.lua"
		local fh   = io.open(path, "r")
		helpers.assert_true(fh ~= nil, "init.lua must be readable")
		local src  = fh:read("*a"); fh:close()

		local ob_pos      = src:find("should_run", 1, true)
		local cleanup_pos = src:find("boot_cleanup", 1, true)

		helpers.assert_true(ob_pos ~= nil,
			"init.lua must call onboarding.should_run()")
		helpers.assert_true(cleanup_pos ~= nil,
			"init.lua must reference boot_cleanup")
		helpers.assert_true(ob_pos < cleanup_pos,
			"onboarding.should_run() must appear BEFORE boot_cleanup in init.lua (M-14)")
	end)
end)
