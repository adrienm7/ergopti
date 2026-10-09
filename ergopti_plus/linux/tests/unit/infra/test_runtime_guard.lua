--- tests/unit/infra/test_runtime_guard.lua

--- ==============================================================================
--- MODULE: Linux Runtime Failure Guard Regression
--- DESCRIPTION:
--- Proves optional-load diagnostics and the failure/cleanup transaction used by
--- daemon pumps. A swallowed callback exception must never look like progress.
--- ==============================================================================

local helpers = require("tests.helpers")
local Guard = helpers.load_module("infra.runtime_guard")

helpers.describe("runtime guard: optional capabilities", function()
	helpers.it("returns a real module table", function()
		helpers.assert_not_nil(Guard.optional_require("infra.monotonic"))
	end)

	helpers.it("returns nil for a missing or malformed module", function()
		helpers.assert_nil(Guard.optional_require("tests.__missing_optional_capability"))
		package.preload["tests.__malformed_optional_capability"] = function() return true end
		helpers.assert_nil(Guard.optional_require("tests.__malformed_optional_capability"))
		package.preload["tests.__malformed_optional_capability"] = nil
		package.loaded["tests.__malformed_optional_capability"] = nil
	end)
end)

helpers.describe("runtime guard: recurring callback failures", function()
	helpers.it("returns the successful callback result without cleanup", function()
		local cleaned = 0
		local ok, value = Guard.call("healthy pump", function() return 42 end,
			function() cleaned = cleaned + 1 end)
		helpers.assert_true(ok)
		helpers.assert_eq(value, 42)
		helpers.assert_eq(cleaned, 0)
	end)

	helpers.it("reports failure and invokes owner cleanup exactly once", function()
		local cleaned = 0
		local ok, err = Guard.call("broken pump", function() error("pump exploded") end,
			function() cleaned = cleaned + 1 end)
		helpers.assert_eq(ok, false)
		helpers.assert_contains(err, "pump exploded")
		helpers.assert_contains(err, "stack traceback")
		helpers.assert_eq(cleaned, 1)
	end)

	helpers.it("contains a cleanup exception without hiding the original failure", function()
		local ok, err = Guard.call("double failure", function() error("primary") end,
			function() error("cleanup") end)
		helpers.assert_eq(ok, false)
		helpers.assert_contains(err, "primary")
	end)
end)
