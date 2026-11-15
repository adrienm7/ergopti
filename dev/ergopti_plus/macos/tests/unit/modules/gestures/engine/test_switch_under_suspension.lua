--- tests/unit/modules/gestures/engine/test_switch_under_suspension.lua

--- ==============================================================================
--- MODULE: Gesture switch recorded under a pause (EDD-1)
--- DESCRIPTION:
--- A pause stops typing, not configuration (maintainer decision 2026-11-12):
--- the Gestures switch flipped while ScriptControl suspension is active is
--- recorded at once and applied on resume. Switching ON never starts the native
--- runtime under the pause; switching OFF releases it; resume() follows the
--- recorded flag.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.gesture_runtime_fixture").with_fixture





-- ==========================================
-- ==========================================
-- ======= 1/ Switch Under Suspension =======
-- ==========================================
-- ==========================================

helpers.describe("gestures: switch recorded under a pause (edd1-paused-writes)", function()
	helpers.it("records ON without a native start, then starts on resume", function()
		with_fixture({}, function(gestures, _, watcher)
			helpers.assert_eq(gestures.disable_all(), true)
			helpers.assert_eq(gestures.suspend(), true)
			local starts = watcher.start_calls
			helpers.assert_eq(gestures.set_enabled_under_suspension(true), true)
			helpers.assert_eq(gestures.is_enabled(), true, "the feature flag follows the switch")
			helpers.assert_eq(gestures.is_suspended(), true, "the pause stays in force")
			helpers.assert_eq(watcher.start_calls, starts, "no native start under the pause")
			helpers.assert_eq(gestures.resume(), true)
			helpers.assert_true(watcher.start_calls > starts, "resume starts the recorded runtime")
			helpers.assert_eq(watcher:running(), true)
			helpers.assert_eq(gestures.stop(), true)
		end)
	end)

	helpers.it("records OFF and resume keeps the runtime stopped", function()
		with_fixture({}, function(gestures, _, watcher)
			helpers.assert_eq(gestures.start(), true)
			helpers.assert_eq(gestures.suspend(), true)
			helpers.assert_eq(gestures.set_enabled_under_suspension(false), true)
			helpers.assert_eq(gestures.is_enabled(), false)
			helpers.assert_eq(watcher:running(), false, "OFF releases the native runtime")
			local starts = watcher.start_calls
			helpers.assert_eq(gestures.resume(), true)
			helpers.assert_eq(gestures.is_enabled(), false)
			helpers.assert_eq(watcher.start_calls, starts, "resume does not restart a recorded OFF")
		end)
	end)

	helpers.it("refuses outside a suspension and a non-boolean posture", function()
		with_fixture({}, function(gestures)
			helpers.assert_eq(gestures.set_enabled_under_suspension(true), false,
				"outside a pause the switch goes through enable_all")
			helpers.assert_eq(gestures.suspend(), true)
			helpers.assert_eq(gestures.set_enabled_under_suspension("on"), false)
			helpers.assert_eq(gestures.resume(), true)
			helpers.assert_eq(gestures.stop(), true)
		end)
	end)
end)
