--- tests/unit/modules/keystats/storage/ngrams/test_ngram_read_completion.lua

--- ==============================================================================
--- MODULE: N-gram Read Completion Regression
--- DESCRIPTION:
--- Separate successful absence from native refusal across every n-gram family.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.modules.keystats.ngram_completion_fixture")

local function key(family) return family.code == "kc" and "12" or "a" end

helpers.describe("ngram-read-completion", function()
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
