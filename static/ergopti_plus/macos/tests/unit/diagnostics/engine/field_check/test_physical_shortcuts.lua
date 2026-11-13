--- tests/unit/diagnostics/engine/field_check/test_physical_shortcuts.lua

--- ==============================================================================
--- MODULE: Field Check, Physical Shortcut Delivery Tests
--- DESCRIPTION:
--- The field run's `field_physical_shortcuts` step, and the guided press that
--- reads it before and after, decide TODO « Physical shortcut delivery » from
--- the physical hook's own counts. These cases pin the skips with delivery
--- unavailable, no slot bound or no press, the pass when every suppressed key
--- was delivered, a still-queued action named as pending, and the failure that
--- names an unacknowledged or dropped action.
--- ==============================================================================

local helpers = require("tests.helpers")
local Report = require("diagnostics.engine.field_check.report")
local Check = require("diagnostics.engine.field_check.physical_shortcuts")

--- Runs the check over canned facts.
local function run(facts)
	local report, finished = Report.new_report("physical_shortcuts"), 0
	local defaults = { available = true, bound = 1, suppressed = 0, delivered = 0, unacknowledged = 0, dropped = 0 }
	for key, value in pairs(facts or {}) do defaults[key] = value end
	Check.physical_shortcuts({ physical_shortcut_facts = function() return defaults end }, report,
		function() finished = finished + 1 end)
	helpers.assert_eq(finished, 1, "the check finishes exactly once")
	local steps = {}
	for _, step in ipairs(report.result().steps) do steps[step.id] = step end
	return steps, report.result()
end





helpers.describe("field_physical_shortcuts: the physical hook's own counts", function()
	helpers.it("skips by name with delivery unavailable, no slot bound or no press", function()
		local steps = run({ available = false, bound = 0 })
		helpers.assert_eq(steps.physical_delivery_available.state, Report.STATE_SKIP)
		helpers.assert_eq(steps.physical_delivery_available.value, "unavailable")
		helpers.assert_eq(steps.physical_slots_bound.value, "none_bound")
		helpers.assert_eq(steps.physical_delivery_balance.state, Report.STATE_SKIP)
		helpers.assert_eq(steps.physical_delivery_balance.value, "not_pressed")
	end)

	helpers.it("passes when every suppressed key reached its action", function()
		local steps, result = run({ suppressed = 2, delivered = 2 })
		helpers.assert_eq(steps.physical_delivery_available.state, Report.STATE_PASS)
		helpers.assert_eq(steps.physical_slots_bound.value, "1")
		helpers.assert_eq(steps.physical_suppressed.value, "2", "the guided press watches this count rise")
		helpers.assert_eq(steps.physical_delivered.value, "2")
		helpers.assert_eq(steps.physical_delivery_balance.state, Report.STATE_PASS)
		helpers.assert_true(result.passed)
	end)

	helpers.it("names an action still queued, and fails an unacknowledged or dropped one", function()
		helpers.assert_eq(run({ suppressed = 3, delivered = 2 }).physical_delivery_balance.value, "pending:1")
		local steps, result = run({ suppressed = 3, delivered = 1, unacknowledged = 1, dropped = 1 })
		helpers.assert_eq(steps.physical_delivery_balance.state, Report.STATE_FAIL)
		helpers.assert_eq(steps.physical_delivery_balance.value, "unacknowledged:1+dropped:1")
		helpers.assert_true(not result.passed)
	end)
end)
