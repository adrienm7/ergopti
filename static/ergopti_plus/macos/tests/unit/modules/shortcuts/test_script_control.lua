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
