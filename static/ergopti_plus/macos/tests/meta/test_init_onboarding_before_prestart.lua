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





-- =================================================================================
-- =================================================================================
-- ======= 1/ init.lua: onboarding check is before gestures pre-start (M-14) =======
-- =================================================================================
-- =================================================================================

helpers.describe("M-14: onboarding short-circuit before module pre-start", function()

	helpers.it("onboarding.should_run appears before gestures.start() in init.lua", function()
		-- Selected by a declaration unique to init.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function has_common_hotstring_groups")
		helpers.assert_true(src ~= nil, "init.lua source must be locatable")

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
		-- Selected by a declaration unique to init.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function has_common_hotstring_groups")
		helpers.assert_true(src ~= nil, "init.lua source must be locatable")

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





-- =================================================================================
-- =================================================================================
-- ======= 2/ ui.onboarding load failure aborts boot (fail-fast, no consent) =======
-- =================================================================================
-- =================================================================================

helpers.describe("ui.onboarding require failure is fail-fast, not silently skipped", function()

	-- Root cause: the first-launch guard loads ui.onboarding via pcall(require).
	-- If that require failed, the block used to fall through and pre-start gestures
	-- and shortcuts anyway — arming synthetic input BEFORE the user consented. The
	-- not-ok case must log a Logger.error and return (abort boot) between the
	-- require and the first use, and the whole guard must precede gestures.start().
	helpers.it("aborts with Logger.error + return when ui.onboarding fails to load", function()
		-- Selected by a declaration unique to init.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function has_common_hotstring_groups")
		helpers.assert_true(src ~= nil, "init.lua source must be locatable")

		local req_pos     = src:find("pcall(require, \"ui.onboarding\")", 1, true)
		local should_pos  = src:find("should_run", 1, true)
		local gesture_pos = src:find("gestures.start()", 1, true)

		helpers.assert_true(req_pos ~= nil,
			"init.lua must load ui.onboarding via a guarded pcall(require, ...)")
		helpers.assert_true(should_pos ~= nil and should_pos > req_pos,
			"the first-launch check must follow the guarded require")

		-- The failure branch must live between the require and its first use.
		local guard = src:sub(req_pos, should_pos)
		helpers.assert_true(guard:find("not ok_ob", 1, true) ~= nil,
			"the require must be guarded on the not-ok case (no silent continue)")
		helpers.assert_true(guard:find("Logger.error", 1, true) ~= nil,
			"a failed ui.onboarding load must be logged as an ERROR, not swallowed")
		helpers.assert_true(guard:find("return", 1, true) ~= nil,
			"a failed ui.onboarding load must abort boot (return) rather than arm input modules")

		helpers.assert_true(gesture_pos ~= nil and should_pos < gesture_pos,
			"the onboarding guard must run before gestures.start()")
	end)
end)
