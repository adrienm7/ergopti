--- tests/unit/modules/gestures/test_stop_force_cleanup.lua

--- ==============================================================================
--- MODULE: Gestures M.stop() force_cleanup Unit Test
--- DESCRIPTION:
--- Regression test that M.stop() actually invokes Actions.force_cleanup() so
--- that any held synthetic mouse click is released on module teardown.
---
--- ROOT CAUSE ENCODED:
--- M.stop() stopped watchers, timers and the primer but never called
--- Actions.force_cleanup(). If the user had an active gesture-held click
--- (toggle_right_click or long-press left-click) at the time of a reload or
--- explicit stop(), the OS button state remained stuck until a physical click
--- was performed (gesture-stuck-click-on-stop).
--- ==============================================================================

local helpers = require("tests.helpers")

-- -------------------------------------------------------
-- Stub sub-modules before loading gestures so no OS calls
-- -------------------------------------------------------
package.loaded["infra.logger"] = nil
helpers.load_with_stubs("infra.logger")

local force_cleanup_called = false

package.loaded["modules.gestures.actions"] = {
	AX_NAMES             = {},
	SG_NAMES             = {},
	init                 = function() end,
	get_sg_names         = function() return {} end,
	get_label            = function() return "" end,
	force_cleanup        = function() force_cleanup_called = true; return true end,
	toggle_right_click   = function() end,
	trigger_lookup       = function() end,
	is_right_click_held  = function() return false end,
}

package.loaded["modules.gestures.engine"] = {
	init          = function() end,
	process_frame = function() end,
	stop          = function() return true end,
}

package.loaded["modules.gestures.conflicts"] = {
	on_action_changed     = function() end,
	apply_all_overrides   = function() end,
	restore_all_overrides = function() end,
}

package.loaded["modules.gestures"] = nil
local Gestures = helpers.load_with_stubs("modules.gestures")

-- Helper: clear the live watcher / device tables the module aliases
local function clear_live_tables()
	for k in pairs(_G.ERGOPTI_TOUCH_WATCHERS or {}) do
		_G.ERGOPTI_TOUCH_WATCHERS[k] = nil
	end
	for k in pairs(_G.ERGOPTI_TOUCH_DEVICES or {}) do
		_G.ERGOPTI_TOUCH_DEVICES[k] = nil
	end
end





-- ===============================================
-- ===============================================
-- ======= 1/ force_cleanup called on stop =======
-- ===============================================
-- ===============================================

helpers.describe("gestures M.stop(): calls Actions.force_cleanup (gesture-stuck-click-on-stop)", function()

	helpers.it("M.stop() invokes Actions.force_cleanup()", function()
		clear_live_tables()
		force_cleanup_called = false

		helpers.assert_eq(Gestures.stop(), true,
			"the cleanup observation must come from a fully settled stop transaction")

		helpers.assert_true(force_cleanup_called,
			"M.stop() must call Actions.force_cleanup() to release held synthetic clicks (gesture-stuck-click-on-stop)")
	end)

	helpers.it("force_cleanup is called even when no watchers are registered", function()
		clear_live_tables()
		force_cleanup_called = false

		helpers.assert_eq(Gestures.stop(), true,
			"the no-watcher path must still settle every production endpoint")

		helpers.assert_true(force_cleanup_called,
			"M.stop() must call force_cleanup() regardless of watcher count (gesture-stuck-click-on-stop)")
	end)

	helpers.it("force_cleanup is still called on a second stop() call", function()
		clear_live_tables()
		helpers.assert_eq(Gestures.stop(), true)

		force_cleanup_called = false
		helpers.assert_eq(Gestures.stop(), true,
			"an idempotent retry must not hide an unrelated engine cleanup refusal")

		helpers.assert_true(force_cleanup_called,
			"M.stop() must call force_cleanup() on every invocation (idempotence + gesture-stuck-click-on-stop)")
	end)

end)
