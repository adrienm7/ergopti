--- static/ergopti_plus/linux/tests/unit/modules/diagnostics/test_crash_reporter.lua

--- ==============================================================================
--- MODULE: Crash Reporter Coverage (Linux driver)
--- DESCRIPTION:
--- Characterisation tests for modules/diagnostics/crash_reporter.lua, previously
--- an orphan module with zero coverage. Locks the public contract of M.protect,
--- M.dump, M.get_crash_dir and M.get_crash_count so a future regression in the
--- daemon's crash pipeline can never land silently.
---
--- FEATURES & RATIONALE:
--- 1. Call-time resolution: the crash folder is <logs>/crash_reports, resolved
---    per call from HOME, XDG_STATE_HOME and the LogsDirPath override, so the
---    suite redirects HOME via an os.getenv shim (Lua 5.4 has no os.setenv) and
---    an empty bootstrap store around every call, and asserts get_crash_dir()
---    reflects the sandbox path.
--- 2. Hermetic I/O: the module shells out with a Unix-only mkdir -p, which does
---    not exist under the Windows test host. The sandbox stubs os.execute, io.popen
---    and io.open so M.dump is exercised end to end — path construction and report
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

-- The crash directory the module must derive from TMP_HOME: the crash_reports
-- folder of the default logs folder, ~/.local/state/ergopti_plus/logs.
local EXPECTED_DIR = TMP_HOME .. "/.local/state/ergopti_plus/logs/crash_reports"





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

--- Runs `fn` while the logs folder resolves from the sandbox HOME: no
--- XDG_STATE_HOME and an empty bootstrap store, so no LogsDirPath is set.
--- @param fn function Body to run.
local function with_resolution(fn)
	local saved_getenv = os.getenv
	local saved_storage = package.loaded["adapters.storage"]
	os.getenv = function(name)
		if name == "HOME" then return TMP_HOME end
		if name == "XDG_STATE_HOME" then return nil end
		return REAL_GETENV(name)
	end
	package.loaded["adapters.storage"] = { get = function(_, fallback) return fallback end }
	local ok, err = pcall(fn)
	os.getenv = saved_getenv
	package.loaded["adapters.storage"] = saved_storage
	if not ok then error(err, 0) end
end

--- Runs `fn` with os.execute, io.popen and io.open stubbed so the module never
--- touches the real filesystem. Captures the single file path/mode/body that
--- M.dump writes, and optionally feeds a canned io.popen line for count parsing.
--- @param opts table|nil Options: { popen_read = string } to feed get_crash_count.
--- @param fn   function   Body to run inside the sandbox.
--- @return table Capture: { path, mode, content }.
local function with_sandbox(opts, fn)
	return require("tests.support.modules.diagnostics.crash_admission").with_admission(function()
		opts = opts or {}
		local real_open, real_exec, real_popen = io.open, os.execute, io.popen
		local cap = { path = nil, mode = nil, parts = {} }

		io.open = function(path, mode)
			-- Only the crash folder is virtual: the notice reads the locale catalogue.
			if path:sub(1, #EXPECTED_DIR) ~= EXPECTED_DIR then return real_open(path, mode) end
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

		local ok, err = pcall(with_resolution, fn)

		-- Restore globals unconditionally so a failing assertion cannot leak stubs.
		io.open, os.execute, io.popen = real_open, real_exec, real_popen
		if not ok then error(err, 0) end

		cap.content = table.concat(cap.parts, "")
		return cap
	end, { home = TMP_HOME, user = REAL_GETENV("USER") or REAL_GETENV("LOGNAME") or "fixtureuser" })
end





-- ============================================
-- ============================================
-- ======= 3/ Crash Reporter Test Suite =======
-- ============================================
-- ============================================

helpers.describe("linux: crash_reporter diagnostics", function()
	local cr = load_crash_reporter()

	helpers.it("resolves the crash folder inside the logs folder, from HOME", function()
		with_resolution(function()
			helpers.assert_eq(cr.get_crash_dir(), EXPECTED_DIR, "crash dir derived from HOME")
		end)
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
			cap.path:match("/%d%d%d%d%-%d%d%-%d%dT%d%d%-%d%d%-%d%dZ%.json$") ~= nil,
			"report filename is the shared <timestamp>.json")
	end)

	helpers.it("protect rejects a non-function payload", function()
		local ok, msg = cr.protect("engine", "not a function")
		helpers.assert_true(ok == false, "ok is false for a bad payload")
		helpers.assert_eq(msg, "fn is not a function", "explicit guard message returned")
	end)

	helpers.it("dump writes the shared JSON report with the expected fields", function()
		local cap = with_sandbox(nil, function()
			cr.dump("prediction_engine", "segfault", {
				stack_trace = "stack-frame-A",
				locale      = "fr",
			})
		end)
		helpers.assert_not_nil(cap.path, "dump opened a file")
		helpers.assert_eq(cap.mode, "w", "opened for writing")
		helpers.assert_true(cap.path:sub(1, #EXPECTED_DIR) == EXPECTED_DIR, "file under the crash dir")
		local report = require("json").decode(cap.content)
		helpers.assert_not_nil(report, "the file is a JSON document")
		helpers.assert_eq(report.driver, "linux")
		helpers.assert_eq(report.module, "prediction_engine", "module name in the report")
		helpers.assert_eq(report.error_msg, "segfault", "error message in the report")
		helpers.assert_eq(report.stack_trace, "stack-frame-A", "stack trace in the report")
		helpers.assert_eq(report.locale, "fr", "locale in the report")
		helpers.assert_true(report.timestamp:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") ~= nil, "UTC timestamp")
		helpers.assert_not_nil(report.version, "version field present without any context version")
		helpers.assert_not_nil(report.script_dir, "application directory field present")
		helpers.assert_not_nil(report.log_tail, "the log ring buffer field is present")
		-- Same keys, same order as every other driver's report.
		local last = 0
		for _, field in ipairs(require("crash_report").FIELDS) do
			local at = cap.content:find('"' .. field[1] .. '":', 1, true)
			helpers.assert_true(at ~= nil and at > last, "field " .. field[1] .. " is written in the shared order")
			last = at
		end
	end)

	helpers.it("a second report within the same second gets the numeric suffix", function()
		local FileSystem = require("adapters.file_system")
		local real_exists, probed = FileSystem.exists, {}
		FileSystem.exists = function(path)
			probed[#probed + 1] = path
			return path:match("%d%d%d%d%-%d%d%-%d%dT%d%d%-%d%d%-%d%dZ%.json$") ~= nil
		end
		local ok, err = pcall(function()
			local cap = with_sandbox(nil, function() cr.dump("engine", "again") end)
			helpers.assert_true(cap.path:match("%-2%.json$") ~= nil, "the colliding name is suffixed: " .. tostring(cap.path))
			local plain, suffixed = false, false
			for _, probe in ipairs(probed) do
				plain = plain or probe:match("Z%.json$") ~= nil
				suffixed = suffixed or probe:match("Z%-2%.json$") ~= nil
			end
			helpers.assert_true(plain and suffixed, "the plain name is probed, then the first suffix")
		end)
		FileSystem.exists = real_exists
		if not ok then error(err, 0) end
	end)

	helpers.it("tells the user where the report landed, and says so when it cannot be saved", function()
		local sent = {}
		local saved = { package.loaded["adapters.notifier"], package.loaded["infra.i18n"] }
		package.loaded["adapters.notifier"] = { send = function(text, opts) sent[#sent + 1] = { text = text, opts = opts }; return true end }
		package.loaded["infra.i18n"] = { get = function(key) return "T:" .. key end }
		local ok, err = pcall(function()
			local cap = with_sandbox(nil, function() cr.dump("engine", "notice me") end)
			helpers.assert_eq(sent[1].text, cap.path)
			helpers.assert_eq(sent[1].opts, { title = "T:crash.report.saved_title", level = "info" })
			local real_open = io.open
			local failed = with_sandbox(nil, function()
				io.open = function() return nil end
				cr.dump("engine", "cannot write")
			end)
			io.open = real_open
			helpers.assert_nil(failed.path)
			helpers.assert_eq(sent[2], { text = "T:crash.report.save_failed", opts = { level = "error" } })
		end)
		package.loaded["adapters.notifier"], package.loaded["infra.i18n"] = saved[1], saved[2]
		if not ok then error(err, 0) end
	end)

	helpers.it("keeps at most the shared cap of reports and never deletes another file", function()
		local CrashReport = require("crash_report")
		local listing, deleted = { { name = "notes.txt", kind = "file" }, { name = "sub", kind = "directory" } }, {}
		for index = 1, CrashReport.MAX_REPORTS + 2 do
			listing[#listing + 1] = { name = string.format("2026-10-24T10-00-%02dZ.json", index), kind = "file" }
		end
		local saved_directory, saved_delete = package.loaded["infra.native_directory"], require("adapters.file_system").delete
		package.loaded["infra.native_directory"] = { entries = function() return listing end }
		require("adapters.file_system").delete = function(path) deleted[#deleted + 1] = path; return true end
		local ok, err = pcall(function()
			with_sandbox(nil, function() cr.dump("engine", "rotate") end)
			helpers.assert_eq(#deleted, 2)
			helpers.assert_eq(deleted[1], EXPECTED_DIR .. "/2026-10-24T10-00-01Z.json")
			helpers.assert_eq(deleted[2], EXPECTED_DIR .. "/2026-10-24T10-00-02Z.json")
		end)
		package.loaded["infra.native_directory"], require("adapters.file_system").delete = saved_directory, saved_delete
		if not ok then error(err, 0) end
	end)

	helpers.it("dump ignores calls with a non-string or empty error", function()
		local cap = with_sandbox(nil, function()
			cr.dump("engine", nil)
			cr.dump("engine", "")
			cr.dump(nil, "boom")
		end)
		helpers.assert_nil(cap.path, "no file opened for invalid dump inputs")
	end)

	helpers.it("get_crash_count counts report names only", function()
		local saved = package.loaded["infra.native_directory"]
		package.loaded["infra.native_directory"] = { entries = function()
			return { { name = "2026-10-24T10-00-01Z.json", kind = "file" }, { name = "2026-10-24T10-00-01Z-2.json", kind = "file" },
				{ name = ".last_crash_notice", kind = "file" }, { name = "crash_old.txt", kind = "file" } }
		end }
		local ok, err = pcall(function()
			with_resolution(function() helpers.assert_eq(cr.get_crash_count(), 2) end)
		end)
		package.loaded["infra.native_directory"] = saved
		if not ok then error(err, 0) end
	end)

	-- The dumps of the pre-JSON reporter (crash_<stamp>_<module>.txt) are invisible
	-- to the retention and to the next-start dialog, so the startup removes them.
	helpers.it("removes exactly the legacy text dumps and nothing else (legacy-crash-cleanup)", function()
		local listing = {
			{ name = "crash_2026-09-01T10-00-00_ergopti_hotstrings.txt", kind = "file" },
			{ name = "crash_2026-09-02T11-30-05_engine.v2.txt", kind = "file" },
			{ name = "2026-10-24T10-00-01Z.json", kind = "file" },
			{ name = "2026-10-24T10-00-01Z-2.json", kind = "file" },
			{ name = ".last_crash_notice", kind = "file" },
			{ name = "crash_notes.txt", kind = "file" },
			{ name = "crash_2026-09-01T10-00-00_x.txt.bak", kind = "file" },
			{ name = "my_crash_2026-09-01T10-00-00_x.txt", kind = "file" },
			{ name = "crash_2026-09-01T10-00-00_dir.txt", kind = "directory" },
		}
		local deleted = {}
		local FileSystem = require("adapters.file_system")
		local saved_directory, saved_delete = package.loaded["infra.native_directory"], FileSystem.delete
		package.loaded["infra.native_directory"] = { entries = function() return listing end }
		FileSystem.delete = function(path) deleted[#deleted + 1] = path; return true end
		local ok, err = pcall(function()
			helpers.assert_eq(cr.remove_legacy_dumps("/crash"), 2)
			helpers.assert_eq(#deleted, 2)
			helpers.assert_eq(deleted[1], "/crash/crash_2026-09-01T10-00-00_ergopti_hotstrings.txt")
			helpers.assert_eq(deleted[2], "/crash/crash_2026-09-02T11-30-05_engine.v2.txt")
		end)
		package.loaded["infra.native_directory"], FileSystem.delete = saved_directory, saved_delete
		if not ok then error(err, 0) end
	end)

	helpers.it("a refused legacy delete is a warning, and a missing folder is not an error (legacy-crash-cleanup)", function()
		local FileSystem = require("adapters.file_system")
		local saved_directory, saved_delete = package.loaded["infra.native_directory"], FileSystem.delete
		local attempts = 0
		package.loaded["infra.native_directory"] = { entries = function()
			return { { name = "crash_2026-09-01T10-00-00_a.txt", kind = "file" },
				{ name = "crash_2026-09-01T10-00-01_b.txt", kind = "file" } }
		end }
		FileSystem.delete = function() attempts = attempts + 1; return attempts ~= 1 end
		local ok, err = pcall(function()
			helpers.assert_eq(cr.remove_legacy_dumps("/crash"), 1)
			helpers.assert_eq(attempts, 2, "a refusal must not stop the remaining deletions")
			package.loaded["infra.native_directory"] = { entries = function() return nil, "no such folder" end }
			helpers.assert_eq(cr.remove_legacy_dumps("/crash"), 0)
			package.loaded["infra.native_directory"] = { entries = function() error("listing raised") end }
			helpers.assert_eq(cr.remove_legacy_dumps("/crash"), 0)
		end)
		package.loaded["infra.native_directory"], FileSystem.delete = saved_directory, saved_delete
		if not ok then error(err, 0) end
	end)

	helpers.it("captures the stack where the error was RAISED", function()
		-- protect() used pcall and then took debug.traceback afterwards. By then
		-- the throwing stack has been unwound, so every crash report in the driver
		-- listed the same three frames — protect, its caller, and the entry point —
		-- whatever had actually failed. A report that cannot say where is a report
		-- that costs the reader the same hour every time.
		local Reporter = helpers.load_module("modules.diagnostics.crash_reporter")
		local captured = nil
		local real_dump = Reporter.dump
		Reporter.dump = function(_module, _err, ctx) captured = ctx and ctx.stack_trace end

		local function inner_frame_that_throws()
			error("boom from the inner frame")
		end
		Reporter.protect("probe", function() inner_frame_that_throws() end)

		Reporter.dump = real_dump
		helpers.assert_not_nil(captured, "a failure must produce a stack trace at all")
		helpers.assert_contains(captured, "inner_frame_that_throws",
			"the frame that raised must be IN the trace; a trace taken after the "
				.. "unwind names only the frames that survived it")
	end)

end)
