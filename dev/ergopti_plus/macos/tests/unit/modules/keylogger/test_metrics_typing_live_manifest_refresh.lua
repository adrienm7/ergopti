--- tests/unit/modules/keylogger/test_metrics_typing_live_manifest_refresh.lua

--- ============================================================================
--- MODULE: Regression — typing dashboard live manifest refresh
--- DESCRIPTION:
--- The typing dashboard's KPI cards read `metrics_manifest`, but its old live
--- path refreshed only range n-grams. After an ingest, tables could change while
--- MPM, hotstring, and IA totals stayed frozen until the window was reopened.
--- ============================================================================

local helpers = require("tests.helpers")

local source = assert(helpers.read_driver_source("M._pending_full_refresh"))

helpers.describe("metrics_typing: live manifest refresh", function()
	helpers.it("coalesces a full projection reload instead of sending range data alone", function()
		local push_pos = assert(source:find("function M.push_live_update", 1, true))
		local schedule_pos = assert(source:find("M._pending_full_refresh = true", push_pos, true))
		local reload_pos = assert(source:find("if M._wv then refresh_live_manifest() end", schedule_pos, true))
		helpers.assert_true(schedule_pos < reload_pos,
			"ingest updates must reload the manifest that drives the KPI cards")
		helpers.assert_true(source:find("push_live_update: pending notify set.", 1, true) == nil,
			"the obsolete ngram-only live-refresh path must not remain")
	end)
end)
