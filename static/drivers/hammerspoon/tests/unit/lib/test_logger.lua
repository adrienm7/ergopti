--- tests/unit/lib/test_logger.lua

--- ==============================================================================
--- MODULE: Logger Unit Tests
--- DESCRIPTION:
--- Validates the 8-variant logger: level filtering, lifecycle pairs, error
--- notification handler routing, and dedup summary suppression.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Replace hs.console.printStyledtext with a recording stub before loading.
local Logger = helpers.load_with_stubs("lib.logger")

helpers.describe("Logger: levels", function()
	helpers.it("exposes the 4 numeric levels", function()
		helpers.assert_eq(Logger.LEVELS.DEBUG, 1)
		helpers.assert_eq(Logger.LEVELS.INFO, 2)
		helpers.assert_eq(Logger.LEVELS.WARNING, 3)
		helpers.assert_eq(Logger.LEVELS.ERROR, 4)
	end)

	helpers.it("set_level accepts numeric level", function()
		Logger.set_level(Logger.LEVELS.DEBUG)
		helpers.assert_eq(Logger.current_level, 1)
	end)

	helpers.it("set_level accepts string level", function()
		Logger.set_level("INFO")
		helpers.assert_eq(Logger.current_level, 2)
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
		-- Fresh logger state — reload to reset internal ring buffer.
		local FreshLogger = helpers.load_with_stubs("lib.logger")
		FreshLogger.set_level("DEBUG")
		local snap = FreshLogger.ring_buffer_snapshot()
		helpers.assert_true(type(snap) == "table", "snapshot must be a table")
		helpers.assert_eq(#snap, 0)
	end)

	helpers.it("ring_buffer_snapshot contains emitted lines in order", function()
		local FreshLogger = helpers.load_with_stubs("lib.logger")
		FreshLogger.set_level("DEBUG")
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
		local FreshLogger = helpers.load_with_stubs("lib.logger")
		FreshLogger.set_level("DEBUG")
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
		local FreshLogger = helpers.load_with_stubs("lib.logger")
		FreshLogger.set_level("DEBUG")
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
		local FreshLogger = helpers.load_with_stubs("lib.logger")
		FreshLogger.set_level("DEBUG")
		-- First call must always emit.
		local snap_before = FreshLogger.ring_buffer_snapshot()
		FreshLogger.info("dedup_test", "Unique line.")
		local snap_after = FreshLogger.ring_buffer_snapshot()
		helpers.assert_eq(#snap_after, #snap_before + 1, "first occurrence must be pushed to ring buffer")
	end)

	helpers.it("suppresses consecutive identical lines (count > 1)", function()
		local FreshLogger = helpers.load_with_stubs("lib.logger")
		FreshLogger.set_level("DEBUG")
		FreshLogger.info("dedup_test", "Repeated.")
		local snap_after_first = FreshLogger.ring_buffer_snapshot()
		-- Second identical call — should be suppressed (no new ring entry yet).
		FreshLogger.info("dedup_test", "Repeated.")
		local snap_after_second = FreshLogger.ring_buffer_snapshot()
		helpers.assert_eq(#snap_after_second, #snap_after_first,
			"duplicate line must not add an entry to the ring buffer")
	end)

	helpers.it("flushes a dedup summary when a different line breaks the run", function()
		local FreshLogger = helpers.load_with_stubs("lib.logger")
		FreshLogger.set_level("DEBUG")
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
		local FreshLogger = helpers.load_with_stubs("lib.logger")
		FreshLogger.set_level("DEBUG")
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
		local Logger = helpers.load_with_stubs("lib.logger")
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
		local Logger = helpers.load_with_stubs("lib.logger")
		local captured = {}
		Logger.set_sink(function(line) captured[#captured + 1] = line end)
		Logger.set_level("INFO")
		Logger.info("SinkTag", "level-check")
		Logger.set_sink(nil)
		helpers.assert_true(captured[1]:find("INFO") ~= nil,
			"line must contain INFO level label")
	end)

	helpers.it("sink is not called when message is filtered out", function()
		local Logger = helpers.load_with_stubs("lib.logger")
		local calls = 0
		Logger.set_sink(function() calls = calls + 1 end)
		Logger.set_level("WARNING")
		Logger.debug("SinkTag", "dropped")
		Logger.set_sink(nil)
		helpers.assert_eq(calls, 0)
	end)

	helpers.it("sink is removed after set_sink(nil)", function()
		local Logger = helpers.load_with_stubs("lib.logger")
		local calls = 0
		Logger.set_sink(function() calls = calls + 1 end)
		Logger.set_sink(nil)
		Logger.set_level("INFO")
		Logger.info("SinkTag", "after-clear")
		helpers.assert_eq(calls, 0)
	end)
end)
