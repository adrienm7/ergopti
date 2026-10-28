--- tests/unit/modules/keystats/storage/test_reader_ngram_catalogue.lua

--- ==============================================================================
--- MODULE: macOS n-gram reads come from the shared query catalogue
--- DESCRIPTION:
--- read_ngrams and the today split run the catalogue's ngram.tokens and
--- ngram.tokens_by_app (_shared/data/db/queries.sql), the statements Linux
--- runs. They used SUM, which overflows and sums a malformed counter as the
--- number its text starts with; the catalogue form uses TOTAL and returns such
--- a row raw, for the reader to read as zero (keystats SQL census, finding 7).
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads a reader whose database records statements and answers ngram_chars.
--- @param rows table Rows answered for ngram_chars statements.
--- @return table reader, table statements
local function reader_with(rows)
	package.loaded["infra.logger"] = {
		debug = function() end, trace = function() end, done = function() end,
		info = function() end, start = function() end, success = function() end,
		warn = function() end, error = function() end,
	}
	local statements = {}
	local sqlite = { OK = 0, open = function()
		return { exec = function() return 0 end, close = function() end,
			nrows = function(_, sql)
				statements[#statements + 1] = sql
				local answer = sql:find("FROM ngram_chars[^%w_]") and rows or {}
				local index = 0
				return function() index = index + 1; return answer[index] end
			end }
	end }
	return helpers.load_with_stubs("modules.keystats.sqlite_reader", { sqlite3 = sqlite }), statements
end

helpers.describe("macOS n-gram reads: the shared catalogue", function()
	local Queries = require("keystats.queries")

	helpers.it("issues the catalogue rendering for every family", function()
		local reader, statements = reader_with({})
		reader.read_ngrams("/declared/db.sqlite", "2026-10-01", "2026-10-02", { "Code" })
		local issued = {}
		for _, sql in ipairs(statements) do issued[sql] = true end
		local where = " WHERE date >= '2026-10-01' AND date <= '2026-10-02' AND app IN ('Code')"
		for _, family in ipairs({ "ngram_chars", "ngram_bigrams", "ngram_trigrams", "ngram_quadgrams",
			"ngram_pentagrams", "ngram_hexagrams", "ngram_heptagrams", "ngram_words", "ngram_word_bigrams" }) do
			local sql = Queries.render("ngram.tokens", "native", { table = family, where = where, conjunction = " AND " })
			helpers.assert_true(issued[sql] == true, family .. " is read through the catalogue")
		end
	end)

	helpers.it("reads a malformed counter as zero and keeps the projection complete", function()
		local reader = reader_with({
			{ token = "e", c = 420.0, td = 51000.0, e = 5.0, esrc_json = "{}", source_rows = 2 },
			{ token = "a", c = 90.0, td = 11000.0, e = 1.0, esrc_json = '{"hotstring":5}', source_rows = 2 },
			{ token = "a", c = 7.0, td = 800.0, e = 0.0, esrc_json = '{"llm":2,"case_transform":1}', source_rows = 1 },
			{ token = "z", c = "12oops", td = 100, e = 0, esrc_json = "{}", source_rows = 1 },
		})
		local out, complete = reader.read_ngrams("/declared/db.sqlite")
		helpers.assert_true(complete, "a malformed row must not abort the family")
		helpers.assert_eq(out.c.z.c, 0, "the malformed counter is not summed as 12")
		helpers.assert_eq(out.c.z.t, 100)
		helpers.assert_eq(out.c.e.c, 420)
		helpers.assert_eq(out.c.e.t, 51000)
		helpers.assert_eq(out.c.a.c, 97)
		helpers.assert_eq(out.c.a.hs, 10, "an identical source map counts once per device")
		helpers.assert_eq(out.c.a.llm, 2)
		helpers.assert_eq(out.c.a.o, 1)
	end)
end)
