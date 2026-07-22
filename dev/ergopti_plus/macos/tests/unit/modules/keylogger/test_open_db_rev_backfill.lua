--- tests/unit/modules/keylogger/test_open_db_rev_backfill.lua

--- ==============================================================================
--- MODULE: Regression — open_db back-fills the 'rev' meta key on existing DBs
--- DESCRIPTION:
--- Audit finding F-L2. open_db's INSERT OR IGNORE meta back-fill (applied to
--- existing DBs, where the fresh-DB schema block is skipped) seeded only
--- next_event_id/today_log_offset/today_log_date/ngram_ctx_json — NOT 'rev'. On a
--- DB created before 'rev' shipped, ingest's `UPDATE meta ... WHERE key='rev'`
--- matched 0 rows (a silent no-op), so get_db_rev() stayed 0 forever and dashboard
--- webviews keyed on rev never invalidated their cache. Fix: add 'rev' to the loop.
--- The meta back-fill set must stay in lockstep with schema.sql's meta seeds.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("sqlite_writer open_db back-fills the rev meta key", function()
	helpers.it("the meta back-fill loop includes 'rev'", function()
		local fh = assert(io.open(helpers.driver_root() .. "modules/keylogger/sqlite_writer.lua", "r"))
		local src = fh:read("*a"); fh:close()
		-- Locate the INSERT OR IGNORE meta back-fill loop and assert 'rev' is seeded.
		local loop = src:find('{ "next_event_id"', 1, true)
		helpers.assert_true(loop ~= nil, "could not find the meta back-fill loop")
		local region = src:sub(loop, loop + 400)
		helpers.assert_true(region:find('{ "rev",', 1, true) ~= nil,
			"the meta back-fill must seed 'rev' so existing DBs get the UI cache-invalidation counter")
	end)
end)
