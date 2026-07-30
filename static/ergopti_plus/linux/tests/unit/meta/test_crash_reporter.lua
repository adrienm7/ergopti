--- static/ergopti_plus/linux/tests/unit/meta/test_crash_reporter.lua

--- ==============================================================================
--- MODULE: Crash Reporter Coverage (Linux driver)
--- DESCRIPTION:
--- Characterisation tests for modules/diagnostics/crash_reporter.lua, previously
--- an orphan module with zero coverage. Locks the public contract of M.protect,
--- M.dump, M.get_crash_dir and M.get_crash_count so a future regression in the
--- daemon's crash pipeline can never land silently.
---
--- FEATURES & RATIONALE:
--- 1. Require-time HOME binding: CRASH_DIR is computed from os.getenv("HOME") at
---    require time, so the suite redirects HOME via an os.getenv shim BEFORE the
---    module loads (Lua 5.4 has no os.setenv) and asserts get_crash_dir() reflects
---    the sandbox path.
--- 2. Hermetic I/O: the module shells out with Unix-only mkdir -p / ls, which do
---    not exist under the Windows test host. The sandbox stubs os.execute, io.popen
---    and io.open so M.dump is exercised end to end — path construction and dump
---    body — without touching the real filesystem, identically on every platform.
--- 3. Full pcall contract: protect is verified on the success, throw and bad-payload
---    paths, including that the throw path routes through dump (a crash file open).
--- ==============================================================================

local helpers = require("tests.helpers")





-- =======================================
-- =======================================
-- ======= 1/ Constants & Fixtures =======
-- =======================================
-- =======================================

-- Dotted module name of the unit under test; kept in one place so the require and
-- the package-cache reset below never drift apart.
local CR_MODULE = "modules.diagnostics.crash_reporter"

-- Real os.getenv captured once so the HOME shim can still delegate every other
-- variable to the genuine environment.
local REAL_GETENV = os.getenv

-- Sandbox HOME rooted under the OS temp dir. Never written to (I/O is stubbed) but
-- kept realistic so the derived CRASH_DIR assertion is meaningful. The name avoids
-- the substring "crash_" so the crash-filename assertions below cannot be satisfied
-- by the home path itself.
local TMP_HOME     = (REAL_GETENV("TEMP") or REAL_GETENV("TMP") or "/tmp")
	:gsub("\\", "/"):gsub("/$", "") .. "/ergopti_cr_sandbox_home"

-- The crash directory the module must derive from TMP_HOME at require time.
local EXPECTED_DIR = TMP_HOME .. "/.local/share/ergopti/crashes"





-- =======================================
-- =======================================
-- ======= 2/ Test Harness Helpers =======
-- =======================================
-- =======================================



-- ==============================
-- ===== 2.1) Module Loader =====
-- ==============================

--- Loads the crash reporter with HOME redirected to the sandbox and the logger
--- neutralised, so CRASH_DIR binds to EXPECTED_DIR without emitting log noise.
--- @return table The freshly required crash_reporter module.
local function load_crash_reporter()
	-- Neutralise the logger require so dump()'s error log stays silent in CI.
	local prev_shim = package.loaded["logger.shim"]
	package.loaded["logger.shim"] = helpers.make_logger_stub()

	-- Redirect HOME only; every other variable falls through to the real env.
	local saved_getenv = os.getenv
	os.getenv = function(name)
		if name == "HOME" then return TMP_HOME end
		return REAL_GETENV(name)
	end

	package.loaded[CR_MODULE] = nil
	local ok, mod = pcall(require, CR_MODULE)

	-- Always restore globals, even if the require itself raised.
	os.getenv = saved_getenv
	package.loaded["logger.shim"] = prev_shim

	if not ok then error(mod, 0) end
	return mod
end



-- ============================
-- ===== 2.2) I/O Sandbox =====
-- ============================

--- Runs `fn` with os.execute, io.popen and io.open stubbed so the module never
--- touches the real filesystem. Captures the single file path/mode/body that
--- M.dump writes, and optionally feeds a canned io.popen line for count parsing.
--- @param opts table|nil Options: { popen_read = string } to feed get_crash_count.
--- @param fn   function   Body to run inside the sandbox.
--- @return table Capture: { path, mode, content }.
local function with_sandbox(opts, fn)
	opts = opts or {}
	local real_open, real_exec, real_popen = io.open, os.execute, io.popen
	local cap = { path = nil, mode = nil, parts = {} }

	io.open = function(path, mode)
		cap.path, cap.mode = path, mode
		return {
			write = function(_, s) cap.parts[#cap.parts + 1] = s; return true end,
			close = function() return true end,
		}
	end
	-- mkdir -p is a no-op here; the sandbox owns the (virtual) directory already.
	os.execute = function() return true end
	io.popen = function()
		if not opts.popen_read then return nil end
		return {
			read  = function() return opts.popen_read end,
			lines = function() return function() return nil end end,
			close = function() return true end,
		}
	end

	local ok, err = pcall(fn)

	-- Restore globals unconditionally so a failing assertion cannot leak stubs.
	io.open, os.execute, io.popen = real_open, real_exec, real_popen
	if not ok then error(err, 0) end

	cap.content = table.concat(cap.parts, "")
	return cap
end





-- ============================================
-- ============================================
-- ======= 3/ Crash Reporter Test Suite =======
-- ============================================
-- ============================================

helpers.describe("linux: crash_reporter diagnostics", function()
	local cr = load_crash_reporter()

	helpers.it("binds CRASH_DIR to $HOME at require time", function()
		helpers.assert_eq(cr.get_crash_dir(), EXPECTED_DIR, "crash dir derived from HOME")
	end)

	helpers.it("protect returns the wrapped result on success", function()
		local ok, result = cr.protect("engine", function() return 42 end)
		helpers.assert_true(ok, "ok is true on success")
		helpers.assert_eq(result, 42, "wrapped return value forwarded")
	end)

	helpers.it("protect reports failure and routes the throw through dump", function()
		local cap = with_sandbox(nil, function()
			local ok, err = cr.protect("engine", function() error("kaboom") end)
			helpers.assert_true(ok == false, "ok is false on throw")
			helpers.assert_contains(tostring(err), "kaboom", "raised error forwarded")
		end)
		helpers.assert_not_nil(cap.path, "throw path opens a crash file via dump")
		helpers.assert_true(
			cap.path:match("/crash_[%d%-T]+_engine%.txt$") ~= nil,
			"dump filename is crash_<timestamp>_<module>.txt")
	end)

	helpers.it("protect rejects a non-function payload", function()
		local ok, msg = cr.protect("engine", "not a function")
		helpers.assert_true(ok == false, "ok is false for a bad payload")
		helpers.assert_eq(msg, "fn is not a function", "explicit guard message returned")
	end)

	helpers.it("dump writes a timestamped file with the expected fields", function()
		local cap = with_sandbox(nil, function()
			cr.dump("prediction_engine", "segfault", {
				stack_trace = "stack-frame-A",
				version     = "9.9.9",
				layout      = "ergopti",
				locale      = "fr",
			})
		end)
		helpers.assert_not_nil(cap.path, "dump opened a file")
		helpers.assert_eq(cap.mode, "w", "opened for writing")
		helpers.assert_true(cap.path:sub(1, #EXPECTED_DIR) == EXPECTED_DIR, "file under the crash dir")
		helpers.assert_true(
			cap.path:match("/crash_[%d%-T]+_prediction_engine%.txt$") ~= nil,
			"filename is crash_<timestamp>_<module>.txt")
		helpers.assert_contains(cap.content, "Ergopti Linux Crash Dump", "dump header present")
		helpers.assert_contains(cap.content, "prediction_engine", "module name in body")
		helpers.assert_contains(cap.content, "segfault", "error message in body")
		helpers.assert_contains(cap.content, "stack-frame-A", "stack trace in body")
		helpers.assert_contains(cap.content, "9.9.9", "version in body")
		helpers.assert_contains(cap.content, "ergopti", "layout in body")
	end)

	helpers.it("dump ignores calls with a non-string or empty error", function()
		local cap = with_sandbox(nil, function()
			cr.dump("engine", nil)
			cr.dump("engine", "")
			cr.dump(nil, "boom")
		end)
		helpers.assert_nil(cap.path, "no file opened for invalid dump inputs")
	end)

	helpers.it("get_crash_count parses the file tally", function()
		local cap = with_sandbox({ popen_read = "3" }, function()
			helpers.assert_eq(cr.get_crash_count(), 3, "count parsed from the shell tally")
		end)
		helpers.assert_nil(cap.path, "count reads no crash files")
	end)
end)
