--- tests/unit/lib/test_logger_today_paths.lua

--- ==============================================================================
--- MODULE: Logger today's log paths
--- DESCRIPTION:
--- The native worker rolls its files by each record's date. A fatal report
--- written after midnight must name the files that hold today's lines, so
--- today_log_path() and today_errors_path() read the date per call.
--- ==============================================================================

local helpers = require("tests.helpers")

local Fixture = require("tests.support.logger_async_sink_fixture")

helpers.describe("logger: today's log paths", function()
	helpers.it("(logger-today-paths) follow the calendar date past midnight", function()
		Fixture.with_policy_logger(function(Logger)
			-- Only the chosen folder matters here, not whether the stub can create it.
			Logger.init_log_path("/tmp/ergopti_today_paths/", 14)
			local folder = "/tmp/ergopti_today_paths/"
			local boot_day = os.date("%Y-%m-%d")
			helpers.assert_eq(Logger.today_log_path(), folder .. "ErgoptiPlus_" .. boot_day .. ".log")
			helpers.assert_eq(Logger.today_errors_path(),
				folder .. "ErgoptiPlus_errors_" .. boot_day .. ".log")

			local real_date = os.date
			os.date = function(format, time)
				if format == "%Y-%m-%d" and time == nil then return "2099-01-02" end
				return real_date(format, time)
			end
			local ok, err = pcall(function()
				helpers.assert_eq(Logger.today_log_path(), folder .. "ErgoptiPlus_2099-01-02.log")
				helpers.assert_eq(Logger.today_errors_path(), folder .. "ErgoptiPlus_errors_2099-01-02.log")
			end)
			os.date = real_date
			if not ok then error(err, 0) end
		end)
	end)
end)
