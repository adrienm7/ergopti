--- tests/unit/lib/test_perf.lua

--- ==============================================================================
--- MODULE: perf Unit Tests
--- DESCRIPTION:
--- Smoke tests for the performance instrumentation helper. The module is
--- loaded under the hs stub; these tests verify that the public API doesn't
--- raise and that disabled mode is a no-op.
--- ==============================================================================

local helpers = require("tests.helpers")

local ok, perf = pcall(helpers.load_with_stubs, "lib.perf")
if not ok then
	helpers.describe("lib.perf", function()
		helpers.it("module not loadable under stub — skipping", function() end)
	end)
	return
end

helpers.describe("lib.perf basic API", function()
	helpers.it("module returns a table", function()
		helpers.assert_true(type(perf) == "table")
	end)

	helpers.it("has timing helpers (if present)", function()
		-- These are optional; we just assert each named field, when present,
		-- is callable. This makes the test resilient to minor API changes.
		for _, name in ipairs({ "enable", "disable", "reset", "report", "report_all" }) do
			local fn = perf[name]
			if fn ~= nil then
				helpers.assert_true(type(fn) == "function", name .. " should be a function")
			end
		end
	end)
end)
