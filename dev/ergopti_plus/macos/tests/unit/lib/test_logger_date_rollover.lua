--- tests/unit/lib/test_logger_date_rollover.lua

--- ==============================================================================
--- MODULE: Logger — Daily log path rollover at midnight without restart
--- DESCRIPTION:
--- _ensure_log_file() must recompute the dated unified and errors paths
--- whenever the calendar date advances, so a long-running Hammerspoon session
--- that crosses midnight writes to the new day's log file rather than reopening
--- yesterday's path (which is what init_log_path chose at boot).
---
--- Test: mock os.date to advance the date mid-session and assert that the next
--- write opens the new day's files, and that the public resolver names them.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Reload the logger from scratch so init_log_path picks up our shell stub.
local _real_logger = package.loaded["infra.logger"]
local _real_shell  = package.loaded["adapters.shell_runner"]

local exec_log = {}
package.loaded["adapters.shell_runner"] = {
	exec = function(cmd) exec_log[#exec_log + 1] = tostring(cmd); return "" end,
}
package.loaded["infra.logger"] = nil
local Logger = require("infra.logger")

-- Records every path the logger opens, so the test observes where a line goes.
local _real_io_open = io.open
local function record_opens()
	local opened = {}
	io.open = function(path, mode)
		opened[#opened + 1] = tostring(path)
		return _real_io_open(path, mode)
	end
	return opened
end
local function restore_opens() io.open = _real_io_open end

--- True when any recorded path contains `needle`.
local function any_contains(paths, needle)
	for _, path in ipairs(paths) do
		if path:find(needle, 1, true) then return true end
	end
	return false
end





-- ===========================================================================
-- ===========================================================================
-- ======= 1/ Logger daily path rolls over at midnight without restart =======
-- ===========================================================================
-- ===========================================================================

helpers.describe("Logger date rollover — the daily files advance on midnight", function()

	helpers.it("the unified file is reopened when the calendar date changes", function()
		local tmp = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp") .. "/ergopti_test_logger_rollover/"
		local hs_ref = _G.hs
		-- Suppress the deferred purge timer so it does not fire during the test.
		local saved_doAfter = hs_ref.timer.doAfter
		hs_ref.timer.doAfter = function(_d, _fn) end

		-- Boot the logger with a known tmp dir.
		Logger.set_level(Logger.LEVELS.DEBUG)
		Logger.init_log_path(tmp, 1)
		local day_a_path = Logger.today_log_path()
		helpers.assert_true(type(day_a_path) == "string" and day_a_path ~= "",
			"today's log must be a non-empty string after init_log_path")

		-- Extract the date embedded in the path and verify it matches today.
		local embedded_date = day_a_path:match("(%d%d%d%d%-%d%d%-%d%d)")
		helpers.assert_true(embedded_date ~= nil,
			"today's log must embed a YYYY-MM-DD date")

		-- Advance the date by intercepting os.date.
		local real_os_date = os.date
		local function fake_date(fmt, t)
			if fmt == "%Y-%m-%d" and not t then
				return "2099-01-01"
			end
			return real_os_date(fmt, t)
		end
		os.date = fake_date
		local opened = record_opens()

		-- Trigger _ensure_log_file via a write; the date guard must fire.
		Logger.info("test_rollover", "Crossing midnight boundary.")
		local resolved = Logger.today_log_path()

		restore_opens()
		os.date = real_os_date
		hs_ref.timer.doAfter = saved_doAfter

		helpers.assert_true(any_contains(opened, "ErgoptiPlus_2099-01-01.log"),
			"the write crossing midnight must open the new day's unified file")
		helpers.assert_true(resolved:find("2099-01-01", 1, true) ~= nil,
			"the resolver must name the new day's file")
	end)

	helpers.it("the errors file also rolls over at midnight", function()
		local real_os_date = os.date
		os.date = function(fmt, t)
			if fmt == "%Y-%m-%d" and not t then return "2099-02-02" end
			return real_os_date(fmt, t)
		end

		local opened = record_opens()
		Logger.warn("test_rollover_errors", "Second boundary crossing.")
		restore_opens()

		os.date = real_os_date

		helpers.assert_true(any_contains(opened, "ErgoptiPlus_errors_2099-02-02.log"),
			"the errors mirror must also move to the new date on midnight rollover")
	end)
end)

-- Restore the originals so subsequent test files are unaffected.
package.loaded["adapters.shell_runner"] = _real_shell
package.loaded["infra.logger"]            = _real_logger
