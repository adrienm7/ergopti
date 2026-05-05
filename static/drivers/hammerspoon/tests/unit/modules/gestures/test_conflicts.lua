--- tests/unit/modules/gestures/test_conflicts.lua

--- ==============================================================================
--- MODULE: gestures.conflicts Unit Tests
--- DESCRIPTION:
--- Validates the macOS gesture conflict detector: on_action_changed returns a
--- structured warning for known conflicting slots, nil for everything else.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

local Conflicts = helpers.load_with_stubs("modules.gestures.conflicts")




-- =====================================
-- =====================================
-- ======= 1/ on_action_changed =========
-- =====================================
-- =====================================

helpers.describe("Conflicts.on_action_changed", function()
	helpers.it("returns nil for action 'none'", function()
		helpers.assert_eq(Conflicts.on_action_changed("tap_3", "none"), nil)
	end)

	helpers.it("returns warning for tap_3 with non-none action", function()
		local w = Conflicts.on_action_changed("tap_3", "lookup")
		helpers.assert_true(type(w) == "table")
		helpers.assert_true(type(w.msg) == "string" and w.msg ~= "")
		helpers.assert_true(type(w.url) == "string" and w.url ~= "")
	end)

	helpers.it("returns nil for unknown slot", function()
		helpers.assert_eq(Conflicts.on_action_changed("nonexistent", "lookup"), nil)
	end)

	helpers.it("returns warning for swipe_3_horiz", function()
		local w = Conflicts.on_action_changed("swipe_3_horiz", "back")
		helpers.assert_true(type(w) == "table")
	end)

	helpers.it("returns warning for swipe_4_up (in vertical group)", function()
		local w = Conflicts.on_action_changed("swipe_4_up", "ms")
		helpers.assert_true(type(w) == "table")
	end)

	helpers.it("warning URL is a System Settings deeplink", function()
		local w = Conflicts.on_action_changed("tap_3", "lookup")
		helpers.assert_true(w.url:find("x%-apple%.systempreferences") ~= nil)
	end)

	helpers.it("warning message starts with a separator dash line", function()
		local w = Conflicts.on_action_changed("tap_3", "lookup")
		-- Should have the U+2500 box-drawing dashes
		helpers.assert_true(w.msg:find("─") ~= nil)
	end)
end)




-- =========================================
-- =========================================
-- ======= 2/ apply_all_overrides ===========
-- =========================================
-- =========================================

helpers.describe("Conflicts.apply_all_overrides", function()
	helpers.it("does not error with an empty actions table", function()
		Conflicts.apply_all_overrides({})
	end)

	helpers.it("does not error with active actions", function()
		Conflicts.apply_all_overrides({ tap_3 = "lookup", swipe_3_up = "ms" })
	end)
end)




-- =========================================
-- =========================================
-- ======= 3/ restore_all_overrides =========
-- =========================================
-- =========================================

helpers.describe("Conflicts.restore_all_overrides", function()
	helpers.it("is a no-op", function()
		Conflicts.restore_all_overrides()
	end)
end)
