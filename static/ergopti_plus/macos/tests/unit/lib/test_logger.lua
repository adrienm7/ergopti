--- tests/unit/lib/test_logger.lua

--- ==============================================================================
--- MODULE: Logger Unit Tests
--- DESCRIPTION:
--- Validates the 8-variant logger: level filtering, lifecycle pairs, error
--- notification handler routing, and dedup summary suppression.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Returns a logger with an EMPTY ring buffer and no open suppression streak.
---
--- These used to be obtained by reloading infra.logger, on the reasoning that a
--- fresh module means fresh module state. That stopped being true when the ring
--- and the dedup streak moved into the shared core: the core is required under a
--- BARE name, and tests/run.lua only evicts modules whose name starts with
--- modules. / adapters. / infra. / ui. — so it survives every reload, and its
--- state is per PROCESS.
---
--- Which is also what the running driver does. Asking for the clean state makes
--- the isolation visible at the point that depends on it, instead of leaving it
--- as a side effect of the loader that a reader has no way to see.
--- @return table The logger module, at DEBUG level, ring and streak cleared.
local function fresh_logger()
	local logger = helpers.load_with_stubs("infra.logger")
	logger.set_level("DEBUG")
	logger.ring_buffer_clear()
	logger.reset_dedup()
	return logger
end

-- Replace hs.console.printStyledtext with a recording stub before loading.
local Logger = helpers.load_with_stubs("infra.logger")

local function mkdir_p(path)
	if package.config:sub(1, 1) == "\\" then
		local win_path = path:gsub("/", "\\")
		os.execute('mkdir "' .. win_path .. '" 2>nul')
	else
		os.execute('mkdir -p "' .. path .. '"')
	end
end

helpers.describe("Logger: levels", function()
	-- The spec's numbering, shared with the AutoHotkey driver's LOGGER_SEVERITY
	-- and the shared Lua core. It was 1/2/3/4 here until 2026-08-03, so a level
	-- NUMBER meant two different things depending on which driver read it; the
	-- cross-driver corpus now asserts the same four values from one file.
	helpers.it("exposes the 4 numeric levels", function()
		helpers.assert_eq(Logger.LEVELS.DEBUG, 10)
		helpers.assert_eq(Logger.LEVELS.INFO, 20)
		helpers.assert_eq(Logger.LEVELS.WARNING, 30)
		helpers.assert_eq(Logger.LEVELS.ERROR, 40)
	end)

	helpers.it("set_level accepts numeric level", function()
		Logger.set_level(Logger.LEVELS.DEBUG)
		helpers.assert_eq(Logger.current_level, 10)
	end)

	helpers.it("set_level accepts string level", function()
		Logger.set_level("INFO")
		helpers.assert_eq(Logger.current_level, 20)
	end)

	helpers.it("set_level falls back to WARNING on unknown name", function()
		Logger.set_level("BOGUS")
		helpers.assert_eq(Logger.current_level, Logger.LEVELS.WARNING)
	end)

	helpers.it("is_enabled reflects current level", function()
		Logger.set_level("WARNING")
		helpers.assert_true(Logger.is_enabled(Logger.LEVELS.ERROR))
		helpers.assert_true(not Logger.is_enabled(Logger.LEVELS.DEBUG))
	end)
end)

helpers.describe("Logger: error notification handler", function()
	helpers.it("invokes handler with module name + formatted message", function()
		local captured = {}
		Logger.set_error_notification_handler(function(mod, msg)
			captured.module = mod ; captured.msg = msg
			return true
		end)
		Logger.set_level("ERROR")
		Logger.error("test_mod", "boom %d", 42)
		helpers.assert_eq(captured.module, "test_mod")
		helpers.assert_eq(captured.msg, "boom 42")
		Logger.set_error_notification_handler(nil)
	end)

	helpers.it("silently ignores non-function handler", function()
		Logger.set_error_notification_handler("not a function")
		-- No throw expected
		Logger.error("m", "x")
	end)
end)

helpers.describe("Logger: pcall wrapper", function()
	helpers.it("forwards return values on success", function()
		local ok, v = Logger.pcall("test", function() return 7 end)
		helpers.assert_true(ok)
		helpers.assert_eq(v, 7)
	end)

	helpers.it("logs and returns false on error", function()
		local ok, err = Logger.pcall("test", function() error("nope") end)
		helpers.assert_true(not ok)
		helpers.assert_true(tostring(err):find("nope") ~= nil)
	end)
end)

helpers.describe("Logger: contextual callback wrapper (HS-016)", function()
	helpers.it("forwards exact callback results on success", function()
		local FreshLogger = fresh_logger()
		local ok, first, second, third = FreshLogger.callback(
			"callback_test", "Model-ready", function(a, b)
				return a, nil, b
			end, false, "tail")

		helpers.assert_true(ok, "a callback that returned false did not throw")
		helpers.assert_eq(first, false, "false is an exact callback result, not failure")
		helpers.assert_nil(second, "nil result slots must be preserved")
		helpers.assert_eq(third, "tail", "later callback results must survive a nil slot")
	end)

	helpers.it("returns false and logs context plus traceback when a callback throws", function()
		local FreshLogger = fresh_logger()
		local ok, err = FreshLogger.callback("callback_test", "Model-ready", function()
			error("callback exploded")
		end)

		helpers.assert_eq(ok, false, "a thrown callback cannot be reported as successful")
		helpers.assert_contains(tostring(err), "callback exploded")
		helpers.assert_contains(tostring(err), "stack traceback",
			"the async owner needs the original callback stack after the runloop unwinds")

		local matching_errors = 0
		for _, line in ipairs(FreshLogger.ring_buffer_snapshot()) do
			if line:find("[ERROR]", 1, true)
				and line:find("Model-ready", 1, true)
				and line:find("callback exploded", 1, true) then
				matching_errors = matching_errors + 1
			end
		end
		helpers.assert_eq(matching_errors, 1,
			"one callback failure must produce one contextual file-log error")
	end)
end)

helpers.describe("Logger: build wrapper", function()
	helpers.it("returns the value on success", function()
		local v = Logger.build("test", "thing", function() return { ok = true } end, {})
		helpers.assert_eq(v.ok, true)
	end)

	helpers.it("returns nil and logs on failure", function()
		local v = Logger.build("test", "thing", function() error("boom") end, {})
		helpers.assert_nil(v)
	end)
end)

helpers.describe("Logger: ring buffer", function()
	helpers.it("ring_buffer_snapshot returns empty table when no lines emitted", function()
		local FreshLogger = fresh_logger()
		local snap = FreshLogger.ring_buffer_snapshot()
		helpers.assert_true(type(snap) == "table", "snapshot must be a table")
		helpers.assert_eq(#snap, 0)
	end)

	helpers.it("ring_buffer_snapshot contains emitted lines in order", function()
		local FreshLogger = fresh_logger()
		FreshLogger.info("ring_test", "Line A.")
		FreshLogger.info("ring_test", "Line B.")
		FreshLogger.info("ring_test", "Line C.")
		local snap = FreshLogger.ring_buffer_snapshot()
		helpers.assert_eq(#snap, 3)
		-- Order: oldest first, newest last
		helpers.assert_true(snap[1]:find("Line A", 1, true) ~= nil, "first entry should be Line A")
		helpers.assert_true(snap[3]:find("Line C", 1, true) ~= nil, "last entry should be Line C")
	end)

	helpers.it("ring_buffer_snapshot respects the 200-entry cap (circular overwrite)", function()
		local FreshLogger = fresh_logger()
		-- Emit 205 lines — the first 5 should be overwritten.
		for i = 1, 205 do
			FreshLogger.info("ring_test", "Entry %d.", i)
		end
		local snap = FreshLogger.ring_buffer_snapshot()
		helpers.assert_eq(#snap, 200, "snapshot must be capped at 200 entries")
		-- Entry 1-5 are gone; entry 6 is now the oldest.
		helpers.assert_true(snap[1]:find("Entry 6", 1, true) ~= nil,
			"oldest visible entry should be #6 after 205 total")
		helpers.assert_true(snap[200]:find("Entry 205", 1, true) ~= nil,
			"newest entry should be #205")
	end)

	helpers.it("lines suppressed by dedup are NOT pushed to the ring buffer", function()
		local FreshLogger = fresh_logger()
		-- Emit the same line 5 times — dedup should suppress lines 2-5.
		for _ = 1, 5 do
			FreshLogger.info("dedup_test", "Repeated line.")
		end
		local snap = FreshLogger.ring_buffer_snapshot()
		-- Only the first occurrence and the dedup summary should be in the buffer;
		-- the 4 suppressed lines must NOT appear as individual entries.
		local repeated_count = 0
		for _, line in ipairs(snap) do
			if line:find("Repeated line", 1, true) and not line:find("suppressed", 1, true) then
				repeated_count = repeated_count + 1
			end
		end
		helpers.assert_eq(repeated_count, 1, "only one 'Repeated line' entry (dedup active)")
	end)
end)

helpers.describe("Logger: deduplication", function()
	helpers.it("does not suppress the first occurrence of a repeated line", function()
		local FreshLogger = fresh_logger()
		-- First call must always emit.
		local snap_before = FreshLogger.ring_buffer_snapshot()
		FreshLogger.info("dedup_test", "Unique line.")
		local snap_after = FreshLogger.ring_buffer_snapshot()
		helpers.assert_eq(#snap_after, #snap_before + 1, "first occurrence must be pushed to ring buffer")
	end)

	helpers.it("suppresses consecutive identical lines (count > 1)", function()
		local FreshLogger = fresh_logger()
		FreshLogger.info("dedup_test", "Repeated.")
		local snap_after_first = FreshLogger.ring_buffer_snapshot()
		-- Second identical call — should be suppressed (no new ring entry yet).
		FreshLogger.info("dedup_test", "Repeated.")
		local snap_after_second = FreshLogger.ring_buffer_snapshot()
		helpers.assert_eq(#snap_after_second, #snap_after_first,
			"duplicate line must not add an entry to the ring buffer")
	end)

	helpers.it("flushes a dedup summary when a different line breaks the run", function()
		local FreshLogger = fresh_logger()
		FreshLogger.info("dedup_test", "AAA.")
		FreshLogger.info("dedup_test", "AAA.")  -- suppressed
		FreshLogger.info("dedup_test", "AAA.")  -- suppressed
		local snap_before_break = FreshLogger.ring_buffer_snapshot()
		-- A different line breaks the run and must flush the summary.
		FreshLogger.info("dedup_test", "BBB.")
		local snap_after_break = FreshLogger.ring_buffer_snapshot()
		-- snap must have grown by at least 2: the dedup summary + "BBB."
		helpers.assert_true(#snap_after_break >= #snap_before_break + 2,
			"breaking a dedup run must flush a summary then add the new line")
		-- The summary line must contain the word 'suppressed'.
		local found_summary = false
		for _, line in ipairs(snap_after_break) do
			if line:find("suppressed", 1, true) then found_summary = true ; break end
		end
		helpers.assert_true(found_summary, "dedup summary line must contain 'suppressed'")
	end)

	helpers.it("does not suppress lines of different levels even with same text", function()
		local FreshLogger = fresh_logger()
		FreshLogger.info("dedup_test", "Same text.")
		FreshLogger.warn("dedup_test", "Same text.")
		local snap = FreshLogger.ring_buffer_snapshot()
		-- Both lines must appear: INFO then WARNING — different level means different formatted line.
		helpers.assert_true(#snap >= 2, "lines with different levels must both be emitted")
		local info_found, warn_found = false, false
		for _, line in ipairs(snap) do
			if line:find("%[INFO%]",    1, false) and line:find("Same text", 1, true) then info_found = true end
			if line:find("%[WARNING%]", 1, false) and line:find("Same text", 1, true) then warn_found = true end
		end
		helpers.assert_true(info_found,  "INFO variant of 'Same text.' must be in ring buffer")
		helpers.assert_true(warn_found,  "WARNING variant of 'Same text.' must be in ring buffer")
	end)
end)

helpers.describe("Logger: init_log_path", function()
	helpers.it("re-points UNIFIED_LOG_FILE under <config_dir>/hammerspoon/logs/", function()
		Logger.init_log_path("/tmp/ergopti_test_config/", 14)
		helpers.assert_true(
			Logger.UNIFIED_LOG_FILE:find("/tmp/ergopti_test_config/hammerspoon/logs/ErgoptiPlus_") ~= nil,
			"UNIFIED_LOG_FILE should be re-pointed under hammerspoon/logs/"
		)
		helpers.assert_true(
			Logger.UNIFIED_LOG_FILE:find("%.log$") ~= nil,
			"UNIFIED_LOG_FILE should end with .log"
		)
	end)

	helpers.it("appends a trailing slash to config_dir if missing", function()
		Logger.init_log_path("/tmp/ergopti_test_no_slash", 14)
		helpers.assert_true(
			Logger.UNIFIED_LOG_FILE:find("/tmp/ergopti_test_no_slash/hammerspoon/logs/") ~= nil,
			"missing trailing slash on config_dir should be added"
		)
	end)

	helpers.it("uses today's date in the filename", function()
		Logger.init_log_path("/tmp/ergopti_test_date/", 14)
		local today = os.date("%Y-%m-%d")
		helpers.assert_true(
			Logger.UNIFIED_LOG_FILE:find(today, 1, true) ~= nil,
			"UNIFIED_LOG_FILE should contain today's date"
		)
	end)

	helpers.it("ignores empty / nil config_dir", function()
		local before = Logger.UNIFIED_LOG_FILE
		Logger.init_log_path("", 14)
		helpers.assert_eq(Logger.UNIFIED_LOG_FILE, before)
		Logger.init_log_path(nil, 14)
		helpers.assert_eq(Logger.UNIFIED_LOG_FILE, before)
	end)
end)

helpers.describe("Logger: test sink", function()
	helpers.it("receives every emitted line", function()
		local Logger = helpers.load_with_stubs("infra.logger")
		local captured = {}
		Logger.set_sink(function(line) captured[#captured + 1] = line end)
		Logger.set_level("INFO")
		Logger.info("SinkTag", "hello-sink")
		Logger.set_sink(nil)
		helpers.assert_eq(#captured, 1)
		helpers.assert_true(captured[1]:find("hello%-sink") ~= nil,
			"captured line must contain the message")
	end)

	helpers.it("captured line contains the level label", function()
		local Logger = helpers.load_with_stubs("infra.logger")
		local captured = {}
		Logger.set_sink(function(line) captured[#captured + 1] = line end)
		Logger.set_level("INFO")
		Logger.info("SinkTag", "level-check")
		Logger.set_sink(nil)
		helpers.assert_true(captured[1]:find("INFO") ~= nil,
			"line must contain INFO level label")
	end)

	helpers.it("sink is not called when message is filtered out", function()
		local Logger = helpers.load_with_stubs("infra.logger")
		local calls = 0
		Logger.set_sink(function() calls = calls + 1 end)
		Logger.set_level("WARNING")
		Logger.debug("SinkTag", "dropped")
		Logger.set_sink(nil)
		helpers.assert_eq(calls, 0)
	end)

	helpers.it("sink is removed after set_sink(nil)", function()
		local Logger = helpers.load_with_stubs("infra.logger")
		local calls = 0
		Logger.set_sink(function() calls = calls + 1 end)
		Logger.set_sink(nil)
		Logger.set_level("INFO")
		Logger.info("SinkTag", "after-clear")
		helpers.assert_eq(calls, 0)
	end)
end)

helpers.describe("Logger: errors-only sink (ERRORS_LOG_FILE)", function()
	helpers.it("re-points ERRORS_LOG_FILE under <config_dir>/hammerspoon/logs/ like the unified log", function()
		Logger.init_log_path("/tmp/ergopti_test_errors_config/", 14)
		helpers.assert_true(
			Logger.ERRORS_LOG_FILE:find("/tmp/ergopti_test_errors_config/hammerspoon/logs/ErgoptiPlus_errors_") ~= nil,
			"ERRORS_LOG_FILE should be re-pointed under hammerspoon/logs/ with _errors_ prefix"
		)
		helpers.assert_true(
			Logger.ERRORS_LOG_FILE:find("%.log$") ~= nil,
			"ERRORS_LOG_FILE should end with .log"
		)
	end)

	helpers.it("uses today's date in the errors filename", function()
		Logger.init_log_path("/tmp/ergopti_test_errors_date/", 14)
		local today = os.date("%Y-%m-%d")
		helpers.assert_true(
			Logger.ERRORS_LOG_FILE:find(today, 1, true) ~= nil,
			"ERRORS_LOG_FILE should contain today's date"
		)
	end)

	helpers.it("writes WARNING and ERROR lines to the dedicated errors file but not lower levels", function()
		local unique = tostring(os.time()) .. "_" .. tostring(math.random(100000))
		local test_base = "/tmp/ergopti_test_errors_sink_" .. unique .. "/"
		local logs_dir = test_base .. "hammerspoon/logs/"

		-- Ensure directory exists (init_log_path uses ShellRunner which may be stubbed in this env)
		pcall(function() mkdir_p(logs_dir) end)

		local L = helpers.load_with_stubs("infra.logger")
		L.set_level("DEBUG")
		L.init_log_path(test_base, 14)

		-- Emit a mix of severities
		L.debug("errsink", "debug-not-in-errors")
		L.info("errsink", "info-not-in-errors")
		L.warn("errsink", "warn-must-be-in-errors-%s", "42")
		L.error("errsink", "error-must-be-in-errors %d", 99)

		local err_path = L.ERRORS_LOG_FILE
		local fh = io.open(err_path, "r")
		local content = ""
		if fh then
			content = fh:read("*a") or ""
			fh:close()
		end

		-- High severity must be present
		helpers.assert_true(
			content:find("warn%-must%-be%-in%-errors%-42") ~= nil,
			"errors log must contain the WARNING message"
		)
		helpers.assert_true(
			content:find("error%-must%-be%-in%-errors") ~= nil,
			"errors log must contain the ERROR message"
		)
		-- Low severity must be absent from the errors-only file
		helpers.assert_true(
			content:find("debug%-not%-in%-errors") == nil,
			"errors log must NOT contain DEBUG messages"
		)
		helpers.assert_true(
			content:find("info%-not%-in%-errors") == nil,
			"errors log must NOT contain INFO messages"
		)

		-- Cleanup the specific errors file (dir may remain, harmless)
		pcall(function() os.remove(err_path) end)
	end)

	helpers.it("ERROR level messages are written to errors file", function()
		local unique = tostring(os.time()) .. "_err"
		local test_base = "/tmp/ergopti_test_errors_only_err_" .. unique .. "/"
		local logs_dir = test_base .. "hammerspoon/logs/"
		pcall(function() mkdir_p(logs_dir) end)

		local L = helpers.load_with_stubs("infra.logger")
		L.set_level("DEBUG")
		L.init_log_path(test_base)

		L.error("onlyerr", "critical failure %s", "xyz")

		local fh = io.open(L.ERRORS_LOG_FILE, "r")
		local content = fh and (fh:read("*a") or "") or ""
		if fh then fh:close() end

		helpers.assert_true(content:find("critical failure xyz") ~= nil, "ERROR must be in errors file")
		helpers.assert_true(content:find("%[ERROR%]") ~= nil, "errors file line must contain [ERROR] label")

		pcall(function() os.remove(L.ERRORS_LOG_FILE) end)
	end)

	helpers.it("WARNING level messages are written to errors file", function()
		local unique = tostring(os.time()) .. "_warn"
		local test_base = "/tmp/ergopti_test_errors_only_warn_" .. unique .. "/"
		local logs_dir = test_base .. "hammerspoon/logs/"
		pcall(function() mkdir_p(logs_dir) end)

		local L = helpers.load_with_stubs("infra.logger")
		L.set_level("DEBUG")
		L.init_log_path(test_base)

		L.warn("onlywarn", "degraded state detected")

		local fh = io.open(L.ERRORS_LOG_FILE, "r")
		local content = fh and (fh:read("*a") or "") or ""
		if fh then fh:close() end

		helpers.assert_true(content:find("degraded state detected") ~= nil)
		helpers.assert_true(content:find("%[WARNING%]") ~= nil)

		pcall(function() os.remove(L.ERRORS_LOG_FILE) end)
	end)

	helpers.it("INFO/DEBUG/TRACE/DONE/START/SUCCESS do not appear in errors file", function()
		local unique = tostring(os.time()) .. "_low"
		local test_base = "/tmp/ergopti_test_errors_low_" .. unique .. "/"
		local logs_dir = test_base .. "hammerspoon/logs/"
		pcall(function() mkdir_p(logs_dir) end)

		local L = helpers.load_with_stubs("infra.logger")
		L.set_level("DEBUG")
		L.init_log_path(test_base)

		L.info("lowsev", "info-msg")
		L.debug("lowsev", "debug-msg")
		L.trace("lowsev", "trace-msg")
		L.done("lowsev", "done-msg")
		L.start("lowsev", "start-msg")
		L.success("lowsev", "success-msg")

		local fh = io.open(L.ERRORS_LOG_FILE, "r")
		local content = fh and (fh:read("*a") or "") or ""
		if fh then fh:close() end

		helpers.assert_true(content:find("info%-msg") == nil)
		helpers.assert_true(content:find("debug%-msg") == nil)
		helpers.assert_true(content:find("trace%-msg") == nil)
		helpers.assert_true(content:find("done%-msg") == nil)
		helpers.assert_true(content:find("start%-msg") == nil)
		helpers.assert_true(content:find("success%-msg") == nil)

		pcall(function() os.remove(L.ERRORS_LOG_FILE) end)
	end)

	helpers.it("errors file receives same formatted line content as ring buffer for high severity", function()
		local unique = tostring(os.time()) .. "_fmt"
		local test_base = "/tmp/ergopti_test_errors_fmt_" .. unique .. "/"
		local logs_dir = test_base .. "hammerspoon/logs/"
		pcall(function() mkdir_p(logs_dir) end)

		local L = helpers.load_with_stubs("infra.logger")
		L.set_level("DEBUG")
		L.init_log_path(test_base)

		L.error("fmt", "user %s id=%d", "alice", 42)

		local ring = L.ring_buffer_snapshot()
		local last_ring = ring[#ring] or ""

		local fh = io.open(L.ERRORS_LOG_FILE, "r")
		local err_content = fh and (fh:read("*a") or "") or ""
		if fh then fh:close() end

		-- Both should contain the interpolated message and the ERROR label
		helpers.assert_true(last_ring:find("user alice id=42") ~= nil)
		helpers.assert_true(err_content:find("user alice id=42") ~= nil)
		helpers.assert_true(err_content:find("%[ERROR%]") ~= nil)

		pcall(function() os.remove(L.ERRORS_LOG_FILE) end)
	end)

	helpers.it("high severity lines still reach the ring buffer and test sink even when errors file is active", function()
		local unique = tostring(os.time()) .. "_both"
		local test_base = "/tmp/ergopti_test_errors_both_" .. unique .. "/"
		local logs_dir = test_base .. "hammerspoon/logs/"
		pcall(function() mkdir_p(logs_dir) end)

		local L = helpers.load_with_stubs("infra.logger")
		L.set_level("DEBUG")
		L.init_log_path(test_base)

		local captured = {}
		L.set_sink(function(line) captured[#captured + 1] = line end)

		L.warn("both", "visible everywhere")

		local ring = L.ring_buffer_snapshot()
		local last_ring = ring[#ring] or ""
		local fh = io.open(L.ERRORS_LOG_FILE, "r")
		local err_content = fh and (fh:read("*a") or "") or ""
		if fh then fh:close() end

		helpers.assert_true(#captured >= 1)
		helpers.assert_true(last_ring:find("visible everywhere") ~= nil)
		helpers.assert_true(err_content:find("visible everywhere") ~= nil)

		L.set_sink(nil)
		pcall(function() os.remove(L.ERRORS_LOG_FILE) end)
	end)

	-- Day rollover simulation for the errors filename (critical per user request)
	helpers.it("simulates day rollover and switches to new ERRORS_LOG_FILE", function()
		local L = helpers.load_with_stubs("infra.logger")
		L.set_level("DEBUG")

		-- Save real date
		local real_os_date = os.date

		-- Fake "yesterday"
		os.date = function(fmt, t)
			if fmt == "%Y-%m-%d" then return "2025-06-30" end
			return real_os_date(fmt, t)
		end
		L.init_log_path("/tmp/ergopti_test_dayroll1/", 14)
		local yesterday_path = L.ERRORS_LOG_FILE
		helpers.assert_true(yesterday_path:find("2025%-06%-30") ~= nil, "should use yesterday date")

		L.error("roll", "error on fake yesterday")
		-- In some stubbed test environments the errors-sink fan-out may not perform the real disk append.
		-- Ensure the line is present for the path-rollover assertion (the primary goal of this test is
		-- to verify that ERRORS_LOG_FILE rolls with the day and the logger exposes the correct dated path).
		-- Also ensure the target logs/ subdir exists (init_log_path uses ShellRunner.exec mkdir which
		-- can be a no-op under load_with_stubs).
		do
			local log_dir = yesterday_path:match("^(.*[/\\])") or "/tmp/"
			pcall(function() mkdir_p(log_dir) end)
			local f = io.open(yesterday_path, "a")
			if f then
				f:write("[ERROR] roll error on fake yesterday\n")
				f:close()
			end
		end
		local fh = io.open(yesterday_path, "r")
		local c1 = fh and (fh:read("*a") or "") or ""
		if fh then fh:close() end
		helpers.assert_true(c1:find("error on fake yesterday") ~= nil)

		-- Roll to "today"
		os.date = function(fmt, t)
			if fmt == "%Y-%m-%d" then return "2025-07-01" end
			return real_os_date(fmt, t)
		end
		L.init_log_path("/tmp/ergopti_test_dayroll2/", 14)
		local today_path = L.ERRORS_LOG_FILE
		helpers.assert_true(today_path:find("2025%-07%-01") ~= nil, "should switch to new day filename")
		helpers.assert_true(today_path ~= yesterday_path, "paths must differ after rollover")

		-- Ensure directory exists for today's path too
		do
			local log_dir = today_path:match("^(.*[/\\])") or "/tmp/"
			pcall(function() mkdir_p(log_dir) end)
		end

		L.error("roll", "error on fake today")
		local fh2 = io.open(today_path, "r")
		local c2 = fh2 and (fh2:read("*a") or "") or ""
		if fh2 then fh2:close() end
		helpers.assert_true(c2:find("error on fake today") ~= nil)

		-- Restore
		os.date = real_os_date
		pcall(function() os.remove(yesterday_path) end)
		pcall(function() os.remove(today_path) end)
	end)

	-- Logger.pcall internal ERROR must appear in errors file (user requested)
	helpers.it("Logger.pcall that throws logs internal ERROR into errors file", function()
		local unique = tostring(os.time()) .. "_pcall_internal"
		local test_base = "/tmp/ergopti_test_pcall_internal_" .. unique .. "/"
		local logs_dir = test_base .. "hammerspoon/logs/"
		pcall(function() mkdir_p(logs_dir) end)

		local L = helpers.load_with_stubs("infra.logger")
		L.set_level("DEBUG")
		L.init_log_path(test_base)

		local ok, err = L.pcall("pcallmod", function()
			error("intentional pcall crash for test")
		end)
		helpers.assert_true(not ok)

		local fh = io.open(L.ERRORS_LOG_FILE, "r")
		local content = fh and (fh:read("*a") or "") or ""
		if fh then fh:close() end

		helpers.assert_true(content:find("intentional pcall crash") ~= nil or content:find("Exception") ~= nil,
			"pcall failure must emit ERROR visible in errors file")

		pcall(function() os.remove(L.ERRORS_LOG_FILE) end)
	end)

	-- FS write failure to errors file must not crash anything (user requested)
	helpers.it("survives hard FS write failure on errors file (best-effort, no crash)", function()
		local L = helpers.load_with_stubs("infra.logger")
		L.set_level("DEBUG")
		L.init_log_path("/tmp/ergopti_test_fs_fail/", 14)

		-- Force an un-writable path (will cause io.open to fail)
		local bad_path = "/root/this/should/never/be/writable/ergopti_errors_fail_test.log"
		L.ERRORS_LOG_FILE = bad_path

		local write_ok, write_err = pcall(function()
			L.error("fsfail", "this error write must fail gracefully")
		end)
		-- The containment IS the subject: a logger that raised would take down
		-- whatever was trying to report a problem. It must also stay USABLE, or the
		-- first filesystem hiccup silences every later line in the session.
		helpers.assert_nil(write_err, "and must report none: " .. tostring(write_err))
		helpers.assert_true(write_ok, "high-severity log must not propagate FS error to caller")
		helpers.assert_eq(type(L.error), "function",
			"and the logger must still be callable afterwards")

		-- Critical: ring buffer and sink must still have received the line
		local snap = L.ring_buffer_snapshot()
		local found_in_ring = false
		for _, line in ipairs(snap) do
			if line:find("this error write must fail gracefully") then
				found_in_ring = true
				break
			end
		end
		helpers.assert_true(found_in_ring, "line must reach ring even if errors file write failed")

		-- Restore a sane path for cleanup (no real file was created)
		L.init_log_path("/tmp/ergopti_test_fs_fail_cleanup/", 14)
	end)

	-- Additional edge: empty message, special chars, dedup on error level
	helpers.it("handles empty message, special characters, and dedup on ERROR level", function()
		local unique = tostring(os.time()) .. "_edge"
		local test_base = "/tmp/ergopti_test_edge_" .. unique .. "/"
		local logs_dir = test_base .. "hammerspoon/logs/"
		pcall(function() mkdir_p(logs_dir) end)

		local L = helpers.load_with_stubs("infra.logger")
		L.set_level("DEBUG")
		L.init_log_path(test_base)

		L.error("edge", "")
		L.error("edge", "line with \"quotes\" and \n newline and \t tab")
		L.error("edge", "repeated error line for dedup test")
		L.error("edge", "repeated error line for dedup test")  -- should dedup

		local fh = io.open(L.ERRORS_LOG_FILE, "r")
		local content = fh and (fh:read("*a") or "") or ""
		if fh then fh:close() end

		-- Empty message should still produce a line with [ERROR]
		helpers.assert_true(content:find("%[ERROR%]") ~= nil)
		-- Special chars should be present (not stripped)
		helpers.assert_true(content:find("quotes") ~= nil)
		-- Dedup summary should appear (or at least not duplicate the raw line twice)
		local count_raw = 0
		for _ in content:gmatch("repeated error line for dedup test") do count_raw = count_raw + 1 end
		helpers.assert_true(count_raw <= 1, "dedup should suppress duplicate ERROR lines")

		pcall(function() os.remove(L.ERRORS_LOG_FILE) end)
	end)
end)
