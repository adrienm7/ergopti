--- tests/unit/modules/keystats/storage/test_reader_manifest_switches_to.lua

--- ==============================================================================
--- MODULE: sqlite_reader switches_to projection regression tests
--- DESCRIPTION:
--- The aggregator persists directed application transitions in
--- agg_app_day_switches_to, and the shared metrics pages read
--- manifest[date][app].switches_to (app pair affinity, workflow views). The
--- macOS reader never projected that table, so those views were empty on a Mac
--- while Windows and Linux filled them, and a change to the table could not
--- invalidate a cached projection (reader-switches-to-2026-10-21).
--- ==============================================================================

local helpers = require("tests.helpers")

--- Models hs.sqlite3 answering one table with fixed rows.
--- @param rows table Rows returned for agg_app_day_switches_to.
--- @return table sqlite3, table seen_sql
local function native_sqlite(rows)
	local seen = {}
	local sqlite3 = { OK = 0, OPEN_READONLY = 1 }
	function sqlite3.open()
		return {
			exec = function() return 0 end,
			close = function() return 0 end,
			nrows = function(_, sql)
				seen[#seen + 1] = sql
				local index, selected = 0, {}
				if sql:find("FROM agg_app_day_switches_to", 1, true) and sql:find("app_to", 1, true) then
					selected = rows
				end
				return function()
					index = index + 1
					return selected[index]
				end
			end,
		}
	end
	return sqlite3, seen
end

local function load_reader(rows)
	local sqlite3, seen = native_sqlite(rows)
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	return helpers.load_with_stubs("modules.keystats.sqlite_reader", { sqlite3 = sqlite3 }), seen
end


helpers.describe("sqlite_reader projects directed app transitions (reader-switches-to-2026-10-21)", function()
	helpers.it("publishes switches_to per date and source app", function()
		local reader = load_reader({
			{ date = "2026-10-20", app = "Safari", app_to = "Mail", count = 6 },
			{ date = "2026-10-20", app = "Safari", app_to = "Notes", count = 0 },
			{ date = "2026-10-21", app = "Mail", app_to = "Safari", count = 1 },
		})
		local manifest, complete = reader.read_manifest("/db.sqlite")
		helpers.assert_eq(complete, true)
		helpers.assert_eq(manifest["2026-10-20"].Safari.switches_to, { Mail = 6, Notes = 0 })
		helpers.assert_eq(manifest["2026-10-21"].Mail.switches_to, { Safari = 1 })
	end)

	helpers.it("leaves switches_to absent for an app without transitions", function()
		local reader = load_reader({ { date = "2026-10-20", app = "Safari", app_to = "Mail", count = 2 } })
		local manifest = reader.read_manifest("/db.sqlite")
		helpers.assert_eq(manifest["2026-10-20"].Mail, nil)
	end)

	helpers.it("sums device contributions and keeps the date window", function()
		local reader, seen = load_reader({})
		reader.read_manifest("/db.sqlite", "2026-10-01", "2026-10-21")
		local query
		for _, sql in ipairs(seen) do
			if sql:find("FROM agg_app_day_switches_to", 1, true) and sql:find("app_to", 1, true) then query = sql end
		end
		helpers.assert_true(query ~= nil, "the manifest must read agg_app_day_switches_to")
		helpers.assert_true(query:find("SUM(count)", 1, true) ~= nil, "contributions of several devices must be summed")
		helpers.assert_true(query:find("date >= '2026-10-01'", 1, true) ~= nil, "the lower date bound must apply")
		helpers.assert_true(query:find("date <= '2026-10-21'", 1, true) ~= nil, "the upper date bound must apply")
	end)

	helpers.it("includes the table in the past-data fingerprint", function()
		local reader, seen = load_reader({})
		helpers.assert_type(reader.fingerprint("/db.sqlite", "2026-10-21"), "string")
		local covered = false
		for _, sql in ipairs(seen) do
			if sql:find("FROM agg_app_day_switches_to WHERE date <=", 1, true) then covered = true end
		end
		helpers.assert_true(covered, "a change to transitions must invalidate cached projections")
	end)
end)
