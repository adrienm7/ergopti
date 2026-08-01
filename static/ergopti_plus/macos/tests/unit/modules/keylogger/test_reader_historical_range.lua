--- tests/unit/modules/keylogger/test_reader_historical_range.lua

--- ============================================================================
--- MODULE: Regression — typing dashboard historical date ranges
--- DESCRIPTION:
--- `read_range_split_today` maintains a special live per-app projection for
--- today. It previously opened and merged that projection for every request,
--- so selecting a past date leaked today's keys into historical typing totals.
--- ============================================================================

local helpers = require("tests.helpers")

local function load_reader(open_count)
	package.loaded["infra.logger"] = {
		debug = function() end, trace = function() end, done = function() end,
		info = function() end, start = function() end, success = function() end,
		warn = function() end, error = function() end,
	}
	return helpers.load_with_stubs("modules.keylogger.sqlite_reader", {
		sqlite3 = {
			OK = 0,
			open = function()
				open_count.value = open_count.value + 1
				return {
					exec = function() return 0 end,
					close = function() end,
					nrows = function() return function() return nil end end,
				}
			end,
		},
	})
end

helpers.describe("sqlite_reader: historical ranges exclude the live today split", function()
	helpers.it("does not open a second today projection for an interval ending before today", function()
		local opens = { value = 0 }
		local reader = load_reader(opens)
		local result = reader.read_range_split_today("/fake/db.sqlite", "2001-01-01", "2001-01-02")
		helpers.assert_eq(opens.value, 1,
			"a past-only request must read historical ngrams once and skip today's projection")
		helpers.assert_eq(next(result.today), nil,
			"a past-only request must not return current-day ngrams")
	end)

	helpers.it("still opens the live split when the requested range includes today", function()
		local opens = { value = 0 }
		local reader = load_reader(opens)
		reader.read_range_split_today("/fake/db.sqlite", nil, os.date("%Y-%m-%d"))
		helpers.assert_eq(opens.value, 2,
			"a range ending today needs both historical and per-app live projections")
	end)
end)
