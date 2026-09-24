--- tests/unit/lib/test_logger_logs_dir.lua

--- ==============================================================================
--- MODULE: Logger logs-folder resolver
--- DESCRIPTION:
--- The logger is the one resolver every consumer asks for the logs folder and
--- today's files: the Debug menu, the gesture actions, the health check, the
--- crash reporter and the LLM helpers.
---
--- ROOT CAUSE ENCODED (logs-dir-resolver):
--- Logger.UNIFIED_LOG_FILE and ERRORS_LOG_FILE were public fields set once,
--- when the folder was chosen at boot. Once the native worker owned the files
--- it rolled them by each record's date, but nothing refreshed those fields, so
--- every consumer that read them opened yesterday's file after midnight. The
--- fields are gone: a path fixed at boot cannot be read, and the resolver reads
--- the date on every call.
--- ==============================================================================

local helpers = require("tests.helpers")

local Fixture = require("tests.support.logger_async_sink_fixture")

local FOLDER = "/tmp/ergopti_logs_dir_resolver/ergopti_plus/"

--- Runs `callback` with os.date answering `day` for today's date.
--- @param day string "YYYY-MM-DD" returned for os.date("%Y-%m-%d").
--- @param callback function Assertions to run meanwhile.
local function on_day(day, callback)
	local real_date = os.date
	os.date = function(format, time)
		if format == "%Y-%m-%d" and time == nil then return day end
		return real_date(format, time)
	end
	local ok, err = pcall(callback)
	os.date = real_date
	if not ok then error(err, 0) end
end

helpers.describe("logger: logs-folder resolver", function()
	helpers.it("(logs-dir-resolver) resolves every artifact inside the folder it was given", function()
		Fixture.with_policy_logger(function(Logger)
			Logger.init_log_path(FOLDER, 14)
			local day = os.date("%Y-%m-%d")
			helpers.assert_eq(Logger.logs_dir(), FOLDER)
			helpers.assert_eq(Logger.today_log_path(), FOLDER .. "ErgoptiPlus_" .. day .. ".log")
			helpers.assert_eq(Logger.today_errors_path(), FOLDER .. "ErgoptiPlus_errors_" .. day .. ".log")
			helpers.assert_eq(Logger.crash_reports_dir(), FOLDER .. "crash_reports/")
		end)
	end)

	helpers.it("(logs-dir-resolver) adds the missing trailing separator", function()
		Fixture.with_policy_logger(function(Logger)
			Logger.init_log_path("/tmp/ergopti_logs_dir_resolver/ergopti_plus", 14)
			helpers.assert_eq(Logger.logs_dir(), FOLDER)
		end)
	end)

	helpers.it("(logs-dir-resolver) publishes no path fixed at boot", function()
		Fixture.with_policy_logger(function(Logger)
			Logger.init_log_path(FOLDER, 14)
			helpers.assert_nil(Logger.UNIFIED_LOG_FILE,
				"a public unified path set at boot goes stale at midnight")
			helpers.assert_nil(Logger.ERRORS_LOG_FILE,
				"a public errors path set at boot goes stale at midnight")
		end)
	end)

	helpers.it("(logs-dir-resolver) follows the date while the native worker owns the files", function()
		Fixture.with_fixture(function(fixture)
			local Logger = fixture.Logger
			local folder = "/tmp/ergopti_async_logger_handoff/"
			on_day("2099-01-02", function()
				helpers.assert_eq(Logger.today_log_path(), folder .. "ErgoptiPlus_2099-01-02.log")
				helpers.assert_eq(Logger.today_errors_path(), folder .. "ErgoptiPlus_errors_2099-01-02.log")
			end)
		end)
	end)

	helpers.it("(logs-dir-default) defaults to ~/Library/Logs/ergopti_plus", function()
		local LogFolders = require("infra.log_folders")
		helpers.assert_eq(LogFolders.default_logs_dir("/Users/someone"),
			"/Users/someone/Library/Logs/ergopti_plus/")
		helpers.assert_eq(LogFolders.default_logs_dir("/Users/someone/"),
			"/Users/someone/Library/Logs/ergopti_plus/")
		helpers.assert_nil(LogFolders.default_logs_dir(nil), "no home folder, no default")
		helpers.assert_nil(LogFolders.default_logs_dir(""), "no home folder, no default")
	end)

	helpers.it("(logs-dir-default) writes the early-boot fallback inside the default folder", function()
		Fixture.with_policy_logger(function(Logger)
			local home = os.getenv("HOME")
			if type(home) == "string" and home ~= "" then
				local expected = require("infra.log_folders").default_logs_dir(home)
				helpers.assert_eq(Logger.FALLBACK_LOG_DIR, expected)
				helpers.assert_eq(Logger.FALLBACK_BOOT_LOG_FILE, expected .. "ErgoptiPlus_boot.log")
			else
				helpers.assert_eq(Logger.FALLBACK_LOG_DIR, "/tmp/ergopti_plus/")
			end
			helpers.assert_nil(Logger.FALLBACK_BOOT_LOG_FILE:find("^/tmp/ErgoptiPlus"),
				"the shared /tmp root is readable by every account on the Mac")
		end)
	end)
end)
