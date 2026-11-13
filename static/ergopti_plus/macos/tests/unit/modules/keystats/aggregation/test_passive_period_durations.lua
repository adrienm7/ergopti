--- tests/unit/modules/keystats/aggregation/test_passive_period_durations.lua

--- ==============================================================================
--- MODULE: Regression — measured passive intervals reach the system KPIs
--- DESCRIPTION:
--- The caffeinate watcher measures each lock and sleep interval and persists it
--- as `passive_period{kind, duration_ms}` (LogManager.log_passive_period); its
--- `wake`/`unlock` edges carry no duration. The walker credited durations only on
--- those edges, so the dashboard showed a nonzero passive count beside zero sleep
--- and lock time (audit HS-005 / MM-002). A finished keep-awake session has the
--- same shape with kind "awake" and was never aggregated either (HS-006 / MM-003).
---
--- WHAT THIS PINS:
--- Each measured interval is credited once to its category, a legacy edge that
--- still carries a duration keeps counting, and an edge without one adds nothing.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["core.logger.engine.logger"] = nil
local _ = helpers.load_with_stubs("core.logger.engine.logger")
package.loaded["core.timing.engine.timings"] = {
	ms  = function(_section, _key) return 1000 end,
	sec = function(_section, _key) return 1.0  end,
}




-- =====================================
-- =====================================
-- ======= 1/ Harness ==================
-- =====================================
-- =====================================

--- Walks system entries through a fresh aggregator and returns the day's row.
--- @param entries table Entries in the shape the production producers append.
--- @return table row The accumulated agg_system_day row for 2026-11-04.
local function walk(entries)
	package.loaded["modules.keystats.sqlite_writer"] = { get_db = function() return nil end, init = function() end }
	package.loaded["modules.keystats.export"] = {
		get_native_app_category = function() return "Development" end,
		init = function() end,
	}
	-- The state singleton outlives a module reload; reset it so each scenario
	-- starts from an empty batch.
	local state = require("modules.keystats.aggregator.state")
	state.initialized, state.agg_batch, state.ngram_ctx, state.device_id = false, nil, nil, nil
	local aggregator = helpers.load_with_stubs("modules.keystats.aggregator")
	aggregator.init({ device_id = "passive-period-probe" })
	for index, entry in ipairs(entries) do
		entry.type = "system_event"
		entry.timestamp = entry.timestamp or string.format("2026-11-04 10:%02d:00.000", index)
		aggregator.walk_system_event(entry)
	end
	return state.agg_batch.system_day["2026-11-04"]
end




-- =====================================
-- =====================================
-- ======= 2/ Regression ===============
-- =====================================
-- =====================================

helpers.describe("keystats aggregator: measured passive intervals (HS-005)", function()
	helpers.it("credits a measured sleep and a measured lock to their KPIs", function()
		local row = walk({
			{ action = "sleep" },
			{ action = "wake" },
			{ action = "passive_period", kind = "sleep", duration_ms = 60000 },
			{ action = "lock" },
			{ action = "unlock" },
			{ action = "passive_period", kind = "lock", duration_ms = 30000 },
		})
		helpers.assert_eq(row.sleep_ms, 60000)
		helpers.assert_eq(row.locked_ms, 30000)
		helpers.assert_eq(row.passive_count, 2)
	end)

	helpers.it("still credits a legacy edge that carries its own duration", function()
		local row = walk({
			{ action = "wake", duration_ms = 1200 },
			{ action = "unlock", duration_ms = 3400 },
		})
		helpers.assert_eq(row.sleep_ms, 1200)
		helpers.assert_eq(row.locked_ms, 3400)
		helpers.assert_eq(row.passive_count, 0)
	end)
end)

helpers.describe("keystats aggregator: night wakes", function()
	helpers.it("counts a wake before the night's end and not a daytime one", function()
		local row = walk({
			{ action = "wake", timestamp = "2026-11-04 03:12:00.000" },
			{ action = "wake", timestamp = "2026-11-04 05:59:59.000" },
			{ action = "wake", timestamp = "2026-11-04 06:00:00.000" },
			{ action = "wake", timestamp = "2026-11-04 14:00:00.000" },
		})
		helpers.assert_eq(row.night_wake_count, 2,
			"the dashboard reads night_wake_count as the wakes between 0 h and 6 h")
	end)
end)

helpers.describe("keystats aggregator: keep-awake accounting (HS-006)", function()
	helpers.it("credits a finished keep-awake session once to awake_ms", function()
		-- The exact pair shortcuts/actions/system.lua appends on keep-awake stop.
		local row = walk({
			{ action = "passive_period", kind = "awake", duration_ms = 120000 },
			{ action = "awake_focus", app = "Editor", duration_ms = 120000 },
		})
		helpers.assert_eq(row.awake_ms, 120000,
			"the awake_focus companion must not count the interval a second time")
		helpers.assert_eq(row.sleep_ms, 0)
		helpers.assert_eq(row.locked_ms, 0)
	end)
end)

