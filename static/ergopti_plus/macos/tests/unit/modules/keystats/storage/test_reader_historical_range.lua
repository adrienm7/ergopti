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
					nrows = function(_, sql)
						open_count.queries = (open_count.queries or 0) + 1
						if open_count.fail_distinct and sql:find("SELECT DISTINCT date FROM ngram_chars", 1, true) then
							open_count.failure_observed = true
							error("independent census failure")
						end
						return function() return nil end
					end,
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

	helpers.it("reports a refused future-date census as incomplete", function()
		local calls = { value = 0, fail_distinct = true }
		local reader = load_reader(calls)
		local projection = helpers.load_with_stubs("ui.metrics_typing.projection")
		projection.reset()
		local session = projection.session(reader, "/fake/db.sqlite", "2026-11-05", { pause = function() end })
		local json, complete = session.range("2027-01-01", "2027-12-31", nil)
		helpers.assert_eq(complete, false)
		helpers.assert_true(calls.failure_observed)
		helpers.assert_true(json:find('"incomplete":true', 1, true) ~= nil)
	end)
	helpers.it("does not visit every empty day of a future dashboard selection", function()
		local calls = { value = 0 }
		local reader = load_reader(calls)
		local projection = helpers.load_with_stubs("ui.metrics_typing.projection")
		projection.reset()
		local session = projection.session(reader, "/fake/db.sqlite", "2026-11-05", { pause = function() end })
		local _, complete = session.range("2027-01-01", "2028-12-31", nil)
		helpers.assert_true(complete)
		helpers.assert_true(calls.queries < 100, "empty range performed " .. tostring(calls.queries) .. " queries")
	end)
	helpers.it("admits an empty selection on the final representable day in paced mode", function()
		local reader = load_reader({ value = 0 })
		local ok, result, complete = pcall(reader.read_range_split_today, "/fake/db.sqlite",
			"9999-12-31", "9999-12-31", nil, { pause = function() end }, "2026-11-05")
		helpers.assert_true(ok, tostring(result))
		helpers.assert_true(complete)
	end)
	helpers.it("projects an empty future day through the real dashboard owner", function()
		local reader = load_reader({ value = 0 })
		local projection = helpers.load_with_stubs("ui.metrics_typing.projection")
		projection.reset()
		local session = projection.session(reader, "/fake/db.sqlite", "2026-11-05", { pause = function() end })
		local ok, result = pcall(session.range, "9999-12-31", "9999-12-31", nil)
		helpers.assert_true(ok, tostring(result))
	end)
	helpers.it("includes explicitly selected future dates without duplicating today", function()
		local reader = load_reader({ value = 0 })
		local today = os.date("%Y-%m-%d")
		local tomorrow = reader.next_day(today)
		local calls = {}
		reader.read_ngrams = function(_, first, last)
			calls[#calls + 1] = { first, last }
			return { c = { token = { c = last == tomorrow and 3 or 1, t = 0, e = 0, hs = 0, llm = 0, o = 0 } } }, true
		end
		reader.read_today_split = function() return {}, true end
		local result, complete = reader.read_range_split_today("/fake/db.sqlite", nil, tomorrow)
		helpers.assert_true(complete)
		helpers.assert_eq(result.historical.c.token.c, 4)
		helpers.assert_eq(calls[2][1], tomorrow)
		helpers.assert_eq(calls[2][2], tomorrow)
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
