--- tests/unit/lib/test_perf.lua

--- ==============================================================================
--- MODULE: lib.perf contract
--- DESCRIPTION:
--- Asserts the profiling API the driver actually calls exists and behaves.
---
--- ROOT CAUSE ENCODED:
--- This file previously asserted nothing. A pcall-guarded load wrapped the WHOLE
--- file in a skip — so a module that stopped loading reported a passing test
--- named "module not loadable — skipping" — and the only other case walked five
--- optional names asserting each "if present", which passes when none is. Two
--- shapes of test that cannot fail, guarding the one subsystem whose job is to
--- tell us when something got slow.
--- ==============================================================================

local helpers = require("tests.helpers")

-- The surface keymap/init.lua and the Hammerspoon console actually call, read
-- from the module rather than invented. Named
-- here so a rename has to update this list deliberately rather than silently
-- reduce the test to nothing.
local REQUIRED_API = { "set_enabled", "is_enabled", "now", "sample", "report", "report_all", "reset" }

helpers.describe("lib.perf: the profiling API exists and is callable", function()

	helpers.it("loads under the test stubs", function()
		package.loaded["lib.perf"] = nil
		local perf = helpers.load_with_stubs("lib.perf")
		helpers.assert_type(perf, "table",
			"a module that stops loading must fail here, not report a passing skip")
	end)

	helpers.it("exposes every function the driver calls", function()
		package.loaded["lib.perf"] = nil
		local perf = helpers.load_with_stubs("lib.perf")
		for _, name in ipairs(REQUIRED_API) do
			helpers.assert_type(perf[name], "function",
				"lib.perf." .. name .. " is called by the driver; an 'if present' check would "
				.. "pass against a module that exports none of them")
		end
	end)

	helpers.it("the sample/report/reset lifecycle runs and the toggle is observable", function()
		package.loaded["lib.perf"] = nil
		local perf = helpers.load_with_stubs("lib.perf")
		local ok, err = pcall(function()
			perf.set_enabled(true)
			helpers.assert_true(perf.is_enabled(), "set_enabled(true) must be observable")
			local t0 = perf.now()
			perf.sample("unit_test_segment", t0)
			perf.report("unit_test_segment")
			perf.reset("unit_test_segment")
			perf.set_enabled(false)
			helpers.assert_true(not perf.is_enabled(), "set_enabled(false) must be observable")
		end)
		helpers.assert_true(ok, "the profiler lifecycle must not raise: " .. tostring(err))
	end)

end)
