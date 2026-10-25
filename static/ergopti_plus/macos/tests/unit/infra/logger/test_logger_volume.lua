--- tests/unit/infra/logger/test_logger_volume.lua

--- ==============================================================================
--- MODULE: Logger Volume Counters (macOS)
--- DESCRIPTION:
--- Replays the shared log-volume contract on the shared core this driver runs,
--- then proves the driver's own level filter feeds the dropped counter.
--- ==============================================================================

local helpers = require("tests.helpers")

require("test.logger_volume_contract")(helpers, helpers.shared(""))

local Logger = require("infra.logger")
helpers.admit_logger_privacy(Logger)

helpers.describe("macOS logger feeds the dropped counter from its own level filter", function()
	helpers.it("counts a line below M.current_level and an evidence record below INFO", function()
		local previous_level = Logger.current_level
		Logger.volume_interval()
		Logger.current_level = Logger.LEVELS.WARNING
		local ok, err = pcall(function()
			Logger.debug("volume_test", "filtered debug")
			Logger.info("volume_test", "filtered info")
			Logger.evidence("volume_test", "filtered evidence")
			local volume = Logger.volume_interval()
			helpers.assert_eq(volume.dropped, 3)
			helpers.assert_eq(volume.debug + volume.info, 0, "a dropped line is not a written line")
		end)
		Logger.current_level = previous_level
		if not ok then error(err, 0) end
	end)
end)
