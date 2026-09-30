--- tests/unit/modules/keylogger/test_reader_yesterday_date.lua

--- Regression test for keylogger-storage-4: read_range_split_today computed
--- "yesterday" by subtracting 1 from the day component as a string operation
--- (today_str:sub(9,10) - 1). On the 1st of any month this produced "00" as
--- the day, yielding an invalid ISO date like "2026-01-00". The query against
--- SQLite silently returned no rows for the historical half, making the
--- split read appear as "today only" data with no history.
---
--- Fix: yesterday is calendar arithmetic on the day being split
--- (`sqlite_reader.split_bounds`), which handles month and year boundaries and
--- keeps one "today" for a whole paced projection job.

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

-- Test 2: The split's historical end is the real previous calendar day.
helpers.with_fresh_modules({ "modules.keylogger.sqlite_reader", "infra.logger" }, function()
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	local reader = helpers.load_with_stubs("modules.keylogger.sqlite_reader")
	for today, yesterday in pairs({
		["2026-01-01"] = "2025-12-31", ["2026-03-01"] = "2026-02-28", ["2028-03-01"] = "2028-02-29",
		["2026-10-26"] = "2026-10-25", ["2026-09-30"] = "2026-09-29",
	}) do
		helpers.assert_eq(reader.split_bounds(nil, nil, today).historical_end, yesterday,
			"yesterday of " .. today .. " (keylogger-storage-4)")
	end
	helpers.assert_eq(reader.split_bounds("2026-02-01", "2026-02-10", "2026-03-01").historical_end, "2026-02-10",
		"a range ending before today keeps its own end")
	helpers.assert_eq(reader.split_bounds(nil, "2026-03-01", "2026-03-01").includes_today, true)
	helpers.assert_eq(reader.split_bounds(nil, "2026-02-28", "2026-03-01").includes_today, false)
end)

print("[PASS] test_reader_yesterday_date")
