--- tests/unit/modules/keylogger/test_reader_ngram_multidevice_esrc.lua

--- Regression test for keylogger-storage-2: read_ngrams, read_range_split_today,
--- and read_manifest used `MIN(esrc_json)` / `MIN(e_buckets_json)` /
--- `MIN(length_buckets_json)` to collapse multi-device rows in SQL, keeping
--- only one device's JSON blob and silently discarding the others.
---
--- Fix: changed all affected queries to GROUP BY including the JSON column and
--- accumulate the decoded values key-by-key in Lua, so all devices' counts
--- contribute to the final totals.

local helpers = require("tests.helpers")

-- Selected by a declaration unique to modules/keylogger/sqlite_reader.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("function M.read_range_split_today")
helpers.assert_true(src ~= nil, "modules/keylogger/sqlite_reader.lua source must be locatable")

-- Test 1: MIN(esrc_json) AS ... must not appear in SQL context.
-- Matches SQL aggregation syntax "MIN(esrc_json) AS" but not inline comments.
local min_esrc = src:find("MIN(esrc_json) AS", 1, true) ~= nil
helpers.assert_true(
	not min_esrc,
	"sqlite_reader.lua must not use `MIN(esrc_json) AS` in SQL — it drops multi-device data (keylogger-storage-2)"
)

-- Test 2: MIN(e_buckets_json) AS must not appear in SQL context.
local min_ebuckets = src:find("MIN(e_buckets_json) AS", 1, true) ~= nil
helpers.assert_true(
	not min_ebuckets,
	"sqlite_reader.lua must not use `MIN(e_buckets_json) AS` in SQL — it drops multi-device data (keylogger-storage-2)"
)

-- Test 3: MIN(length_buckets_json) AS must not appear in SQL context.
local min_lbuckets = src:find("MIN(length_buckets_json) AS", 1, true) ~= nil
helpers.assert_true(
	not min_lbuckets,
	"sqlite_reader.lua must not use `MIN(length_buckets_json) AS` in SQL — it drops multi-device data (keylogger-storage-2)"
)

-- Test 4: esrc_json appears in GROUP BY clauses (multi-device grouping).
local group_by_esrc = src:find("GROUP BY token, esrc_json", 1, true) ~= nil
helpers.assert_true(
	group_by_esrc,
	"sqlite_reader.lua read_ngrams must GROUP BY token, esrc_json (keylogger-storage-2)"
)

-- Test 5: Lua accumulation of esrc_json — item.hs and item.llm use += not direct assign.
-- Pre-fix: item.hs = src.hotstring or 0 (overwrites per row)
-- Post-fix: item.hs = item.hs + (src.hotstring or 0) (accumulates across rows)
local direct_assign_hs = src:find("item.hs  = src.hotstring", 1, true) ~= nil
helpers.assert_true(
	not direct_assign_hs,
	"sqlite_reader.lua must not directly assign item.hs = src.hotstring — must accumulate with += (keylogger-storage-2)"
)

local accum_hs = src:find("item.hs  = item.hs  + (src.hotstring", 1, true) ~= nil
helpers.assert_true(
	accum_hs,
	"sqlite_reader.lua must accumulate item.hs with item.hs + (src.hotstring or 0) (keylogger-storage-2)"
)

-- Test 6: e_buckets are merged key-by-key, not assigned wholesale.
-- Pre-fix: h.e_buckets = buckets (overwrites)
-- Post-fix: h.e_buckets[k] = (h.e_buckets[k] or 0) + (v or 0)
local overwrite_buckets = src:find("h.e_buckets = buckets", 1, true) ~= nil
helpers.assert_true(
	not overwrite_buckets,
	"sqlite_reader.lua must not assign h.e_buckets = buckets wholesale — must merge key-by-key (keylogger-storage-2)"
)

-- Test 7: length_buckets_json is in GROUP BY for burst query.
local group_by_lbuckets = src:find("GROUP BY date, app, length_buckets_json", 1, true) ~= nil
helpers.assert_true(
	group_by_lbuckets,
	"sqlite_reader.lua agg_app_day_burst must GROUP BY date, app, length_buckets_json (keylogger-storage-2)"
)

print("[PASS] test_reader_ngram_multidevice_esrc")
