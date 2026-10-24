--- tests/unit/modules/keystats/storage/test_reader_manifest_dashboard_keys.lua

--- ==============================================================================
--- MODULE: Regression — macOS manifest fields the shared dashboards read
--- DESCRIPTION:
--- The metrics pages are one shared web app; each driver's reader must land a
--- row under the exact keys that app reads, as the Windows and Linux readers
--- do. A row landed under another key reads as zero, which looks like an
--- unused feature rather than a defect (keystats SQL census, PAR-67).
---
--- FEATURES & RATIONALE:
--- 1. Key holds: `_shared/ui/metrics_apps/script.js` sums `kc_hold[kc].s` and
---    `.n` for the modifier hold mean; macOS projected `sum` and `count`.
--- 2. Focus latency: macOS writes focus_to_first_key_* into agg_app_day_ergo
---    and the page reads them, but only the Linux reader projected them.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads a fresh reader whose database answers one table with given rows.
--- @param table_name string Table whose SELECT returns `rows`.
--- @param rows table Rows the stubbed statement yields.
--- @return table reader
local function reader_answering(table_name, rows)
	package.loaded["infra.logger"] = {
		debug = function() end, trace = function() end, done = function() end,
		info = function() end, start = function() end, success = function() end,
		warn = function() end, error = function() end,
	}
	local sqlite = { OK = 0, open = function()
		return { exec = function() return 0 end, close = function() end,
			nrows = function(_, sql)
				local answer = sql:find("FROM " .. table_name .. "[^%w_]") and rows or {}
				local index = 0
				return function() index = index + 1; return answer[index] end
			end }
	end }
	return helpers.load_with_stubs("modules.keystats.sqlite_reader", { sqlite3 = sqlite })
end

helpers.describe("macOS manifest: fields under the dashboard's keys", function()
	helpers.it("projects key holds as { s, n, m, tap, hold } like Windows and Linux", function()
		local reader = reader_answering("agg_app_day_kc_hold", {
			{ date = "2026-10-01", app = "Code", keycode = 56, s = 13000, c = 60, mx = 1200, t = 48, h = 12 },
		})
		local manifest, complete = reader.read_manifest("/declared/db.sqlite", "2026-10-01", "2026-10-01")
		helpers.assert_true(complete)
		helpers.assert_eq(manifest["2026-10-01"].Code.kc_hold["56"],
			{ s = 13000, n = 60, m = 1200, tap = 48, hold = 12 })
	end)

	helpers.it("projects the focus-to-first-key latency it writes, like Linux", function()
		local reader = reader_answering("agg_app_day_ergo", {
			{ date = "2026-10-01", app = "Code", f_max = 7, h_max = 11, ar_count = 4,
				focus_sum = 4200, focus_count = 6 },
		})
		local manifest = reader.read_manifest("/declared/db.sqlite", "2026-10-01", "2026-10-01")
		local entry = manifest["2026-10-01"].Code
		helpers.assert_eq(entry.focus_to_first_key_sum_ms, 4200)
		helpers.assert_eq(entry.focus_to_first_key_count, 6)
		helpers.assert_eq(entry.same_finger_streak_max, 7)
	end)
end)
