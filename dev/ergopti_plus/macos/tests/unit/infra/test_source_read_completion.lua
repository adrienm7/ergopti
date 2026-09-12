--- tests/unit/infra/test_source_read_completion.lua

--- ==============================================================================
--- MODULE: Complete Source Cache Regressions
--- DESCRIPTION:
--- Each enumerated source must open, read and close before a shared snapshot
--- can commit. A repaired retry must never reuse the failed partial snapshot.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.source_read_fixture")

helpers.describe("complete source cache publication", function()
	for _, mode in ipairs({ "open_refusal", "open_throw", "read_refusal", "read_throw", "close_refusal", "close_throw" }) do
		helpers.it("(source-read-completion) cache rejects " .. mode .. " and retries all sources", function()
			helpers.with_fresh_modules({ "tests.helpers" }, function()
				local subject = require("tests.helpers")
				Fixture.with_fault(subject.driver_root(), mode, function(state)
					local ok, reason = pcall(subject.read_driver_source)
					helpers.assert_eq(ok, false, "partial source evidence must never be published")
					helpers.assert_true(tostring(reason):find("controlled " .. mode, 1, true) ~= nil)
					local opened_second = mode ~= "open_refusal" and mode ~= "open_throw"
					helpers.assert_eq(state.closes, opened_second and 2 or 1, "attempt closure of every acquired handle")
					state.repaired = true
					helpers.assert_eq(subject.read_driver_source(), "first source\nsecond source")
					helpers.assert_eq(state.enumerations, 2, "failed snapshot must not enter the cache")
					helpers.assert_eq(state.opens[state.paths[1]], 2, "retry the complete snapshot, not only its failed tail")
					helpers.assert_eq(state.opens[state.paths[2]], 2)
				end)
			end)
		end)
	end

	helpers.it("(source-read-completion) preserves valid empty source files", function()
		helpers.with_fresh_modules({ "tests.helpers" }, function()
			local subject = require("tests.helpers")
			Fixture.with_fault(subject.driver_root(), "empty_success", function(state)
				helpers.assert_eq(subject.read_driver_source(), "first source\n")
				helpers.assert_eq(state.closes, 2)
				helpers.assert_eq(subject.read_driver_source(), "first source\n")
				helpers.assert_eq(state.enumerations, 1, "a fully read snapshot may be cached")
			end)
		end)
	end)
end)
