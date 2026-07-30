--- tests/unit/lib/test_logger_date_rollover.lua

--- ==============================================================================
--- MODULE: Logger — Daily log path rollover at midnight without restart
--- DESCRIPTION:
--- _ensure_log_file() must recompute M.UNIFIED_LOG_FILE and M.ERRORS_LOG_FILE
--- whenever the calendar date advances, so a long-running Hammerspoon session
--- that crosses midnight writes to the new day's log file rather than reopening
--- yesterday's path (which is what init_log_path last set them to at boot).
---
--- Test: mock os.date to advance the date mid-session and assert that the next
--- write updates both path constants to reflect the new date.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Reload the logger from scratch so init_log_path picks up our shell stub.
local _real_logger = package.loaded["lib.logger"]
local _real_shell  = package.loaded["adapters.shell_runner"]

local exec_log = {}
package.loaded["adapters.shell_runner"] = {
	exec = function(cmd) exec_log[#exec_log + 1] = tostring(cmd); return "" end,
}
package.loaded["lib.logger"] = nil
local Logger = require("lib.logger")





-- ===========================================================================
-- ===========================================================================
-- ======= 1/ Logger daily path rolls over at midnight without restart =======
-- ===========================================================================
-- ===========================================================================

helpers.describe("Logger date rollover — M.UNIFIED_LOG_FILE advances on midnight", function()

	helpers.it("M.UNIFIED_LOG_FILE is updated when the calendar date changes", function()
		local tmp = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp") .. "/ergopti_test_logger_rollover/"
		local hs_ref = _G.hs
		-- Suppress the deferred purge timer so it does not fire during the test.
		local saved_doAfter = hs_ref.timer.doAfter
		hs_ref.timer.doAfter = function(_d, _fn) end

		-- Boot the logger with a known tmp dir.
		Logger.set_level(Logger.LEVELS.DEBUG)
		Logger.init_log_path(tmp, 1)
		local day_a_path = Logger.UNIFIED_LOG_FILE
		helpers.assert_true(type(day_a_path) == "string" and day_a_path ~= "",
			"UNIFIED_LOG_FILE must be a non-empty string after init_log_path")

		-- Extract the date embedded in the path and verify it matches today.
		local embedded_date = day_a_path:match("(%d%d%d%d%-%d%d%-%d%d)")
		helpers.assert_true(embedded_date ~= nil,
			"UNIFIED_LOG_FILE must embed a YYYY-MM-DD date")

		-- Advance the date by intercepting os.date.
		local real_os_date = os.date
		local function fake_date(fmt, t)
			if fmt == "%Y-%m-%d" and not t then
				return "2099-01-01"
			end
			return real_os_date(fmt, t)
		end
		os.date = fake_date

		-- Trigger _ensure_log_file via a write; the date guard must fire.
		Logger.info("test_rollover", "Crossing midnight boundary.")

		os.date = real_os_date
		hs_ref.timer.doAfter = saved_doAfter

		helpers.assert_true(Logger.UNIFIED_LOG_FILE:find("2099-01-01", 1, true) ~= nil,
			"M.UNIFIED_LOG_FILE must contain the new date after a write crossing midnight")
	end)

	helpers.it("M.ERRORS_LOG_FILE is also updated on date rollover", function()
		local real_os_date = os.date
		os.date = function(fmt, t)
			if fmt == "%Y-%m-%d" and not t then return "2099-02-02" end
			return real_os_date(fmt, t)
		end

		Logger.warn("test_rollover_errors", "Second boundary crossing.")

		os.date = real_os_date

		helpers.assert_true(Logger.ERRORS_LOG_FILE:find("2099-02-02", 1, true) ~= nil,
			"M.ERRORS_LOG_FILE must also update to the new date on midnight rollover")
	end)
end)

-- Restore the originals so subsequent test files are unaffected.
package.loaded["adapters.shell_runner"] = _real_shell
package.loaded["lib.logger"]            = _real_logger
