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


-- ===================================
-- ===================================
-- ======= 1/ Value formatting =======
-- ===================================
-- ===================================

--- Pretty-prints any Lua value (string, number, boolean, nil, table, function)
--- into a single-line representation suitable for error messages. Tables are
--- expanded up to `max_depth` levels (default 3); beyond that, `{…}` is shown.
--- Cycles are detected and rendered as `[cyclic]`.
--- @param v      any    Value to format.
--- @param depth  number Internal recursion counter (omit on first call).
--- @param seen   table  Cycle-detection set (omit on first call).
--- @return string Single-line representation.
function M.inspect(v, depth, seen)
	depth = depth or 0
	if depth > 2 then return "{…}" end
	if type(v) == "string" then
		if #v > 120 then return string.format("%q", v:sub(1, 117) .. "...") end
		return string.format("%q", v)
	end
	if type(v) == "number" then return tostring(v) end
	if type(v) == "boolean" then return v and "true" or "false" end
	if v == nil then return "nil" end
	if type(v) == "function" then return "<function>" end
	if type(v) == "thread" then return "<thread>" end
	if type(v) == "userdata" then return "<userdata>" end
	if type(v) ~= "table" then return tostring(v) end

	seen = seen or {}
	if seen[v] then return "[cyclic]" end
	seen[v] = true

	local parts = {}
	local count = 0
	for k, val in pairs(v) do
		count = count + 1
		if count > 20 then parts[#parts + 1] = "…"; break end
		local key_fmt
		if type(k) == "string" and k:match("^[%a_][%w_]*$") then
			key_fmt = k
		else
			key_fmt = "[" .. M.inspect(k, depth + 1, seen) .. "]"
		end
		parts[#parts + 1] = key_fmt .. "=" .. M.inspect(val, depth + 1, seen)
	end
	seen[v] = nil
	return "{" .. table.concat(parts, " ") .. "}"
end


-- ===================================
-- ===================================
-- ======= 2/ Path Resolution ========
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
-- ======= 3/ Module Loader ============
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
-- ======= 4/ Assertions ============
-- ==================================
-- ==================================

--- Resolves the caller's file:line from the debug stack — the file and line
--- of the TEST function, not the assertion helper. Skips helpers.lua frames.
--- @param level number Starting stack level (default 2).
--- @return string file:line pair, or "" if unresolvable.
local function _caller_site(level)
	level = level or 2
	for lvl = level, level + 10 do
		local info = debug.getinfo(lvl, "Sl")
		if info and info.source then
			local src = info.source:gsub("^@", "")
			if not src:match("helpers%.lua$") then
				local fname = src:match("([^/\\]+)$") or src
				return fname .. ":" .. (info.currentline or "?")
			end
		end
	end
	return ""
end

--- Formats a failure message with the test's file:line prefix.
--- @param msg string Assertion message.
--- @return string Formatted message like "file:42: assertion reason".
local function _fail_msg(msg)
	local site = _caller_site(3)
	if site ~= "" then
		return site .. ": " .. msg
	end
	return msg
end

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

--- Asserts strict equality. Tables are pretty-printed in the error message
--- so you see WHICH field differs, not just `table: 0x...`.
--- @param actual   any        Observed value.
--- @param expected any        Expected value.
--- @param msg      string|nil Optional context tag.
function M.assert_eq(actual, expected, msg)
	if not M.deep_equal(actual, expected) then
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
-- =================================
-- ======= 5/ Mini Test Runner =====
-- =================================
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
	-- substring) so one behaviour can be re-run in isolation (REFACTOR_GUIDE P9.5).
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
