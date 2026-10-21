--- tests/unit/modules/keylogger/storage/ngrams/test_today_read_completion.lua

--- ==============================================================================
--- MODULE: Today Read Completion Regression
--- DESCRIPTION:
--- Every native today query distinguishes empty success from partial SQL refusal.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.modules.keylogger.today_completion_fixture")

helpers.describe("today-read-completion", function()
	for _, paced in ipairs({ false, true }) do
		local mode = paced and "paced" or "synchronous"
		helpers.it("(today-read-completion) accepts healthy " .. mode .. " rows", function()
			Fixture.run({}, function(state, reader)
				local data, complete = reader.read_today_split("/fixture/db.sqlite", Fixture.TODAY, Fixture.TODAY,
					{ "Editor" }, paced and state.pacer or nil, Fixture.TODAY)
				helpers.assert_eq(complete, true)
				for _, family in ipairs(Fixture.FAMILIES) do
					helpers.assert_eq(data.Editor[family.code][Fixture.key(family)].c, 11)
				end
				helpers.assert_eq(#state.errors, 0)
				helpers.assert_eq(state.opens, state.closes)
			end)
		end)
		helpers.it("(today-read-completion) accepts healthy empty " .. mode .. " rows", function()
			Fixture.run({ empty = true }, function(state, reader)
				local data, complete = reader.read_today_split("/fixture/db.sqlite", Fixture.TODAY, Fixture.TODAY,
					{ "Editor" }, paced and state.pacer or nil, Fixture.TODAY)
				helpers.assert_eq(complete, true)
				helpers.assert_eq(next(data), nil)
				helpers.assert_eq(#state.errors, 0)
			end)
		end)
		helpers.it("(today-read-completion) refuses unopened " .. mode .. " database", function()
			Fixture.run({}, function(state, reader)
				state.refuse_open_at = 1
				local data, complete = reader.read_today_split("/fixture/db.sqlite", Fixture.TODAY, Fixture.TODAY,
					{ "Editor" }, paced and state.pacer or nil, Fixture.TODAY)
				helpers.assert_eq(complete, false)
				helpers.assert_eq(next(data), nil)
				helpers.assert_eq(#state.errors, 1)
				helpers.assert_eq(state.closes, 0)
			end)
		end)
		for _, family in ipairs(Fixture.FAMILIES) do
			for _, failure in ipairs({ "rows", "after-row" }) do
				helpers.it("(today-read-completion) " .. mode .. " " .. family.code .. " " .. failure, function()
					Fixture.run({ target = family.table, failure = failure }, function(state, reader)
						local data, complete = reader.read_today_split("/fixture/db.sqlite", Fixture.TODAY, Fixture.TODAY,
							{ "Editor" }, paced and state.pacer or nil, Fixture.TODAY)
						helpers.assert_eq(complete, false)
						helpers.assert_eq(#state.errors, 1)
						for _, other in ipairs(Fixture.FAMILIES) do
							if other ~= family then helpers.assert_eq(data.Editor[other.code][Fixture.key(other)].c, 11) end
						end
						if failure == "after-row" and not paced then
							helpers.assert_eq(data.Editor[family.code][Fixture.key(family)].c, 11,
								"the existing partial first return remains compatible")
						else
							helpers.assert_eq(next(data.Editor[family.code]), nil,
								"paced draining does not expose an unfinished statement")
						end
						helpers.assert_eq(state.opens, state.closes)
					end)
				end)
			end
		end
	end
	for _, interval in ipairs({ { Fixture.PAST, Fixture.NEXT }, { "2026-10-21", "2026-10-22" } }) do
		helpers.it("(today-read-completion) excluded today " .. interval[1] .. " needs no database", function()
			Fixture.run({ failure = "rows" }, function(state, reader)
				state.refuse_open_at = 1
				local data, complete = reader.read_today_split("/fixture/db.sqlite", interval[1], interval[2],
					{ "Editor" }, state.pacer, Fixture.TODAY)
				helpers.assert_eq(complete, true)
				helpers.assert_eq(next(data), nil)
				helpers.assert_eq(state.opens, 0)
				helpers.assert_eq(#state.errors, 0)
			end)
		end)
	end
	helpers.it("(today-read-completion) an unmatched app is a successful empty selection", function()
		Fixture.run({}, function(state, reader)
			local data, complete = reader.read_today_split("/fixture/db.sqlite", Fixture.TODAY, Fixture.TODAY,
				{ "Other" }, state.pacer, Fixture.TODAY)
			helpers.assert_eq(complete, true)
			helpers.assert_eq(next(data), nil)
			helpers.assert_eq(#state.errors, 0)
		end)
	end)
end)
