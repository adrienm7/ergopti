--- tests/unit/diagnostics/engine/field_check/test_engine_icon.lua

--- ==============================================================================
--- MODULE: Field Check, Engine Icon Tests
--- DESCRIPTION:
--- The field run's `field_engine_icon` step decides the file half of TODO
--- « Engine dialog icon » from the running engine's Info.plist. These cases pin
--- the skip outside ErgoptiPlus.app, the pass on the plist the build writes,
--- and a failure by name for each way the hammer comes back: Hammerspoon's own
--- icon file, a CFBundleIconName left in place, a missing icns or an
--- unreadable plist.
--- ==============================================================================

local helpers = require("tests.helpers")
local Report = require("diagnostics.engine.field_check.report")
local Check = require("diagnostics.engine.field_check.engine_icon")
local Checks = require("diagnostics.engine.field_check.checks")

--- Runs the check over canned facts.
local function run(facts)
	local report, finished = Report.new_report("engine_icon"), 0
	local defaults = { embedded = true, readable = true, icon_file = "ErgoptiPlus", icns_present = true }
	for key, value in pairs(facts or {}) do defaults[key] = value end
	Check.engine_icon({ engine_icon_facts = function() return defaults end }, report,
		function() finished = finished + 1 end)
	helpers.assert_eq(finished, 1, "the check finishes exactly once")
	local steps = {}
	for _, step in ipairs(report.result().steps) do steps[step.id] = step end
	return steps
end





helpers.describe("field_engine_icon: the icon the embedded engine declares", function()
	helpers.it("is registered as a field check", function()
		helpers.assert_eq(Checks.checks.engine_icon, Check.engine_icon)
	end)

	helpers.it("skips by name outside ErgoptiPlus.app", function()
		local steps = run({ embedded = false })
		helpers.assert_eq(steps.engine_embedded.state, Report.STATE_SKIP)
		helpers.assert_eq(steps.engine_embedded.value, "not_embedded")
		helpers.assert_eq(steps.engine_icon_file, nil, "nothing else is read")
	end)

	helpers.it("passes on the plist the build writes", function()
		local steps = run({ icon_file = "ErgoptiPlus.icns" })
		helpers.assert_eq(steps.engine_icon_file.state, Report.STATE_PASS)
		helpers.assert_eq(steps.engine_icon_file.value, "ErgoptiPlus")
		helpers.assert_eq(steps.engine_icon_name.state, Report.STATE_PASS)
		helpers.assert_eq(steps.engine_icns.state, Report.STATE_PASS)
	end)

	helpers.it("fails by name on each way the hammer comes back", function()
		local steps = run({ icon_file = "AppIcon", icon_name = "AppIcon", icns_present = false })
		helpers.assert_eq(steps.engine_icon_file.state, Report.STATE_FAIL)
		helpers.assert_eq(steps.engine_icon_file.value, "AppIcon")
		helpers.assert_eq(steps.engine_icon_name.state, Report.STATE_FAIL)
		helpers.assert_eq(steps.engine_icon_name.value, "AppIcon")
		helpers.assert_eq(steps.engine_icns.value, "missing")
		steps = run({ readable = false })
		helpers.assert_eq(steps.engine_icon_file.state, Report.STATE_FAIL)
		helpers.assert_eq(steps.engine_icon_file.value, "info_plist_unreadable")
	end)
end)
