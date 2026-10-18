--- tests/unit/modules/keylogger/storage/test_sqlite_reader_projection_ngram_extra_sources.lua

--- ==============================================================================
--- MODULE: The Reader Asks For Everything The Walk Writes
--- DESCRIPTION:
--- That the dashboard projection queries every n-gram table and every per-app-day
--- aggregate the schema declares, carries the delay and error columns out of
--- each, and lands the rows under the keys the dashboard reads.
---
--- THE DEFECT THIS PINS:
--- The reader named exactly one n-gram table and no aggregate table at all. It built an envelope with thirteen codes
--- in it and filled one, handing back permanently empty maps for the other
--- eight — so the word lists, the pair lists and every panel keyed on a sequence
--- longer than a single character rendered blank no matter what the database
--- held. Writing the tables (which the walker now does) fixes nothing on its own
--- if nobody reads them, and the two halves fail in exactly the same way from
--- the outside: a blank panel.
---
--- AND THE TWO COLUMNS IT DROPPED:
--- `td` and `e` were selected by neither query and discarded by the merge. They
--- are what separates a frequency list from a cost ranking — "which sequences
--- slow you down" is td/cd, and with td absent the panel sorted a column of
--- zeroes while looking entirely functional.
---
--- WHY IT STUBS THE COMMAND BUILDER AND io.popen:
--- sqlite3 is not guaranteed on the maintainer's machine or in CI, and a test
--- that skips when it is missing would report green having asserted nothing on
--- the platform that gates the merge. Stubbing both ends runs the reader's real
--- code — its SQL, its filters, its merge arithmetic — with nothing left to the
--- environment.
--- ==============================================================================

package.loaded["tests.support.modules.keylogger.storage.sqlite_reader_projection_fixture"] = nil
local Fixture = require("tests.support.modules.keylogger.storage.sqlite_reader_projection_fixture")
local helpers, Json, with_stubbed_sqlite =
	Fixture.helpers, Fixture.Json, Fixture.with_stubbed_sqlite




helpers.describe("linux-ngram-extra-sources", function()
	local cases = {
		{ "extra labels across identical source blobs", '{"hotstring":1,"llm":3,"other":2,"none":9,"case-transform":4,"owned-extension":1}', 2, 2, 6, 14 },
		{ "known sources and manual none exclusion", '{"hotstring":1,"llm":2,"other":3,"none":4}', 1, 1, 2, 3 },
		{ "safe recognized scalar admission", '{"hotstring":"3","llm":"4","other":"2","none":100,"string":"owned","table":{},"bool":true,"nil":null,"array":[9]}', 1, 3, 4, 2 },
		{ "extra scalar admission", '{"hotstring":1.5,"llm":2.5,"other":"3","case-transform":4.5,"owned-extension":"5","none":100}', 1, 1.5, 2.5, 12.5 },
		{ "array keys are not labels", '[1,2,3]', 1, 0, 0, 0 },
		{ "JSON null blob", 'null', 1, 0, 0, 0 },
		{ "JSON null values", '{"hotstring":null,"llm":null,"other":null,"owned":null}', 1, 0, 0, 0 },
		{ "JSON scalar blob", 'false', 1, 0, 0, 0 },
		{ "malformed legacy literal fallback", '{"hotstring":3,"llm":4,"other":5,owned', 1, 3, 4, 5 },
	}
	for _, case in ipairs(cases) do
		helpers.it("linux-ngram-extra-sources: " .. case[1], function()
			with_stubbed_sqlite(function(sql)
				if sql:find("FROM ngram_chars", 1, true) then
					return Json.encode({ { token_json = Json.encode("owned"), c = 40, td = 90, e = 6,
						esrc_json = case[2], source_rows = case[3] } })
				end
				return "[]"
			end, function(reader)
				local item = reader.read_ngrams("/db/owned.sqlite").c.owned
				helpers.assert_eq(item.c, 40)
				helpers.assert_eq(item.t, 90)
				helpers.assert_eq(item.e, 6)
				helpers.assert_eq(item.hs, case[4])
				helpers.assert_eq(item.llm, case[5])
				helpers.assert_eq(item.o, case[6])
			end)
		end)
	end
	helpers.it("linux-ngram-extra-sources: split-today uses the same source taxonomy", function()
		with_stubbed_sqlite(function(sql)
			if sql:find("FROM ngram_chars", 1, true) and sql:find("app,", 1, true) then
				return Json.encode({ { app = "owned", token_json = Json.encode("x"), c = 8, td = 20, e = 1,
					esrc_json = '{"hotstring":1,"llm":2,"none":99,"case-transform":5}', source_rows = 1 } })
			end
			return "[]"
		end, function(reader)
			local split = reader.read_range_split_today("/db/owned.sqlite")
			local item = split.today.owned.c.x
			helpers.assert_eq(item.c, 8)
			helpers.assert_eq(item.hs, 1)
			helpers.assert_eq(item.llm, 2)
			helpers.assert_eq(item.o, 5)
		end)
	end)
end)




helpers.describe("linux-ngram-source-policy", function()
	helpers.it("linux-ngram-source-policy: shared other-source membership excludes dedicated and nonlabel keys", function()
		local Utils = require("keylogger.utils")
		local cases = {
			{ label = "other", expected = true },
			{ label = "case-transform", expected = true },
			{ label = "owned-extension", expected = true },
			{ label = "", expected = true },
			{ label = "hotstring", expected = false },
			{ label = "llm", expected = false },
			{ label = "none", expected = false },
			{ label = 1, expected = false },
			{ label = true, expected = false },
			{ label = false, expected = false },
			{ label = {}, expected = false },
			{ expected = false },
		}
		for _, case in ipairs(cases) do
			helpers.assert_eq(Utils.is_other_synthetic_source(case.label), case.expected)
		end
	end)
end)

