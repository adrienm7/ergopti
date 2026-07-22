--- tests/unit/modules/keylogger/test_metrics_apps_live_update.lua

--- ============================================================================
--- MODULE: Regression — app-time dashboard live refresh
--- DESCRIPTION:
--- The apps dashboard used a revision-keyed SQLite cache but never subscribed
--- to LogManager's completed-ingest signal. A window left open therefore kept
--- its opening snapshot while the typing dashboard refreshed correctly.
--- ============================================================================

local helpers = require("tests.helpers")

local source = assert(helpers.read_driver_source("M._ingest_listener_registered"))

helpers.describe("metrics_apps: live SQLite refresh", function()
	helpers.it("subscribes once to completed ingestion and refreshes the open window", function()
		local guard_pos = assert(source:find("if not M._ingest_listener_registered then", 1, true))
		local subscribe_pos = assert(source:find(".on_ingest_done(function()", guard_pos, true))
		local update_pos = assert(source:find("M.push_live_update()", subscribe_pos, true))
		helpers.assert_true(guard_pos < subscribe_pos and subscribe_pos < update_pos,
			"the apps dashboard must subscribe once and request a live refresh after each ingest")
	end)
end)
