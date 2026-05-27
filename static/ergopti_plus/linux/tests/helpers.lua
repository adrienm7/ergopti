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
---    messages that point straight at the failing value.
--- ==============================================================================

local M = {}


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
	local tests_dir = src:match("^(.*)[/\\]helpers%.lua$") or "."
	return (tests_dir:match("^(.*)[/\\]tests$") or tests_dir):gsub("\\", "/")
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

--- Compares two values for deep equality.
--- @param a any First value.
--- @param b any Second value.
--- @return boolean true if structurally equal.
function M.deep_equal(a, b)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for k, v in pairs(a) do if not M.deep_equal(v, b[k]) then return false end end
	for k, v in pairs(b) do if not M.deep_equal(v, a[k]) then return false end end
	return true
end

--- Asserts strict equality, printing a useful error on mismatch.
--- @param actual   any        Observed value.
--- @param expected any        Expected value.
--- @param msg      string|nil Optional context tag.
function M.assert_eq(actual, expected, msg)
	if not M.deep_equal(actual, expected) then
		error(string.format("%s: expected %s, got %s",
			tostring(msg or "assert_eq"), tostring(expected), tostring(actual)), 2)
	end
end

--- Asserts a boolean condition.
--- @param cond any        Condition to test (truthy = pass).
--- @param msg  string|nil Optional context message shown on failure.
function M.assert_true(cond, msg)
	if not cond then error(tostring(msg or "expected truthy"), 2) end
end

--- Asserts a value is nil.
--- @param v   any        Value to test.
--- @param msg string|nil Optional context tag.
function M.assert_nil(v, msg)
	if v ~= nil then
		error(string.format("%s: expected nil, got %s",
			tostring(msg or "assert_nil"), tostring(v)), 2)
	end
end


-- =================================
-- =================================
-- ======= 4/ Mini Test Runner =====
-- =================================
-- =================================

local _suite_results = { passed = 0, failed = 0, failures = {} }

--- Declares a test suite (analogous to busted's describe).
--- @param name string Suite name printed in the output.
--- @param fn   function Suite body that calls it().
function M.describe(name, fn)
	print(string.format("\n=== %s ===", name))
	local ok, err = pcall(fn)
	if not ok then
		print(string.format("  ! suite error: %s", tostring(err)))
		_suite_results.failed = _suite_results.failed + 1
	end
end

--- Declares a single test case (analogous to busted's it).
--- @param name string Test name printed in the output.
--- @param fn   function Test body.
function M.it(name, fn)
	local ok, err = pcall(fn)
	if ok then
		_suite_results.passed = _suite_results.passed + 1
		print("  ok   " .. name)
	else
		_suite_results.failed = _suite_results.failed + 1
		_suite_results.failures[#_suite_results.failures + 1] = { name = name, err = tostring(err) }
		print("  FAIL " .. name .. " — " .. tostring(err))
	end
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

return M
