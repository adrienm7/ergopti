--- tests/unit/modules/keylogger/test_reader_yesterday_date.lua

--- Regression test for keylogger-storage-4: read_range_split_today computed
--- "yesterday" by subtracting 1 from the day component as a string operation
--- (today_str:sub(9,10) - 1). On the 1st of any month this produced "00" as
--- the day, yielding an invalid ISO date like "2026-01-00". The query against
--- SQLite silently returned no rows for the historical half, making the
--- split read appear as "today only" data with no history.
---
--- Fix: compute yesterday via os.date("%Y-%m-%d", os.time() - 86400), which
--- correctly handles month and year boundaries.

local helpers = require("tests.helpers")

-- Selected by a declaration unique to modules/keylogger/sqlite_reader.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("function M.read_range_split_today")
helpers.assert_true(src ~= nil, "modules/keylogger/sqlite_reader.lua source must be locatable")

-- Test 1: The broken manual string subtraction must not be present.
local has_bad_pattern = src:find('tonumber(today_str:sub(9, 10)) - 1', 1, true) ~= nil
helpers.assert_true(
	not has_bad_pattern,
	"sqlite_reader.lua must not compute yesterday by subtracting 1 from the day substring — fails on 1st of month (keylogger-storage-4)"
)

-- Test 2: The correct computation uses os.date with os.time subtraction.
local has_good_pattern = src:find('os.date("%Y-%m-%d", os.time() - 86400)', 1, true) ~= nil
helpers.assert_true(
	has_good_pattern,
	'sqlite_reader.lua must compute yesterday via os.date("%%Y-%%m-%%d", os.time() - 86400) (keylogger-storage-4)'
)

-- Test 3: yesterday_str variable is used in the read_ngrams call.
local has_yesterday_var = src:find("yesterday_str", 1, true) ~= nil
helpers.assert_true(
	has_yesterday_var,
	"sqlite_reader.lua must use yesterday_str variable in read_range_split_today (keylogger-storage-4)"
)

print("[PASS] test_reader_yesterday_date")
