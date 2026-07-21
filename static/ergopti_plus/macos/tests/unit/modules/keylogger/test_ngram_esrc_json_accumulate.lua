--- tests/unit/modules/keylogger/test_ngram_esrc_json_accumulate.lua

--- ==============================================================================
--- MODULE: Regression — the n-gram source split must accumulate, not overwrite
--- DESCRIPTION:
--- Silent data corruption in the metrics dashboard's "typed vs expanded" split.
---
--- ROOT CAUSE ENCODED:
--- The n-gram UPSERT summed every scalar column but ASSIGNED the JSON one:
---   c=c+excluded.c, td=td+excluded.td, cd=cd+excluded.cd, e=e+excluded.e,
---   esrc_json=excluded.esrc_json
--- item.esrc is a per-tick DELTA — the batch row is deleted after each successful
--- flush — so the assignment discarded every source count accumulated by earlier
--- ticks. The n-gram's total `c` stayed correct while its hotstring / LLM / manual
--- breakdown silently reflected only the LAST flush window. Nothing failed; the
--- dashboard simply displayed a wrong split for every n-gram seen more than once.
---
--- CROSS-DRIVER PARITY:
--- The Windows driver has carried the merge since it was fixed there
--- (KLW_EsrcMergeExpr in keylogger_walker_sql.ahk, with its own regression test
--- test_ngram_esrc_json_accumulate.ahk). macOS kept the overwriting form, so the
--- two drivers disagreed about the same table. This test is the macOS twin of that
--- Windows guard, deliberately named to match.
---
--- The assertion is on the generated SQL: the aggregator builds statements as
--- strings and hands them to SQLite, so the statement IS the observable — and a
--- merge expression versus a bare assignment is exactly what differs.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ==============================================
-- ==============================================
-- ======= 1/ The UPSERT Merges The Blob ========
-- ==============================================
-- ==============================================

helpers.describe("n-gram UPSERT accumulates esrc_json across flush ticks", function()
	helpers.it("does not assign excluded.esrc_json directly", function()
		local path = helpers.driver_root() .. "modules/keylogger/aggregator/sql.lua"
		local fh = io.open(path, "r")
		helpers.assert_true(fh ~= nil, "aggregator/sql.lua must be readable")
		local src = fh:read("*a") ; fh:close()

		-- Match the CODE form specifically — the SQL fragment as it is concatenated
		-- into the statement. The helper's own docstring quotes the old assignment in
		-- prose to explain what it replaced, and that must not read as a live call
		-- site; prose never carries the `.. "` concatenation prefix.
		helpers.assert_true(src:find('%.%. "esrc_json=excluded%.esrc_json"') == nil,
			"the n-gram UPSERT must not ASSIGN excluded.esrc_json: item.esrc is a per-tick "
			.. "delta, so assigning it discards every source count accumulated by earlier "
			.. "flush ticks and the dashboard's typed-vs-expanded split reflects only the "
			.. "last window")
	end)

	helpers.it("builds a json_set merge that sums each source key", function()
		local path = helpers.driver_root() .. "modules/keylogger/aggregator/sql.lua"
		local fh = io.open(path, "r")
		helpers.assert_true(fh ~= nil, "aggregator/sql.lua must be readable")
		local src = fh:read("*a") ; fh:close()

		helpers.assert_true(src:find("esrc_merge_expr") ~= nil,
			"a merge-expression helper must exist, mirroring the Windows KLW_EsrcMergeExpr")
		helpers.assert_true(src:find("json_set%(COALESCE%(esrc_json") ~= nil,
			"the merge must start from the STORED blob (json_set over COALESCE(esrc_json,'{}')), "
			.. "otherwise it still loses the accumulated counts")
		helpers.assert_true(src:find("json_extract%(esrc_json") ~= nil
			and src:find("json_extract%(excluded%.esrc_json") ~= nil,
			"each key must sum the stored value AND the incoming one — reading only one side "
			.. "reproduces the overwrite this fix removes")
	end)

	helpers.it("degrades to the stored blob when the tick carries no source data", function()
		-- An empty delta must leave the accumulated blob untouched rather than
		-- writing '{}' over it.
		local path = helpers.driver_root() .. "modules/keylogger/aggregator/sql.lua"
		local fh = io.open(path, "r")
		helpers.assert_true(fh ~= nil, "aggregator/sql.lua must be readable")
		local src = fh:read("*a") ; fh:close()

		local at = src:find("local function esrc_merge_expr")
		helpers.assert_true(at ~= nil, "the helper must be locatable")
		local body = src:sub(at, at + 400)
		helpers.assert_true(body:find('return "COALESCE%(esrc_json') ~= nil,
			"an empty or absent esrc delta must fall back to COALESCE(esrc_json,'{}') so the "
			.. "existing counts survive a tick that carried no source information")
	end)
end)
