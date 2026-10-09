--- tests/unit/adapters/test_layout_cohort_fixture.lua

--- ==============================================================================
--- MODULE: Controlled Layout Receipts Remain Scoped
--- DESCRIPTION:
--- Checks the real planner's explicit table seam and the controlled Capture
--- acknowledgement protocol. These checks grant no native source capability.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.layout_cohort_fixture")

helpers.describe("controlled layout cohort fixture", function()
	helpers.it("keeps actual planner receipts distinct from native acknowledgement", function()
		local layout, scope = Fixture.layout(function() return 30 end)
		local rows, _, receipt = layout.plan("a")
		helpers.assert_eq(scope.kind, "controlled-layout-table")
		helpers.assert_eq(scope.native_reason, "no-native-source-acknowledgement")
		helpers.assert_eq(rows[1].keycode, 30)
		helpers.assert_true(layout.plan_current(receipt))
		helpers.assert_eq(layout.plan_current(nil), false)
		helpers.assert_eq(layout.plan_current({}), false)
		helpers.assert_nil(layout.plan_view({}))
	end)

	helpers.it("detaches actual plan data from the issuing table and offered rows", function()
		local layout = Fixture.layout(function() return 30 end)
		local offered, _, receipt = layout.plan("a")
		offered[1].keycode = 45
		offered[1].mods[1] = "Shift"
		local view = layout.plan_view(receipt)
		helpers.assert_eq(view[1].keycode, 30)
		helpers.assert_eq(view[1].mods, {})
		view[1].keycode = 46
		helpers.assert_eq(layout.plan_view(receipt)[1].keycode, 30)
	end)

	helpers.it("actual cohort replacement retires the exact old plan", function()
		local layout = Fixture.layout(function() return 30 end)
		local _, _, old = layout.plan("a")
		layout.refresh()
		helpers.assert_eq(layout.plan_current(old), false)
		helpers.assert_nil(layout.plan_view(old))
		local _, _, fresh = layout.plan("a")
		helpers.assert_true(layout.plan_current(fresh))
		helpers.assert_eq(layout.plan_current(old), false)
	end)

	helpers.it("another actual planner cannot adopt a prior issuer's receipt", function()
		local first = Fixture.layout(function() return 30 end)
		local second = Fixture.layout(function() return 30 end)
		local _, _, receipt = first.plan("a")
		helpers.assert_eq(second.plan_current(receipt), false)
		helpers.assert_nil(second.plan_view(receipt))
		helpers.assert_true(first.plan_current(receipt))
	end)

	helpers.it("an unallocated character never manufactures an offered plan", function()
		local layout = Fixture.layout(function() return nil end)
		helpers.assert_nil(layout.resolve("a"))
		local plan, blocker, receipt = layout.plan("a")
		helpers.assert_nil(plan)
		helpers.assert_eq(blocker, "a")
		helpers.assert_nil(receipt)
		helpers.assert_eq(layout.plan_current(receipt), false)
	end)
end)

helpers.describe("controlled Capture map acknowledgement", function()
	local function fixture()
		return Fixture.capture(function(text)
			if text == "map" then return { a = { keycode = 30, level = 1, mods = {} } } end
			return {}
		end)
	end

	helpers.it("refuses before the controlled map is acknowledged", function()
		local capture, scope = fixture()
		helpers.assert_eq(scope.kind, "controlled-capture-acknowledgement")
		helpers.assert_eq(scope.native_reason, "source-selection-protocol-only")
		helpers.assert_eq(capture.is_ready(), false)
		helpers.assert_nil(capture.inverse_table())
		helpers.assert_eq(capture.inverse_current({}), false)
		helpers.assert_eq(capture.load("invalid"), false)
		helpers.assert_nil(capture.inverse_table())
	end)

	helpers.it("acknowledges only its exact issued receipt and detached map", function()
		local capture = fixture()
		helpers.assert_true(capture.load("map"))
		local offered, _, receipt = capture.inverse_table()
		helpers.assert_true(capture.inverse_current(receipt))
		helpers.assert_eq(capture.inverse_current({}), false)
		offered.a.keycode = 45
		offered.a.mods[1] = "Shift"
		local next_map = capture.inverse_table()
		helpers.assert_eq(next_map.a.keycode, 30)
		helpers.assert_eq(next_map.a.mods, {})
	end)

	helpers.it("a same-byte map reload cannot revive its old acknowledgement", function()
		local capture = fixture()
		helpers.assert_true(capture.load("map"))
		local _, _, old = capture.inverse_table()
		helpers.assert_true(capture.load("map"))
		helpers.assert_eq(capture.inverse_current(old), false)
		local _, _, fresh = capture.inverse_table()
		helpers.assert_true(capture.inverse_current(fresh))
		helpers.assert_eq(capture.inverse_current(old), false)
	end)

	helpers.it("another controlled Capture issuer cannot adopt an old receipt", function()
		local first, second = fixture(), fixture()
		helpers.assert_true(first.load("map"))
		helpers.assert_true(second.load("map"))
		local _, _, receipt = first.inverse_table()
		helpers.assert_eq(second.inverse_current(receipt), false)
		helpers.assert_true(first.inverse_current(receipt))
	end)

	helpers.it("observed export substitution retires the old controlled acknowledgement", function()
		local capture = fixture()
		helpers.assert_true(capture.load("map"))
		local _, _, receipt = capture.inverse_table()
		local load = capture.load
		capture.load = function() return true end
		helpers.assert_eq(capture.inverse_current(receipt), false)
		helpers.assert_nil(capture.inverse_table())
		capture.load = load
		helpers.assert_eq(capture.inverse_current(receipt), false)
		local _, _, fresh = capture.inverse_table()
		helpers.assert_true(capture.inverse_current(fresh))
	end)
end)
