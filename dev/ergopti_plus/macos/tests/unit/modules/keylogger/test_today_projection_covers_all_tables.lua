--- tests/unit/modules/keylogger/test_today_projection_covers_all_tables.lua

--- ==============================================================================
--- MODULE: Regression — today's projection must cover every n-gram table
--- DESCRIPTION:
--- The keycode heatmap and both shortcut tabs never moved while the user typed.
---
--- ROOT CAUSE ENCODED:
--- read_range_split_today builds its "today" slice by looping NGRAM_TYPE_TABLE.
--- ngram_keycodes, ngram_shortcuts and ngram_shortcut_bigrams are NOT members of
--- that table — they are queried separately on the HISTORICAL branch — so the
--- today branch simply never read them. Those three views therefore showed
--- yesterday's totals and stayed frozen for the whole day, which reads as "the
--- heatmap is broken" rather than as data that has not arrived yet.
---
--- Nothing failed: every query that ran, ran correctly. The defect is a missing
--- query, which is invisible to any test that only checks the queries present.
---
--- WHY A SOURCE GUARD:
--- read_range_split_today needs a live SQLite handle with nine populated tables to
--- observe behaviourally, and the module opens its own connection from a resolved
--- path. What is decidable — and what was actually wrong — is that the today branch
--- queries the same table set the historical branch does. This guard pins the
--- SET, so a table added to one branch and forgotten in the other fails CI.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Tables that live outside NGRAM_TYPE_TABLE and must be queried explicitly.
local STANDALONE_TABLES = { "ngram_keycodes", "ngram_shortcuts", "ngram_shortcut_bigrams" }





-- ==============================================
-- ==============================================
-- ======= 1/ Both Branches Query The Set =======
-- ==============================================
-- ==============================================

helpers.describe("today's projection reads the same tables as the historical one", function()
	helpers.it("queries every standalone n-gram table in the today branch", function()
		-- Selected by a declaration unique to modules/keylogger/sqlite_reader.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("function M.read_range_split_today")
		helpers.assert_true(src ~= nil, "modules/keylogger/sqlite_reader.lua source must be locatable")
		if not src then return end

		-- The today branch is everything after the today_idx projection begins.
		local today_at = src:find("today_idx", 1, true)
		helpers.assert_true(today_at ~= nil, "the today projection must be locatable")

		local missing = {}
		for _, tbl in ipairs(STANDALONE_TABLES) do
			-- A today pass is identifiable by the table name paired with the
			-- today-scoped label the file's _safe_query wrapper uses.
			if not src:find(tbl .. "%(today%)") then
				missing[#missing + 1] = tbl
			end
		end

		helpers.assert_true(#missing == 0, string.format(
			"%d table(s) are read on the historical branch but never on the today branch: "
			.. "%s. They are not members of NGRAM_TYPE_TABLE, so the loop that builds "
			.. "today's slice skips them — the keycode heatmap and the shortcut tabs then "
			.. "show only historical data and never move while the user types",
			#missing, table.concat(missing, ", ")))
	end)

	helpers.it("routes each today pass through the per-table failure wrapper", function()
		-- F-MED-28: a schema mismatch on one table must not abort the projection for
		-- the other eight, so the new passes must use _safe_query like every sibling.
		-- Selected by a declaration unique to modules/keylogger/sqlite_reader.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("function M.read_range_split_today")
		helpers.assert_true(src ~= nil, "modules/keylogger/sqlite_reader.lua source must be locatable")
		if not src then return end

		for _, tbl in ipairs(STANDALONE_TABLES) do
			helpers.assert_true(src:find('_safe_query%("' .. tbl .. '%(today%)"') ~= nil,
				tbl .. "'s today pass must be wrapped in _safe_query, so a schema mismatch "
				.. "on one table cannot abort the whole projection")
		end
	end)
end)
