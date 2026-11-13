--- tests/unit/metrics/engine/storage/ngrams/test_read_completion.lua

--- ==============================================================================
--- MODULE: N-gram Read Completion Regression
--- DESCRIPTION:
--- Separate successful absence from native refusal across every n-gram family.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.modules.keystats.ngram_completion_fixture")

local function key(family) return family.code == "kc" and "12" or "a" end

helpers.describe("ngram-read-completion", function()
	helpers.it("selected app retains Unknown but excludes Browser in historical and today results", function()
		Fixture.run({ today = true }, function(state, reader)
			for _, date in ipairs({ Fixture.PAST, Fixture.TODAY }) do
				for _, item in ipairs({ { "Unknown", "unknown-probe", 3 }, { "Browser", "browser-probe", 5 } }) do
					state.tables.ngram_chars[#state.tables.ngram_chars + 1] = {
						date = date, app = item[1], token = item[2], c = item[3], td = 0, e = 0, esrc_json = "{}",
					}
				end
			end
			for _, paced in ipairs({ false, true }) do
				local historical, complete = reader.read_ngrams("/fixture/db.sqlite", Fixture.PAST, Fixture.PAST,
					{ "Editor" }, paced and state.pacer or nil)
				helpers.assert_true(complete)
				helpers.assert_eq(historical.c.a.c, 7)
				helpers.assert_eq(historical.c["unknown-probe"].c, 3)
				helpers.assert_nil(historical.c["browser-probe"])
			end
			local today, complete = reader.read_today_split("/fixture/db.sqlite", Fixture.TODAY, Fixture.TODAY,
				{ "Editor" }, nil, Fixture.TODAY)
			helpers.assert_true(complete)
			helpers.assert_eq(today.Editor.c.b.c, 11)
			helpers.assert_eq(today.Unknown.c["unknown-probe"].c, 3)
			helpers.assert_nil(today.Browser)
		end)
	end)
	helpers.it("paced empty future bounds perform no daily reads, including the last date", function()
		Fixture.run({ empty = true }, function(state, reader)
			local data, complete = reader.read_ngrams("/fixture/db.sqlite", "9999-12-31", "9999-12-31", nil, state.pacer)
			helpers.assert_true(complete)
			helpers.assert_nil(next(data.c))
			for _, query in ipairs(state.reads) do
				helpers.assert_true(query.bounds, "an empty census must not launch daily aggregate queries")
			end
		end)
	end)

	helpers.it("paced sparse ranges visit only dates with data", function()
		Fixture.run({}, function(state, reader)
			for _, family in ipairs(Fixture.FAMILIES) do
				for _, row in ipairs(state.tables[family.table]) do
					if row.date == Fixture.NEXT then row.date = "2049-10-19" end
				end
			end
			local data, complete = reader.read_ngrams("/fixture/db.sqlite", Fixture.PAST, "2049-10-19", nil, state.pacer)
			helpers.assert_true(complete)
			helpers.assert_eq(data.c.a.c, 7); helpers.assert_eq(data.c.b.c, 11)
			local dates = {}
			for _, query in ipairs(state.reads) do
				if not query.bounds then
					helpers.assert_eq(query.first, query.last, "each paced aggregate reads exactly one present day")
					dates[query.first] = true
				end
			end
			helpers.assert_eq(dates, { [Fixture.PAST] = true, ["2049-10-19"] = true })
		end)
	end)
	for _, paced in ipairs({ false, true }) do
		local mode = paced and "paced" or "synchronous"
		helpers.it("(ngram-read-completion) acknowledges healthy " .. mode .. " rows", function()
			Fixture.run({}, function(state, reader)
				local data, complete = reader.read_ngrams("/fixture/db.sqlite", Fixture.PAST, Fixture.PAST,
					{ "Editor" }, paced and state.pacer or nil)
				helpers.assert_eq(complete, true)
				for _, family in ipairs(Fixture.FAMILIES) do helpers.assert_eq(data[family.code][key(family)].c, 7) end
				helpers.assert_eq(#state.errors, 0)
				helpers.assert_eq(state.opens, state.closes)
			end)
		end)
		helpers.it("(ngram-read-completion) acknowledges healthy empty " .. mode .. " rows", function()
			Fixture.run({ empty = true }, function(state, reader)
				local data, complete = reader.read_ngrams("/fixture/db.sqlite", Fixture.PAST, Fixture.PAST,
					{ "Editor" }, paced and state.pacer or nil)
				helpers.assert_eq(complete, true)
				for _, family in ipairs(Fixture.FAMILIES) do helpers.assert_eq(next(data[family.code]), nil) end
				helpers.assert_eq(#state.errors, 0)
			end)
		end)
		helpers.it("(ngram-read-completion) refuses an unopened " .. mode .. " database", function()
			Fixture.run({}, function(state, reader)
				state.refuse_open_at = 1
				local data, complete = reader.read_ngrams("/fixture/db.sqlite", Fixture.PAST, Fixture.PAST,
					{ "Editor" }, paced and state.pacer or nil)
				helpers.assert_eq(complete, false)
				helpers.assert_eq(#state.errors, 1)
				for _, family in ipairs(Fixture.FAMILIES) do helpers.assert_eq(next(data[family.code]), nil) end
				helpers.assert_eq(state.closes, 0)
			end)
		end)
		for _, family in ipairs(Fixture.FAMILIES) do
			for _, failure in ipairs({ "rows", "after-row" }) do
				helpers.it("(ngram-read-completion) " .. mode .. " " .. family.code .. " " .. failure, function()
					Fixture.run({ target = family.table, failure = failure }, function(state, reader)
						local data, complete = reader.read_ngrams("/fixture/db.sqlite", Fixture.PAST, Fixture.PAST,
							{ "Editor" }, paced and state.pacer or nil)
						helpers.assert_eq(complete, false)
						helpers.assert_eq(#state.errors, 1, "the native refusal remains visible")
						for _, other in ipairs(Fixture.FAMILIES) do
							if other ~= family then helpers.assert_eq(data[other.code][key(other)].c, 7) end
						end
						if failure == "after-row" and not paced then
							helpers.assert_eq(data[family.code][key(family)].c, 7, "accepted rows survive containment")
						else
							helpers.assert_eq(next(data[family.code]), nil, "paced draining never exposes an unfinished statement")
						end
						helpers.assert_eq(state.opens, state.closes)
					end)
				end)
			end
		end
	end
	for _, family in ipairs(Fixture.FAMILIES) do
		helpers.it("(ngram-read-completion) refuses missing " .. family.code .. " bounds acknowledgement", function()
			Fixture.run({ target = family.table, failure = "bounds" }, function(state, reader)
				local data, complete = reader.read_ngrams("/fixture/db.sqlite", Fixture.PAST, Fixture.PAST,
					{ "Editor" }, state.pacer)
				helpers.assert_eq(complete, false)
				helpers.assert_eq(#state.errors, 1)
				for _, other in ipairs(Fixture.FAMILIES) do helpers.assert_eq(data[other.code][key(other)].c, 7) end
				helpers.assert_eq(state.opens, state.closes)
			end)
		end)
	end
end)
