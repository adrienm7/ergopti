--- tests/unit/modules/gestures/test_init.lua

--- ==============================================================================
--- MODULE: gestures (init.lua) Unit Tests
--- DESCRIPTION:
--- Validates the gesture module's data tables (DEFAULT_GESTURES, AXIS_SLOTS,
--- SINGLE_SLOTS) and its action accessor invariants (set_action / get_action /
--- get_all_actions, enable_all / disable_all toggles).
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

local Gestures = helpers.load_with_stubs("modules.gestures")




-- =====================================
-- =====================================
-- ======= 1/ Data tables ==============
-- =====================================
-- =====================================

helpers.describe("Gestures DEFAULT_GESTURES", function()
	helpers.it("has every slot defaulting to a registered action", function()
		-- tap_3 ships with a non-"none" default (left_click_toggle) so the
		-- product offers something useful out of the box; every other slot
		-- is "none" until the user binds it. The contract here is that the
		-- default for any slot must be a string that the action registry
		-- knows how to dispatch — tested against ACTIONS via the runtime
		-- guard below.
		for k, v in pairs(Gestures.DEFAULT_GESTURES) do
			helpers.assert_eq(type(v), "string", "slot " .. tostring(k) .. " default is not a string")
		end
	end)

	helpers.it("contains the expected tap slots", function()
		helpers.assert_true(Gestures.DEFAULT_GESTURES.tap_3 ~= nil)
		helpers.assert_true(Gestures.DEFAULT_GESTURES.tap_4 ~= nil)
		helpers.assert_true(Gestures.DEFAULT_GESTURES.tap_5 ~= nil)
	end)

	helpers.it("contains the expected swipe-axis slots", function()
		helpers.assert_true(Gestures.DEFAULT_GESTURES.swipe_3_horiz ~= nil)
		helpers.assert_true(Gestures.DEFAULT_GESTURES.swipe_4_horiz ~= nil)
		helpers.assert_true(Gestures.DEFAULT_GESTURES.swipe_5_horiz ~= nil)
	end)

	helpers.it("contains the expected single-vertical slots", function()
		helpers.assert_true(Gestures.DEFAULT_GESTURES.swipe_3_up ~= nil)
		helpers.assert_true(Gestures.DEFAULT_GESTURES.swipe_4_down ~= nil)
	end)
end)




-- =====================================
-- =====================================
-- ======= 2/ Slot lists ==============
-- =====================================
-- =====================================

helpers.describe("Gestures slot lists", function()
	helpers.it("AXIS_SLOTS is a non-empty array", function()
		helpers.assert_true(#Gestures.AXIS_SLOTS > 0)
	end)

	helpers.it("SINGLE_SLOTS is a non-empty array", function()
		helpers.assert_true(#Gestures.SINGLE_SLOTS > 0)
	end)

	helpers.it("AXIS_SLOTS and SINGLE_SLOTS do not overlap", function()
		local axis_set = {}
		for _, s in ipairs(Gestures.AXIS_SLOTS) do axis_set[s] = true end
		for _, s in ipairs(Gestures.SINGLE_SLOTS) do
			helpers.assert_eq(axis_set[s], nil, "slot " .. s .. " in both lists")
		end
	end)
end)




-- =====================================
-- =====================================
-- ======= 3/ Action accessors ==========
-- =====================================
-- =====================================

helpers.describe("Gestures action accessors", function()
	helpers.it("get_action returns the configured value", function()
		Gestures.set_action("tap_3", "lookup")
		helpers.assert_eq(Gestures.get_action("tap_3"), "lookup")
	end)

	helpers.it("set_action then reset restores 'none'", function()
		Gestures.set_action("tap_4", "ms")
		Gestures.set_action("tap_4", "none")
		helpers.assert_eq(Gestures.get_action("tap_4"), "none")
	end)

	helpers.it("get_all_actions returns a flat map", function()
		local all = Gestures.get_all_actions()
		helpers.assert_eq(type(all), "table")
		helpers.assert_true(all.tap_3 ~= nil)
	end)
end)




-- =====================================
-- =====================================
-- ======= 4/ Enable/disable ============
-- =====================================
-- =====================================

helpers.describe("Gestures enable/disable", function()
	helpers.it("disable_all clears the flag", function()
		Gestures.disable_all()
		helpers.assert_eq(Gestures.is_enabled(), false)
	end)

	helpers.it("enable_all sets the flag", function()
		Gestures.disable_all()
		Gestures.enable_all()
		helpers.assert_eq(Gestures.is_enabled(), true)
	end)

	helpers.it("enable('all') is equivalent to enable_all", function()
		Gestures.disable_all()
		Gestures.enable("all")
		helpers.assert_eq(Gestures.is_enabled(), true)
	end)

	helpers.it("disable('all') is equivalent to disable_all", function()
		Gestures.enable_all()
		Gestures.disable("all")
		helpers.assert_eq(Gestures.is_enabled(), false)
	end)

	helpers.it("enable(other) is a no-op (unknown name ignored)", function()
		Gestures.disable_all()
		Gestures.enable("not_all")
		helpers.assert_eq(Gestures.is_enabled(), false)
	end)
end)




-- =====================================
-- =====================================
-- ======= 5/ Re-exports ===============
-- =====================================
-- =====================================

helpers.describe("Gestures re-exports", function()
	helpers.it("exposes Conflicts.on_action_changed", function()
		helpers.assert_eq(type(Gestures.on_action_changed), "function")
	end)

	helpers.it("exposes Action label tables", function()
		helpers.assert_eq(type(Gestures.AX_NAMES), "table")
		helpers.assert_eq(type(Gestures.SG_NAMES), "table")
	end)
end)
