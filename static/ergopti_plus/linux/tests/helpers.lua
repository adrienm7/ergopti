--- static/ergopti_plus/linux/tests/helpers.lua

--- ==============================================================================
--- MODULE: Test Helpers (Linux driver)
--- DESCRIPTION:
--- Shared utilities for the Linux driver test suite — path resolution,
--- lightweight assertions, and a minimal describe/it layer usable under plain
--- LuaJIT with no external dependencies.
---
--- FEATURES & RATIONALE:
--- 1. Zero-dependency runner: works under LuaJIT 2.x with no external libs;
---    the describe/it API mirrors the Hammerspoon helpers so test files are
---    easy to port between drivers.
--- 2. Per-test isolation: load_module() wipes the package cache before
---    requiring so module-level state resets between test cases.
--- 3. Discoverable assertions: assert_eq and friends produce diff-style error
---    messages with pretty-printed values; table contents are shown inline,
---    not as opaque `table: 0x...` pointers.
--- 4. Each assertion captures the test's own file:line so a CI failure log
---    points straight at the failing line without grep.
--- ==============================================================================

local M = {}

-- Value formatting and stack-trace helpers shared with macOS (P0 SSoT).
local fmt = require("test.format")
M.inspect = fmt.inspect
M.deep_equal = fmt.deep_equal

-- fail_msg closure: skip this helpers file when resolving test file:line.
local _fail_msg = fmt.fail_msg_for("helpers%.lua$")


-- ===================================
-- ===================================
-- ======= 1/ Path Resolution ========
-- ===================================
-- ===================================

--- Returns the absolute path of the Linux driver root (no trailing slash).
--- @return string Absolute path.
function M.driver_root()
	local src = debug.getinfo(1, "S").source
	if src:sub(1, 1) == "@" then src = src:sub(2) end
	-- src is .../tests/helpers.lua — go one dir up.
	local tests_dir = src:match("^(.*)[/\\\\]helpers%.lua$") or "."
	return (tests_dir:match("^(.*)[/\\\\]tests$") or tests_dir):gsub("\\\\", "/")
end


-- =====================================
-- =====================================
-- ======= 2/ Module Loader ============
-- =====================================
-- =====================================

--- Loads a module after wiping the package cache so state resets between tests.
--- @param module_name string Dotted Lua module name to require.
--- @return any The module's return value.
function M.load_module(module_name)
	package.loaded[module_name] = nil
	return require(module_name)
end


-- ==================================
-- ==================================
-- ======= 3/ Assertions ============
-- ==================================
-- ==================================

--- Convenience aliases to the shared format module (P0 SSoT).
--- deep_equal is used by assert_eq and is also available to test files.
local deep_equal = fmt.deep_equal

--- Asserts strict equality. Tables are pretty-printed in the error message
--- so you see WHICH field differs, not just `table: 0x...`.
--- @param actual   any        Observed value.
--- @param expected any        Expected value.
--- @param msg      string|nil Optional context tag.
function M.assert_eq(actual, expected, msg)
	if not deep_equal(actual, expected) then
		local label = msg or "assert_eq"
		error(_fail_msg(string.format(
			"%s:\n  expected: %s\n    actual: %s",
			label, M.inspect(expected), M.inspect(actual))), 0)
	end
end

--- Asserts a boolean condition. Shows the actual value on failure.
--- @param cond any        Condition to test (truthy = pass).
--- @param msg  string|nil Optional context message shown on failure.
function M.assert_true(cond, msg)
	if not cond then
		error(_fail_msg(string.format("%s — actual: %s",
			tostring(msg or "expected truthy"), M.inspect(cond))), 0)
	end
end

--- Asserts a value is nil. Shows the actual value on failure.
--- @param v   any        Value to test.
--- @param msg string|nil Optional context tag.
function M.assert_nil(v, msg)
	if v ~= nil then
		error(_fail_msg(string.format("%s: expected nil, got %s",
			tostring(msg or "assert_nil"), M.inspect(v))), 0)
	end
end

--- Asserts a value is NOT nil.
--- @param v   any        Value to test.
--- @param msg string|nil Optional context tag.
function M.assert_not_nil(v, msg)
	if v == nil then
		error(_fail_msg(tostring(msg or "expected non-nil")), 0)
	end
end

--- Asserts `haystack` contains substring `needle`.
--- @param haystack string    String to search in.
--- @param needle   string    Substring to find.
--- @param msg      string|nil Optional context tag.
function M.assert_contains(haystack, needle, msg)
	if not haystack:find(needle, 1, true) then
		error(_fail_msg(string.format("%s: %q not found in %s",
			tostring(msg or "assert_contains"), needle, M.inspect(haystack))), 0)
	end
end

--- Asserts a function throws an error when called.
--- @param fn  function  0-arg callable expected to throw.
--- @param msg string|nil Optional context tag.
function M.assert_throws(fn, msg)
	local ok, err = pcall(fn)
	if ok then
		error(_fail_msg(tostring(msg or "expected exception but none was thrown")), 0)
	end
	-- Return the error so caller can assert on the message too
	return err
end

--- Asserts `v` has type `expected_type` (e.g. "string", "table", "function").
--- @param v             any    Value to check.
--- @param expected_type string Lua type name.
--- @param msg           string|nil Optional context tag.
function M.assert_type(v, expected_type, msg)
	local actual_type = type(v)
	if actual_type ~= expected_type then
		error(_fail_msg(string.format("%s: expected %s, got %s (%s)",
			tostring(msg or "assert_type"), expected_type, actual_type, M.inspect(v))), 0)
	end
end





-- =================================
-- ===================================
-- ======= 4/ Mini Test Runner =======
-- ===================================
-- =================================

local _suite_results = { passed = 0, failed = 0, failures = {} }
-- When set (via --only), M.it runs only tests whose name contains this substring.
local _only_filter = nil
-- Optional setup function run before each test in the current describe block.
local _before_each_fn = nil

--- Declares a test suite (analogous to busted's describe).
--- @param name string Suite name printed in the output.
--- @param fn   function Suite body that calls it().
function M.describe(name, fn)
	print(string.format("\n=== %s ===", name))
	local prev_before_each = _before_each_fn
	_before_each_fn = nil
	local ok, err = pcall(fn)
	_before_each_fn = prev_before_each
	if not ok then
		print(string.format("  ! suite error: %s", tostring(err)))
		_suite_results.failed = _suite_results.failed + 1
	end
end

--- Registers a function to run before each subsequent it() in the current
--- describe block. Reset when the describe exits.
--- @param fn function Setup function.
function M.before_each(fn)
	_before_each_fn = fn
end

--- Declares a single test case (analogous to busted's it).
--- @param name string Test name printed in the output.
--- @param fn   function Test body.
function M.it(name, fn)
	-- --only <substr>: run only tests whose name contains the filter (plain
	-- substring) so one behaviour can be re-run in isolation.
	if _only_filter and not string.find(name, _only_filter, 1, true) then return end
	local ok, err = pcall(function()
		if _before_each_fn then _before_each_fn() end
		fn()
	end)
	if ok then
		_suite_results.passed = _suite_results.passed + 1
		print("  ok   " .. name)
	else
		_suite_results.failed = _suite_results.failed + 1
		_suite_results.failures[#_suite_results.failures + 1] = { name = name, err = tostring(err) }
		print("  FAIL " .. name .. " — " .. tostring(err))
	end
end

--- Builds a minimal logger stub suitable for injection via package.loaded.
--- All log methods are no-ops so modules can log without crashing in headless tests.
--- @return table Logger stub.
function M.make_logger_stub()
	local noop = function() end
	return {
		debug   = noop, trace   = noop, done    = noop,
		info    = noop, start   = noop, success = noop,
		warn    = noop, error   = noop,
		set_level = noop, set_sink = noop,
		ring_buffer_snapshot = function() return {} end,
	}
end

--- Returns the global test result tally.
--- @return table { passed, failed, failures }
function M.get_results() return _suite_results end

--- Resets the cumulative result counters.
function M.reset_results()
	_suite_results.passed   = 0
	_suite_results.failed   = 0
	_suite_results.failures = {}
end

--- Restricts M.it execution to tests whose name contains `substr` (the --only filter).
--- @param substr string|nil Substring to match; nil clears the filter (run all).
function M.set_only_filter(substr) _only_filter = substr end

return M
