--- tests/meta/harness/test_runner_double_leak_guard.lua

--- ==============================================================================
--- MODULE: Runner Double Leak Guard
--- DESCRIPTION:
--- helpers.measure_module restores every product module a test module left
--- replaced by a test double, and fails that module by name. One fixture that
--- failed before its own restore otherwise left its doubles for every later
--- module: the document fixture's timings double failed about 1200 Linux tests.
--- These cases drive the detector directly, so they record no runner failure.
--- ==============================================================================

local helpers = require("tests.helpers")

--- @return table before Shallow copy of package.loaded.
local function snapshot()
	local before = {}
	for key, value in pairs(package.loaded) do before[key] = value end
	return before
end

helpers.describe("runner: test doubles never outlive their module", function()
	helpers.it("restores a replaced and a new double, and names both", function()
		local before = snapshot()
		local real_monotonic = package.loaded["infra.monotonic"]
		package.loaded["infra.monotonic"] = { now_ms = function() return 0 end }
		package.loaded["ergopti_probe.double"] = { call = function() return true end }
		local leaked = helpers.restore_leaked_doubles(before)
		helpers.assert_eq(table.concat(leaked, ","), "ergopti_probe.double,infra.monotonic")
		helpers.assert_true(rawequal(package.loaded["infra.monotonic"], real_monotonic),
			"the replaced product module is the original object again")
		helpers.assert_eq(package.loaded["ergopti_probe.double"], nil, "a new double is removed")
	end)

	helpers.it("keeps a real module a test reloaded and test-support modules", function()
		local before = snapshot()
		local previous_text = package.loaded["text_utils"]
		package.loaded["text_utils"] = nil
		local fresh = require("text_utils")
		package.loaded["tests.support.probe_only"] = { call = function() return true end }
		local leaked = helpers.restore_leaked_doubles(before)
		helpers.assert_eq(#leaked, 0, "only doubles of product modules are restored: "
			.. table.concat(leaked, ","))
		helpers.assert_true(rawequal(package.loaded["text_utils"], fresh), "a real reload stays")
		package.loaded["text_utils"] = previous_text
		package.loaded["tests.support.probe_only"] = nil
	end)
end)
