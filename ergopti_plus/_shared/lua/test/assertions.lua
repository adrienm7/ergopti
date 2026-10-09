--- _shared/lua/test/assertions.lua

--- ==============================================================================
--- MODULE: Shared Test Assertions
--- DESCRIPTION:
--- The seven assertion functions both Lua test harnesses use, in one place.
---
--- WHY THIS EXISTS:
--- macOS and Linux each carried their own copy. Compared body by body, SIX of
--- the seven were byte-identical once whitespace was normalised, and the
--- seventh — assert_throws — differed by a single COMMENT line. Two copies of
--- an assertion library is two places for a fix to land in one of, and the
--- assertions are what every other test's credibility rests on: an assert_eq
--- that stopped comparing properly on one driver would make that driver's whole
--- suite agree with itself about nothing.
---
--- WHY IT TAKES fail_msg AS AN ARGUMENT:
--- Each harness formats a failure so the reported line is the CALLER's, not the
--- helper's, and it does that by skipping stack frames matching a pattern for
--- its own filename — "helpers%.lua$" on Linux, "helpers[/\\]init%.lua$" on
--- macOS. That pattern is the one genuinely per-driver part, so it is injected
--- rather than guessed here. Everything else (inspect, deep_equal) already came
--- from test.format, which is why this module needs nothing else.
---
--- USAGE:
---   local fmt        = require("test.format")
---   local assertions = require("test.assertions").build("helpers%.lua$", fmt)
---   M.assert_eq = assertions.assert_eq   -- …and so on
--- ==============================================================================

local M = {}

--- Builds the assertion set for one harness.
--- @param fail_msg function Formats a failure message, skipping the harness's own frames.
--- @param fmt table The shared test.format module (inspect, deep_equal).
--- @return table The seven assertion functions.
function M.build(harness_pattern, fmt)
	if type(harness_pattern) ~= "string" or harness_pattern == "" then
		error("test.assertions.build(): harness_pattern must be a non-empty Lua pattern", 2)
	end
	if type(fmt) ~= "table" or type(fmt.inspect) ~= "function"
		or type(fmt.deep_equal) ~= "function" or type(fmt.fail_msg_for) ~= "function" then
		error("test.assertions.build(): fmt must be the test.format module", 2)
	end

	-- BOTH frames are skipped: the harness's own file and this one. Skipping only
	-- the harness made every failure report "assertions.lua:57" — the assertion
	-- library's line instead of the failing test's. That knowledge belongs here
	-- rather than in each harness, which is why the pattern is taken and the
	-- fail_msg built, not the other way round.
	local fail_msg = fmt.fail_msg_for({ harness_pattern, "assertions%.lua$" })

	local inspect = fmt.inspect
	local deep_equal = fmt.deep_equal
	local A = {}

	--- Asserts deep equality. Shows both sides on failure.
	--- @param actual any
	--- @param expected any
	--- @param msg string|nil Optional context shown on failure.
	function A.assert_eq(actual, expected, msg)
		if not deep_equal(actual, expected) then
			local label = msg or "assert_eq"
			error(fail_msg(string.format(
				"%s:\n  expected: %s\n    actual: %s",
				label, inspect(expected), inspect(actual))), 0)
		end
	end

	--- Asserts a truthy condition. Shows the actual value on failure.
	--- @param cond any
	--- @param msg string|nil
	function A.assert_true(cond, msg)
		if not cond then
			error(fail_msg(string.format("%s — actual: %s",
				tostring(msg or "expected truthy"), inspect(cond))), 0)
		end
	end

	--- Asserts a value is nil.
	--- @param value any
	--- @param msg string|nil
	function A.assert_nil(v, msg)
		if v ~= nil then
			error(fail_msg(string.format("%s: expected nil, got %s",
				tostring(msg or "assert_nil"), inspect(v))), 0)
		end
	end

	--- Asserts a value is not nil.
	--- @param value any
	--- @param msg string|nil
	function A.assert_not_nil(v, msg)
		if v == nil then
			error(fail_msg(tostring(msg or "expected non-nil")), 0)
		end
	end

	--- Asserts a value's type.
	--- @param value any
	--- @param expected_type string
	--- @param msg string|nil
	function A.assert_type(v, expected_type, msg)
		local actual_type = type(v)
		if actual_type ~= expected_type then
			error(fail_msg(string.format("%s: expected %s, got %s (%s)",
				tostring(msg or "assert_type"), expected_type, actual_type, inspect(v))), 0)
		end
	end

	--- Asserts a string contains a substring.
	--- @param haystack string
	--- @param needle string
	--- @param msg string|nil
	function A.assert_contains(haystack, needle, msg)
		if not haystack:find(needle, 1, true) then
			error(fail_msg(string.format("%s: %q not found in %s",
				tostring(msg or "assert_contains"), needle, inspect(haystack))), 0)
		end
	end

	--- Asserts the function raises, and returns the error so the caller can
	--- assert on the message too.
	--- @param fn function
	--- @param msg string|nil
	--- @return any The raised error.
	function A.assert_throws(fn, msg)
		local ok, err = pcall(fn)
		if ok then
			error(fail_msg(tostring(msg or "expected exception but none was thrown")), 0)
		end
		return err
	end

	return A
end

return M
