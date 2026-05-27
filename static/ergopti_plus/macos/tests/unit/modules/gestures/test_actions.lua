--- tests/unit/modules/gestures/test_actions.lua

--- ==============================================================================
--- MODULE: gestures.actions Unit Tests
--- DESCRIPTION:
--- Validates the action registry data structures: AX_NAMES / SG_NAMES coverage,
--- get_label() lookup, and execute_axis / execute_single dispatch contract.
---
--- These tests focus on the lookup-table validation requested in the test sprint:
--- which gesture id maps to which callable action. The actual OS side-effects
--- (keyStroke posting, AppleScript dispatch) are not asserted — that requires a
--- live macOS host and is intentionally out of scope.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

local Actions = helpers.load_with_stubs("modules.gestures.actions")




-- =====================================
--- =====================================
-- ======= 1/ Public API Surface =======
--- =====================================
-- =====================================

helpers.describe("gestures.actions: public API", function()
	helpers.it("exposes AX_NAMES as a non-empty list", function()
		helpers.assert_eq(type(Actions.AX_NAMES), "table")
		helpers.assert_true(#Actions.AX_NAMES > 0)
	end)

	helpers.it("exposes SG_NAMES as a non-empty list", function()
		helpers.assert_eq(type(Actions.SG_NAMES), "table")
		helpers.assert_true(#Actions.SG_NAMES > 0)
	end)

	helpers.it("exposes the documented function surface", function()
		helpers.assert_eq(type(Actions.get_label),            "function")
		helpers.assert_eq(type(Actions.execute_single),       "function")
		helpers.assert_eq(type(Actions.execute_axis),         "function")
		helpers.assert_eq(type(Actions.is_scalable),          "function")
		helpers.assert_eq(type(Actions.is_right_click_held),  "function")
		helpers.assert_eq(type(Actions.toggle_right_click),   "function")
		helpers.assert_eq(type(Actions.force_cleanup),        "function")
		helpers.assert_eq(type(Actions.trigger_lookup),       "function")
	end)
end)




-- =================================
--- =================================
-- ======= 2/ AX_NAMES Shape =======
--- =================================
-- =================================

helpers.describe("gestures.actions: AX_NAMES contents", function()
	local function contains(t, v)
		for _, x in ipairs(t) do if x == v then return true end end
		return false
	end

	helpers.it("includes the canonical axis ids", function()
		for _, id in ipairs({
			"none", "tabs", "windows", "spaces",
			"volume", "brightness", "tracks",
			"words", "lines", "line_bounds", "paragraphs", "document",
		}) do
			helpers.assert_true(contains(Actions.AX_NAMES, id), "missing AX id: " .. id)
		end
	end)

	helpers.it("starts with 'none' as the disabled-axis sentinel", function()
		helpers.assert_eq(Actions.AX_NAMES[1], "none")
	end)
end)




-- =================================
--- =================================
-- ======= 3/ SG_NAMES Shape =======
--- =================================
-- =================================

helpers.describe("gestures.actions: SG_NAMES contents", function()
	local function contains(t, v)
		for _, x in ipairs(t) do if x == v then return true end end
		return false
	end

	helpers.it("includes the navigation single-action ids", function()
		for _, id in ipairs({
			"right_click_toggle", "lookup",
			"tab_new", "tab_close", "tab_prev", "tab_next",
			"win_prev", "win_next", "space_prev", "space_next",
			"mission_control", "app_expose",
		}) do
			helpers.assert_true(contains(Actions.SG_NAMES, id), "missing SG id: " .. id)
		end
	end)

	helpers.it("includes the media single-action ids", function()
		for _, id in ipairs({
			"vol_up", "vol_down", "brightness_up", "brightness_down", "mute",
			"track_play", "track_next", "track_prev",
		}) do
			helpers.assert_true(contains(Actions.SG_NAMES, id), "missing media SG id: " .. id)
		end
	end)
end)




-- ===============================
-- ===============================
-- ======= 4/ get_label() ========
-- ===============================
-- ===============================

helpers.describe("gestures.actions: get_label", function()
	helpers.it("returns a non-empty string for an axis id", function()
		helpers.assert_true(type(Actions.get_label("tabs"))    == "string" and Actions.get_label("tabs")    ~= "")
		helpers.assert_true(type(Actions.get_label("volume"))  == "string" and Actions.get_label("volume")  ~= "")
		helpers.assert_true(type(Actions.get_label("windows")) == "string" and Actions.get_label("windows") ~= "")
	end)

	helpers.it("returns a non-empty string for a single id", function()
		helpers.assert_true(type(Actions.get_label("mute"))       == "string" and Actions.get_label("mute")       ~= "")
		helpers.assert_true(type(Actions.get_label("track_play")) == "string" and Actions.get_label("track_play") ~= "")
		helpers.assert_true(type(Actions.get_label("lookup"))     == "string" and Actions.get_label("lookup")     ~= "")
	end)

	helpers.it("returns the 'none' label for nil and 'none'", function()
		local none_label = Actions.get_label("none")
		helpers.assert_true(type(none_label) == "string" and none_label ~= "")
		helpers.assert_eq(Actions.get_label(nil), none_label)
	end)

	helpers.it("falls back to the id when unknown", function()
		helpers.assert_eq(Actions.get_label("totally_not_a_real_id"), "totally_not_a_real_id")
	end)
end)




-- =================================
-- =================================
-- ======= 5/ is_scalable() ========
-- =================================
-- =================================

helpers.describe("gestures.actions: is_scalable", function()
	helpers.it("flags volume / brightness / words / lines / paragraphs as scalable", function()
		helpers.assert_eq(Actions.is_scalable("volume"),     true)
		helpers.assert_eq(Actions.is_scalable("brightness"), true)
		helpers.assert_eq(Actions.is_scalable("words"),      true)
		helpers.assert_eq(Actions.is_scalable("lines"),      true)
		helpers.assert_eq(Actions.is_scalable("paragraphs"), true)
	end)

	helpers.it("does NOT flag tracks / spaces / document / line_bounds as scalable", function()
		-- These axes must trigger exactly once per crossing — scaling them would
		-- dispatch the wrapped keyStroke multiple times and cause runaway navigation.
		helpers.assert_true(not Actions.is_scalable("tracks"))
		helpers.assert_true(not Actions.is_scalable("spaces"))
		helpers.assert_true(not Actions.is_scalable("document"))
		helpers.assert_true(not Actions.is_scalable("line_bounds"))
	end)

	helpers.it("returns falsy for unknown ids", function()
		helpers.assert_true(not Actions.is_scalable("totally_not_real"))
		helpers.assert_true(not Actions.is_scalable("none"))
	end)
end)




-- =================================
-- =================================
-- ======= 6/ Execute Calls ========
-- =================================
-- =================================

helpers.describe("gestures.actions: execute helpers do not crash", function()
	helpers.it("execute_single is a no-op for unknown ids", function()
		-- Must not raise — bad gesture ids reach this code path on user misconfiguration.
		Actions.execute_single("totally_not_real")
	end)

	helpers.it("execute_axis is a no-op for unknown ids", function()
		Actions.execute_axis("totally_not_real", true)
		Actions.execute_axis("totally_not_real", false)
	end)

	helpers.it("execute_single('none') runs the empty action without error", function()
		Actions.execute_single("none")
	end)

	helpers.it("is_right_click_held returns a boolean", function()
		local v = Actions.is_right_click_held()
		helpers.assert_true(v == true or v == false)
	end)
end)
