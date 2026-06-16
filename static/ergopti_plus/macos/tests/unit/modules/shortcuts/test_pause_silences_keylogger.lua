--- tests/unit/modules/shortcuts/test_pause_silences_keylogger.lua

--- ==============================================================================
--- MODULE: shortcuts.script_control — keylogger silencing regression tests
--- DESCRIPTION:
--- Regression suite verifying that pause_all() calls keylogger.pause() and
--- resume_all() calls keylogger.resume() so that no keystrokes are recorded
--- while the script is suspended.
---
--- RATIONALE:
--- An active keylogger eventtap during pause logs phantom activity with no
--- corresponding processing context.  These tests pin the contract so that
--- a future refactor cannot accidentally remove the keylogger silencing calls.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Stub lib.logger before any module load so Logger calls are silent no-ops.
package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

-- Minimal stubs required for script_control.lua to load at the top level.
package.loaded["lib.notifications"] = { notify = function() end }
package.loaded["lib.keycodes"] = {
	F13_KARABINER_RETURN    = 0x6A,
	F14_KARABINER_BACKSPACE = 0x6B,
	F15_KARABINER_ESCAPE    = 0x6C,
	BACKSPACE = 0x33,
	RETURN    = 0x24,
	ESCAPE    = 0x35,
}
package.loaded["lib.i18n"] = { get = function(k) return k end, get_locale = function() return "fr" end }
package.loaded["modules.gestures.engine"] = { init = function() end }
package.loaded["modules.gestures.conflicts"] = { on_action_changed = function() end }
package.loaded["modules.gestures.actions"] = {
	init      = function() end,
	get_label = function(n) return n end,
	SG_NAMES  = { "none", "script_pause_toggle", "script_reload", "script_quit" },
	AX_NAMES  = {},
}

local SC = helpers.load_with_stubs("modules.shortcuts.script_control")




-- =========================================================
--- =========================================================
-- ======= 1/ pause_all() silences the keylogger tap =======
--- =========================================================
-- =========================================================

helpers.describe("ScriptControl.pause_all() — keylogger silencing (regression)", function()
	helpers.it("calls keylogger.pause() when pause_all() is invoked", function()
		-- Build a mock keylogger that tracks which methods were called.
		-- The production code invokes _keylogger.pause() (no colon), so closures
		-- over local flags are used rather than method receivers.
		local pause_called  = false
		local resume_called = false
		local mock_keylogger = {
			pause  = function() pause_called  = true end,
			resume = function() resume_called = true end,
		}

		-- Provide minimal stubs for the sibling modules so M.start() does not warn
		local fake_keymap = {
			pause_processing  = function() end,
			resume_processing = function() end,
			reset_predictions = function() end,
		}
		local fake_shortcuts = {
			pause_bindings  = function() end,
			resume_bindings = function() end,
		}
		local fake_gestures = {
			disable_all = function() end,
			enable_all  = function() end,
		}

		-- Arm the module with the mock keylogger injected as the fifth argument
		SC.start(fake_keymap, fake_shortcuts, fake_gestures, nil, mock_keylogger)

		-- Ensure we start from a known unpaused state
		if SC.is_paused() then SC.resume_all() end

		SC.pause_all()

		helpers.assert_true(pause_called,
			"pause_all() must call keylogger.pause() to silence the eventtap")

		SC.stop()
	end)
end)




-- =========================================================
--- =========================================================
-- ======= 2/ resume_all() re-arms the keylogger tap =======
--- =========================================================
-- =========================================================

helpers.describe("ScriptControl.resume_all() — keylogger re-arming (regression)", function()
	helpers.it("calls keylogger.resume() when resume_all() is invoked", function()
		-- Closures over local flags — production code calls _keylogger.resume() without colon
		local pause_called  = false
		local resume_called = false
		local mock_keylogger = {
			pause  = function() pause_called  = true end,
			resume = function() resume_called = true end,
		}

		local fake_keymap = {
			pause_processing  = function() end,
			resume_processing = function() end,
			reset_predictions = function() end,
		}
		local fake_shortcuts = {
			pause_bindings  = function() end,
			resume_bindings = function() end,
		}
		local fake_gestures = {
			disable_all = function() end,
			enable_all  = function() end,
		}

		SC.start(fake_keymap, fake_shortcuts, fake_gestures, nil, mock_keylogger)

		-- Drive the module into paused state first so resume_all() has an effect
		if SC.is_paused() then SC.resume_all() end
		SC.pause_all()
		resume_called = false  -- reset flag after the pause transition

		SC.resume_all()

		helpers.assert_true(resume_called,
			"resume_all() must call keylogger.resume() to re-arm the eventtap")

		SC.stop()
	end)
end)




-- =============================================================
--- =============================================================
-- ======= 3/ Full pause→resume cycle calls both methods =======
--- =============================================================
-- =============================================================

helpers.describe("ScriptControl pause→resume cycle — keylogger call symmetry", function()
	helpers.it("pause() then resume() each call their respective keylogger method exactly once", function()
		local pause_count  = 0
		local resume_count = 0

		local mock_keylogger = {
			pause  = function() pause_count  = pause_count  + 1 end,
			resume = function() resume_count = resume_count + 1 end,
		}

		local fake_keymap = {
			pause_processing  = function() end,
			resume_processing = function() end,
			reset_predictions = function() end,
		}
		local fake_shortcuts = {
			pause_bindings  = function() end,
			resume_bindings = function() end,
		}
		local fake_gestures = {
			disable_all = function() end,
			enable_all  = function() end,
		}

		SC.start(fake_keymap, fake_shortcuts, fake_gestures, nil, mock_keylogger)

		if SC.is_paused() then SC.resume_all() end

		SC.pause_all()
		helpers.assert_eq(pause_count,  1, "keylogger.pause must be called exactly once after pause_all()")
		helpers.assert_eq(resume_count, 0, "keylogger.resume must not be called during pause_all()")

		SC.resume_all()
		helpers.assert_eq(pause_count,  1, "keylogger.pause must not be called during resume_all()")
		helpers.assert_eq(resume_count, 1, "keylogger.resume must be called exactly once after resume_all()")

		SC.stop()
	end)

	helpers.it("idempotent pause does not double-call keylogger.pause()", function()
		local pause_count = 0

		local mock_keylogger = {
			pause  = function() pause_count = pause_count + 1 end,
			resume = function() end,
		}

		local fake_keymap = {
			pause_processing  = function() end,
			resume_processing = function() end,
			reset_predictions = function() end,
		}
		local fake_shortcuts = {
			pause_bindings  = function() end,
			resume_bindings = function() end,
		}
		local fake_gestures = {
			disable_all = function() end,
			enable_all  = function() end,
		}

		SC.start(fake_keymap, fake_shortcuts, fake_gestures, nil, mock_keylogger)

		if SC.is_paused() then SC.resume_all() end

		SC.pause_all()
		SC.pause_all()  -- second call must be a no-op (guard: if _is_paused then return end)

		helpers.assert_eq(pause_count, 1,
			"pause_all() is idempotent — keylogger.pause must only be called once")

		SC.resume_all()
		SC.stop()
	end)
end)




-- ===========================================================
--- ===========================================================
-- ======= 4/ Source-level invariant (grep regression) =======
--- ===========================================================
-- ===========================================================

helpers.describe("script_control.lua source — keylogger silencing grep invariant", function()
	-- This test encodes the root cause at the textual level so that a refactor
	-- which removes the keylogger calls fails visibly even before the mock tests run.
	helpers.it("source references _keylogger.pause and _keylogger.resume", function()
		local src_path = helpers.driver_root() .. "modules/shortcuts/script_control.lua"
		local fh = io.open(src_path, "r")
		helpers.assert_true(fh ~= nil,
			"script_control.lua must be readable at " .. tostring(src_path))
		local src = fh:read("*a"); fh:close()

		helpers.assert_true(src:find("_keylogger.pause", 1, true) ~= nil,
			"script_control.lua must call _keylogger.pause() inside pause_all()")
		helpers.assert_true(src:find("_keylogger.resume", 1, true) ~= nil,
			"script_control.lua must call _keylogger.resume() inside resume_all()")
	end)
end)
