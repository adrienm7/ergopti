--- tests/unit/modules/keystats/storage/test_reader_historical_range.lua

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
	return helpers.load_with_stubs("modules.keystats.sqlite_reader", {
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
	helpers.it("returns incomplete and closes the database when a query error cannot be formatted", function()
		helpers.with_stub_scope({"modules.keystats.sqlite_reader", "infra.logger"}, function()
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			local calls, closed = 0, 0
			local opaque = setmetatable({}, {__tostring = function() error("unprintable") end})
			local reader = helpers.load_with_stubs("modules.keystats.sqlite_reader", {
				sqlite3 = {OPEN_READONLY = 1, open = function()
					return {
						exec = function() return 0 end,
						close = function() closed = closed + 1 end,
						nrows = function()
							calls = calls + 1
							if calls == 1 then error(opaque) end
							return function() return nil end
						end,
					}
				end},
			})
			local ok, manifest, complete = pcall(reader.read_manifest, "/fake/db.sqlite")
			helpers.assert_true(ok, "formatting a query error must not escape the reader")
			helpers.assert_true(type(manifest) == "table")
			helpers.assert_eq(complete, false)
			helpers.assert_true(calls > 1, "subsequent projections still run")
			helpers.assert_eq(closed, 1)
		end)
	end)

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
