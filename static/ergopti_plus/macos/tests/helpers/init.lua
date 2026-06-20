--- tests/helpers/init.lua

--- ==============================================================================
--- MODULE: Test Helpers
--- DESCRIPTION:
--- Shared utilities for the test suite — module loading with a fresh `hs` stub,
--- fixture readers, lightweight assertions, and a minimal `describe/it` layer
--- usable when busted is unavailable.
---
--- FEATURES & RATIONALE:
--- 1. Per-test isolation: `load_with_stubs` resets `package.loaded` and the `hs`
---    global so every test starts from a clean slate.
--- 2. Zero-dependency runner: works under plain Lua 5.4 with no external libs;
---    falls through transparently to busted when present.
--- 3. Discoverable assertions: `assert_eq` and friends produce diff-style error
---    messages that point straight at the failing field.
--- ==============================================================================

local M = {}




-- ===================================
-- ===================================
-- ======= 1/ Path Resolution ========
-- ===================================
-- ===================================

--- Returns the absolute path of the Hammerspoon driver root.
--- The harness sets `package.path` to include the driver root before any
--- helper loads, so we recover it from that environment.
--- @return string Absolute path with trailing slash.
function M.driver_root()
	-- Resolve from the helper's own debug source path.
	local src = debug.getinfo(1, "S").source
	if src:sub(1, 1) == "@" then src = src:sub(2) end
	-- src is .../tests/helpers/init.lua — go two dirs up.
	local helper_dir = src:match("^(.*)[/\\]helpers[/\\]init%.lua$") or "./tests"
	return helper_dir:gsub("[/\\]tests$", "") .. "/"
end

--- Returns the path to the tests/fixtures directory.
--- @return string Absolute path with trailing slash.
function M.fixtures_dir()
	return M.driver_root() .. "tests/fixtures/"
end




-- =====================================
--- =====================================
-- ======= 2/ Module Stub Loader =======
--- =====================================
-- =====================================

--- Reloads a module after wiping the package cache and stubbing `hs`.
--- @param module_name string Dotted Lua module name to require.
--- @param hs_overrides table|nil Optional table merged onto the default `hs` stub.
--- @return any The module's return value.
function M.load_with_stubs(module_name, hs_overrides)
	-- Drop any previous instance so module-level state resets between tests.
	package.loaded[module_name] = nil
	package.loaded["hs"] = nil
	-- Force a fresh stub table each call so overrides from one test never leak
	-- into the next. Modules that override hs.execute or hs.timer with a partial
	-- table would otherwise corrupt the shared singleton for all later tests.
	package.loaded["tests.stubs.hs"] = nil

	-- Fresh hs stub for this test
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()

	if type(hs_overrides) == "table" then
		for k, v in pairs(hs_overrides) do hs_stub[k] = v end
	end

	_G.hs = hs_stub
	-- Anchor the stub under the bare "hs" key so that any subsequent
	-- `require("hs")` call in the harness or cascaded modules returns
	-- exactly this same stub — not a fresh reload. Without this, Lua
	-- re-executes tests/stubs/hs.lua and creates a second KEYSTROKES
	-- table; keyStroke/keyStrokes closures captured by utils and expander
	-- would then write to the first table while the harness reads from the
	-- second, making all keystroke assertions see 0 entries.
	package.loaded["hs"] = hs_stub

	-- Clear any partial or stubbed lib.text_utils installed by a previous test file
	-- (e.g. test_apply_prediction_arms_guard.lua installs a minimal stub that lacks
	-- utf8_len / repl_title). Without this, modules that capture text_utils at
	-- require-time get the stub instead of the full shared module, causing
	-- "attempt to call a nil value (field 'utf8_len')" crashes in subsequent tests.
	-- text_utils/init.lua is pure Lua with no hs deps, so reloading it is safe.
	package.loaded["lib.text_utils"] = nil

	-- Clear any toml_codec stub installed at module level by test files that
	-- treat it as a native C library (e.g. test_config.lua). The real codec is
	-- pure Lua and loads fine in CI; the stub's encode() returns "" which
	-- causes preferences.save() to write an empty TOML file and all persistence
	-- tests to see flat = {}.
	package.loaded["lib.toml_codec"]   = nil
	package.loaded["toml_codec"]       = nil
	package.loaded["toml_codec.codec"] = nil

	-- Always inject a minimal lib.i18n stub so that modules calling i18n.get()
	-- at require-time (terminators, conflicts, actions, profiles …) never crash
	-- with "attempt to call a nil value (field 'get')". The real lib.i18n depends
	-- on hs.settings and locale JSON files unavailable in headless unit tests.
	-- Tests that need a richer stub should override package.loaded["lib.i18n"]
	-- AFTER calling load_with_stubs (this baseline is always restored here).
	package.loaded["lib.i18n"] = {
		get        = function(key) return key end,
		get_locale = function() return "fr" end,
		set_locale = function() end,
	}

	-- Stub lib.paths so that any module (e.g. llm/api_remote, profiles resolution)
	-- can find shared/llm/api_providers.json and profiles.json during headless
	-- tests. Without this, io.open fails or returns nil path, causing "not found"
	-- errors in tests that load api_remote or exercise catalogue-dependent code.
	package.loaded["lib.paths"] = {
		-- Single shared-tree resolver: maps a path relative to shared/ onto the
		-- repo's shared/ directory next to the driver. Mirrors the production
		-- Paths.shared contract (nil/"" → the shared root dir).
		shared = function(rel)
			local root = M.driver_root() .. "../shared"
			if rel and rel ~= "" then
				return root .. "/" .. rel
			end
			return root
		end,
		shared_root = function()
			return M.driver_root() .. "../shared"
		end,
		shared_llm_path = function(name)
			return M.driver_root() .. "../shared/llm/" .. name
		end,
		find_from_configdir = function(relative_target)
			-- relative_target is usually "static/ergopti_plus/shared/locales"
			-- M.driver_root() is .../static/ergopti_plus/macos/
			-- We want to return .../relative_target
			return M.driver_root() .. "../../" .. relative_target
		end,
	}

	-- Minimal DEFAULT_STATE for modules.llm.init (lazy-required by
	-- profiles.resolve_system_prompt for {min_words}/{max_words} injection).
	-- Prevents "attempt to index a nil value" when Core.DEFAULT_STATE is accessed
	-- in test/CI envs.
	package.loaded["modules.llm.init"] = {
		DEFAULT_STATE = {
			llm_min_words = 4,
			llm_max_words = 20,
		},
	}

	-- Register sub-module aliases so that `require("hs.json")` etc. resolve to
	-- the same tables as `hs.json`. Some production modules call require("hs.*")
	-- directly rather than accessing the global `hs` table.
	local hs_sub_modules = {
		"json", "fs", "sqlite3", "timer", "http", "logger",
		"settings", "keycodes", "eventtap", "canvas", "styledtext",
		"notify", "dialog", "application", "window", "host",
		"pathwatcher", "urlevent", "pasteboard", "osascript",
		"spaces", "fnutils", "inspect", "task", "webview",
		"distributednotifications", "image", "menubar", "hotkey",
	}
	for _, sub in ipairs(hs_sub_modules) do
		if hs_stub[sub] ~= nil then
			package.loaded["hs." .. sub] = hs_stub[sub]
		end
	end

	return require(module_name)
end

--- Reads the contents of a fixture file relative to tests/fixtures/.
--- @param relative_path string Path under tests/fixtures.
--- @return string|nil File contents or nil if unreadable.
function M.read_fixture(relative_path)
	local path = M.fixtures_dir() .. relative_path
	local fh = io.open(path, "r")
	if not fh then return nil end
	local body = fh:read("*a")
	fh:close()
	return body
end




-- ==================================
-- ==================================
-- ======= 3/ Assertions ============
-- ==================================
-- ==================================

--- Compares two values for deep equality.
--- @param a any First value.
--- @param b any Second value.
--- @return boolean True if structurally equal.
function M.deep_equal(a, b)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for k, v in pairs(a) do if not M.deep_equal(v, b[k]) then return false end end
	for k, v in pairs(b) do if not M.deep_equal(v, a[k]) then return false end end
	return true
end

--- Asserts strict equality, printing a useful error on mismatch.
--- @param actual any Observed value.
--- @param expected any Expected value.
--- @param msg string|nil Optional context tag.
function M.assert_eq(actual, expected, msg)
	if not M.deep_equal(actual, expected) then
		error(string.format("%s: expected %s, got %s",
			tostring(msg or "assert_eq"), tostring(expected), tostring(actual)), 2)
	end
end

--- Asserts a boolean condition.
--- @param cond any Condition to test.
--- @param msg string|nil Optional context tag.
function M.assert_true(cond, msg)
	if not cond then error(tostring(msg or "expected truthy"), 2) end
end

--- Asserts a value is nil.
--- @param v any Value to test.
--- @param msg string|nil Optional context tag.
function M.assert_nil(v, msg)
	if v ~= nil then error(string.format("%s: expected nil, got %s", tostring(msg or "assert_nil"), tostring(v)), 2) end
end





-- =================================
--- ===================================
--- ======= 4/ Mini Test Runner =======
--- ===================================
-- =================================

local _suite_results = { passed = 0, failed = 0, failures = {} }
local _before_each_fn = nil

--- Declares a test suite (analogous to busted’s `describe`).
--- @param name string Suite name, printed in the output.
--- @param fn function Suite body that calls `it()`.
function M.describe(name, fn)
	print(string.format("\n=== %s ===", name))
	-- Save and reset before_each so nested describes don’t inherit the outer hook
	local prev_before_each = _before_each_fn
	_before_each_fn = nil
	local ok, err = pcall(fn)
	_before_each_fn = prev_before_each
	if not ok then
		print(string.format("  ! suite error: %s", tostring(err)))
		_suite_results.failed = _suite_results.failed + 1
	end
end

--- Registers a function to run before each subsequent `it()` in the current describe block.
--- @param fn function Setup function to run before each test.
function M.before_each(fn)
	_before_each_fn = fn
end

--- Declares a single test case (analogous to busted’s `it`).
--- @param name string Test name, printed in the output.
--- @param fn function Test body.
function M.it(name, fn)
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

--- Builds a minimal lib.logger stub suitable for injection via package.loaded.
--- All log methods are no-ops so modules can log without crashing in headless tests.
--- @return table Logger stub with the same public API as lib/logger.lua.
function M.make_logger_stub()
	local noop = function() end
	return {
		debug   = noop, trace   = noop, done    = noop,
		info    = noop, start   = noop, success = noop,
		warn    = noop, error   = noop,
		set_level = noop, set_sink = noop, is_enabled = function() return false end,
		ring_buffer_snapshot = function() return {} end,
		pcall   = function(_, fn, ...) return pcall(fn, ...) end,
		build   = function() return noop end,
		install_runtime_error_capture = noop,
		init_log_path = noop,
	}
end

--- Returns the global test result tally.
--- @return table {passed, failed, failures}
function M.get_results() return _suite_results end

--- Resets the cumulative result counters.
function M.reset_results()
	_suite_results.passed = 0
	_suite_results.failed = 0
	_suite_results.failures = {}
end

return M
