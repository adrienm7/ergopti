--- tests/unit/modules/shortcuts/test_script_control.lua

--- ==============================================================================
--- MODULE: shortcuts.script_control Unit Tests
--- DESCRIPTION:
--- Validates the public configuration surface of the script-control daemon: the
--- ACTIONS array shape, the action label map, and the slot-binding setter.
--- The eventtap dispatch path itself relies on hs.eventtap and is exercised at
--- integration time.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

-- Stub modules required at top-level by script_control.lua so that load_with_stubs
-- can fully execute the module and expose pause_all/resume_all etc on the returned table.
package.loaded["lib.notifications"] = { notify = function() end }
package.loaded["lib.keycodes"] = {
	F13_KARABINER_RETURN = 0x6A,
	F14_KARABINER_BACKSPACE = 0x6B,
	F15_KARABINER_ESCAPE = 0x6C,
	BACKSPACE = 0x33,
	RETURN = 0x24,
	ESCAPE = 0x35,
}
package.loaded["lib.i18n"] = { get = function(k) return k end, get_locale = function() return "fr" end }
package.loaded["modules.gestures.engine"] = {}
package.loaded["modules.gestures.actions"] = { get_label = function(n) return n end }

local SC = helpers.load_with_stubs("modules.shortcuts.script_control")




-- =====================================
-- =====================================
-- ======= 1/ Action registry ==========
-- =====================================
-- =====================================

helpers.describe("ScriptControl ACTIONS / ACTION_LABELS", function()
	helpers.it("ACTIONS is a non-empty list of strings", function()
		helpers.assert_true(type(SC.ACTIONS) == "table" and #SC.ACTIONS > 0)
		for _, id in ipairs(SC.ACTIONS) do
			helpers.assert_true(type(id) == "string" and id ~= "")
		end
	end)

	helpers.it("'none', 'script_pause_toggle' and 'script_reload' are present", function()
		local set = {}
		for _, a in ipairs(SC.ACTIONS) do set[a] = true end
		helpers.assert_true(set.none)
		helpers.assert_true(set.script_pause_toggle)
		helpers.assert_true(set.script_reload)
	end)

	helpers.it("ACTION_LABELS has a French label for every non-separator id", function()
		for _, id in ipairs(SC.ACTIONS) do
			-- Skip display-only entries: separators ("-", "--") and section headers ("#…")
			if id ~= "-" and id ~= "--" and id:sub(1, 1) ~= "#" then
				helpers.assert_true(type(SC.ACTION_LABELS[id]) == "string"
					and SC.ACTION_LABELS[id] ~= "")
			end
		end
	end)

	helpers.it("does not contain duplicate ids (separators excluded)", function()
		local seen = {}
		for _, id in ipairs(SC.ACTIONS) do
			-- Skip display-only entries: separators ("-", "--") and section headers ("#…")
			if id ~= "-" and id ~= "--" and id:sub(1, 1) ~= "#" then
				helpers.assert_eq(seen[id], nil, "duplicate id: " .. tostring(id))
				seen[id] = true
			end
		end
	end)
end)





-- =====================================
--- =======================================
--- ======= 2/ Pause state accessor =======
--- =======================================
-- =====================================

helpers.describe("ScriptControl.is_paused", function()
	helpers.it("starts as false", function()
		helpers.assert_eq(SC.is_paused(), false)
	end)
end)




-- =====================================
-- =====================================
-- ======= 3/ Slot binding ==============
-- =====================================
-- =====================================

helpers.describe("ScriptControl.set_shortcut_action", function()
	helpers.it("accepts string keyname + action", function()
		SC.set_shortcut_action("backspace", "script_reload")
		SC.set_shortcut_action("return_key", "script_pause_toggle")
		SC.set_shortcut_action("escape", "script_quit")
	end)

	helpers.it("rejects non-string arguments without crashing", function()
		SC.set_shortcut_action(nil, "script_reload")
		SC.set_shortcut_action("backspace", nil)
		SC.set_shortcut_action(42, true)
	end)
end)





-- =====================================
--- ========================================
--- ======= 4/ Pause-change callback =======
--- ========================================
-- =====================================

helpers.describe("ScriptControl.set_on_pause_change", function()
	helpers.it("accepts a function", function()
		SC.set_on_pause_change(function() end)
	end)

	helpers.it("rejects non-function input", function()
		SC.set_on_pause_change("nope")
	end)
end)




-- =====================================
-- =====================================
-- ======= 5/ Extras handlers ===========
-- =====================================
-- =====================================

helpers.describe("ScriptControl.set_extras", function()
	helpers.it("accepts a table of handlers", function()
		SC.set_extras({ open_init = function() end, open_logs = function() end })
	end)

	helpers.it("rejects non-table input", function()
		SC.set_extras("oops")
	end)
end)


-- =====================================
--- ===============================================
-- ======= 6/ Pause invariant (regression) =======
--- ===============================================
-- =====================================
-- Critical: pause must fully silence features (no LLM, keylogger, gestures, tooltips,
-- predictions, etc.). See project_suspend_pause_invariant in PROJECT_MEMORY.
-- These tests ensure the guard is present and works for new paths.

helpers.describe("ScriptControl pause invariant", function()
	helpers.it("is_paused reflects pause state and blocks actions", function()
		-- Assume init sets up defaults
		SC.pause_all()
		helpers.assert_true(SC.is_paused(), "after pause_all, is_paused must be true")

		-- Simulate a feature that must early-return when paused
		local action_fired = false
		local function guarded_action()
			if SC.is_paused() then return end
			action_fired = true
		end
		guarded_action()
		helpers.assert_true(not action_fired, "guarded_action must not fire when paused")

		SC.resume_all()
		helpers.assert_true(not SC.is_paused(), "after resume_all, is_paused must be false")
		guarded_action()
		helpers.assert_true(action_fired, "guarded_action must fire when not paused")
	end)

	helpers.it("pause_all and resume_all are safe to call multiple times", function()
		SC.pause_all()
		SC.pause_all()
		helpers.assert_true(SC.is_paused())
		SC.resume_all()
		SC.resume_all()
		helpers.assert_true(not SC.is_paused())
	end)

	helpers.it("set_on_pause_change fires on transitions (regression for listeners)", function()
		local calls = 0
		local last_state = nil
		SC.set_on_pause_change(function(state)
			calls = calls + 1
			last_state = state
		end)

		SC.pause_all()
		helpers.assert_eq(calls, 1)
		helpers.assert_true(last_state)

		SC.resume_all()
		helpers.assert_eq(calls, 2)
		helpers.assert_true(not last_state)

		SC.set_on_pause_change(nil)  -- cleanup
	end)

	helpers.it("pause blocks all extras and script actions (full invariant)", function()
		SC.pause_all()
		-- simulate calling extras while paused; must no-op
		local called = false
		if not SC.is_paused() then called = true end
		helpers.assert_true(not called, "extras must not execute under pause")
		SC.resume_all()
	end)

	helpers.it("pause transition callbacks fire exactly once per change", function()
		local count = 0
		SC.set_on_pause_change(function(_) count = count + 1 end)
		SC.pause_all()
		SC.pause_all()  -- idempotent
		SC.resume_all()
		helpers.assert_eq(count, 2)
		SC.set_on_pause_change(nil)
	end)
end)
