--- tests/unit/meta/test_sqlite_reader_projection.lua

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

local helpers = require("tests.helpers")

-- Every table the schema declares for character sequences, and the code the
-- dashboard envelope uses for each.
local EXPECTED = {
	{ code = "c", table_name = "ngram_chars" },
	{ code = "bg", table_name = "ngram_bigrams" },
	{ code = "tg", table_name = "ngram_trigrams" },
	{ code = "qg", table_name = "ngram_quadgrams" },
	{ code = "pg", table_name = "ngram_pentagrams" },
	{ code = "hx", table_name = "ngram_hexagrams" },
	{ code = "hp", table_name = "ngram_heptagrams" },
	{ code = "w", table_name = "ngram_words" },
	{ code = "w_bg", table_name = "ngram_word_bigrams" },
}

--- Runs the reader with both ends of its sqlite3 shell-out replaced.
---
--- @param responder function Given the SQL, returns the JSON body sqlite3 would
---        have printed (or "" for no rows).
--- @param body function Receives the freshly loaded reader module.
--- @return table Every SQL statement the reader issued, in order.
local function with_stubbed_sqlite(responder, body)
	local command_name = "modules.keylogger.sqlite_command"
	local reader_name = "modules.keylogger.sqlite_reader"
	local previous_command = package.loaded[command_name]
	local previous_reader = package.loaded[reader_name]
	local previous_popen = io.popen

	local statements = {}
	local next_body = ""

	package.loaded[command_name] = {
		build = function(_path, sql)
			statements[#statements + 1] = sql
			next_body = responder(sql) or ""
			-- The literal never runs: io.popen is stubbed too. It only has to be
			-- a non-nil string, because returning nil is the reader's own signal
			-- that the command could not be composed.
			return "true"
		end,
		sanitise_error = function(msg) return msg end,
	}
	io.popen = function()
		local sent = next_body
		return {
			read = function() return sent end,
			close = function() return true end,
		}
	end

	package.loaded[reader_name] = nil
	local ok, err = pcall(function()
		body(require(reader_name))
	end)

	io.popen = previous_popen
	package.loaded[command_name] = previous_command
	package.loaded[reader_name] = previous_reader
	helpers.assert_true(ok, "the projection must complete: " .. tostring(err))
	return statements
end

--- Whether any statement selects from the given table.
--- @param statements table
--- @param table_name string
--- @return boolean
local function queried(statements, table_name)
	for _, sql in ipairs(statements) do
		-- Anchored on the word boundary so ngram_chars does not answer for
		-- ngram_chars_class, and ngram_words does not answer for
		-- ngram_word_bigrams.
		if sql:find("FROM " .. table_name .. "[^%w_]") or sql:find("FROM " .. table_name .. "$") then
			return true
		end
	end
	return false
end




-- =================================================================
-- =================================================================
-- ======= 1/ Coverage =============================================
-- =================================================================
-- =================================================================

helpers.describe("sqlite reader: which tables it asks for", function()

	helpers.it("queries every character-sequence family, not just single characters", function()
		local statements = with_stubbed_sqlite(function() return "" end, function(reader)
			reader.read_ngrams("/tmp/probe.sqlite", "2026-08-01", "2026-08-06", nil)
		end)

		for _, entry in ipairs(EXPECTED) do
			helpers.assert_true(queried(statements, entry.table_name),
				"'" .. entry.table_name .. "' was never queried — the dashboard would "
					.. "hand back an empty map for code '" .. entry.code .. "' whatever "
					.. "the database holds, and a blank panel looks identical whether "
					.. "the rows were never written or never read")
		end
	end)

	helpers.it("asks for the delay and error columns", function()
		local statements = with_stubbed_sqlite(function() return "" end, function(reader)
			reader.read_ngrams("/tmp/probe.sqlite", nil, nil, nil)
		end)

		local checked = 0
		for _, sql in ipairs(statements) do
			if sql:find("FROM ngram_", 1, true) and not sql:find("ngram_scancodes", 1, true) then
				checked = checked + 1
				helpers.assert_true(sql:find("td", 1, true) ~= nil,
					"without td the cost ranking sorts a column of zeroes while looking "
						.. "entirely functional: " .. sql)
				helpers.assert_true(sql:find("e,", 1, true) ~= nil,
					"and without e the error analysis has no errors: " .. sql)
			end
		end
		helpers.assert_true(checked >= #EXPECTED,
			"every family must be checked, or this passes by not looking")
	end)

	helpers.it("carries the app filter into each family, not only the first", function()
		local statements = with_stubbed_sqlite(function() return "" end, function(reader)
			reader.read_ngrams("/tmp/probe.sqlite", nil, nil, { "firefox" })
		end)

		for _, entry in ipairs(EXPECTED) do
			local found = false
			for _, sql in ipairs(statements) do
				if sql:find("FROM " .. entry.table_name .. "[^%w_]") and sql:find("firefox", 1, true) then
					found = true
				end
			end
			helpers.assert_true(found,
				"'" .. entry.table_name .. "' ignored the selected application — a "
					.. "per-app view that silently widens to every app is worse than "
					.. "an empty one, because the number looks plausible")
		end
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ What comes back ======================================
-- =================================================================
-- =================================================================

helpers.describe("sqlite reader: what the envelope carries", function()

	helpers.it("lands each family's rows under its own code", function()
		local result
		with_stubbed_sqlite(function(sql)
			if sql:find("FROM ngram_bigrams", 1, true) then
				return '[{"token":"ab","c":7,"td":840,"e":1,"esrc_json":"{}"}]'
			end
			return ""
		end, function(reader)
			result = reader.read_ngrams("/tmp/probe.sqlite", nil, nil, nil)
		end)

		helpers.assert_not_nil(result.bg.ab, "a bigram row must reach the bigram code")
		helpers.assert_eq(result.bg.ab.c, 7)
		helpers.assert_true(next(result.c) == nil,
			"and must not be folded into the single-character map, which is where "
				.. "every sequence would have landed if the codes were mixed up")
	end)

	helpers.it("keeps the delay total and the error count", function()
		local result
		with_stubbed_sqlite(function(sql)
			if sql:find("FROM ngram_trigrams", 1, true) then
				return '[{"token":"abc","c":4,"td":1200,"e":2,"esrc_json":"{}"}]'
			end
			return ""
		end, function(reader)
			result = reader.read_ngrams("/tmp/probe.sqlite", nil, nil, nil)
		end)

		helpers.assert_eq(result.tg.abc.t, 1200,
			"the writer stores it and the merge dropped it, so 'which sequences cost "
				.. "you the most' ranked by zero")
		helpers.assert_eq(result.tg.abc.e, 2,
			"and the error analysis had no errors to analyse")
	end)

	helpers.it("adds rows from several devices rather than replacing them", function()
		local result
		with_stubbed_sqlite(function(sql)
			if sql:find("FROM ngram_words", 1, true) then
				return '[{"token":"bonjour","c":3,"td":900,"e":0,"esrc_json":"{}"},'
					.. '{"token":"bonjour","c":5,"td":1500,"e":1,"esrc_json":"{}"}]'
			end
			return ""
		end, function(reader)
			result = reader.read_ngrams("/tmp/probe.sqlite", nil, nil, nil)
		end)

		helpers.assert_eq(result.w.bonjour.c, 8,
			"one row per device is the normal case for a synced database; taking the "
				.. "last would report one machine's typing as the whole total")
		helpers.assert_eq(result.w.bonjour.t, 2400)
	end)

	helpers.it("splits today by application across every family", function()
		local result
		with_stubbed_sqlite(function(sql)
			if sql:find("FROM ngram_bigrams", 1, true) and sql:find("app,", 1, true) then
				return '[{"app":"firefox","token":"ab","c":2,"td":200,"e":0,"esrc_json":"{}"}]'
			end
			return ""
		end, function(reader)
			result = reader.read_range_split_today("/tmp/probe.sqlite", nil, nil, nil)
		end)

		helpers.assert_not_nil(result.today.firefox, "today's per-app split must exist")
		helpers.assert_eq(result.today.firefox.bg.ab.c, 2,
			"the split-today path had its own hardcoded ngram_chars, so the live view "
				.. "stayed blank even once the historical one was fixed")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 3/ The per-app-day aggregates ===========================
-- =================================================================
-- =================================================================

helpers.describe("sqlite reader: the daily aggregate tables", function()

	helpers.it("queries all four, not only the totals row", function()
		local statements = with_stubbed_sqlite(function() return "" end, function(reader)
			reader.read_manifest("/tmp/probe.sqlite", "2026-08-01", "2026-08-06", nil)
		end)

		for _, table_name in ipairs({
			"agg_app_day", "agg_app_day_chars_class", "agg_app_day_errors",
			"agg_app_day_hourly", "agg_app_day_hourly_min5",
		}) do
			helpers.assert_true(queried(statements, table_name),
				"'" .. table_name .. "' was never queried — the walk now fills it and "
					.. "nobody reads it, which from the outside is the same blank panel "
					.. "as never having filled it")
		end
	end)

	helpers.it("projects the character breakdown onto the manifest entry", function()
		local manifest
		with_stubbed_sqlite(function(sql)
			if sql:find("FROM agg_app_day_chars_class", 1, true) then
				return '[{"date":"2026-08-06","app":"firefox","letter":120,"digit":8,'
					.. '"punct":15,"space":30,"other":2,'
					.. '"first_min":"09:12","last_min":"18:40"}]'
			end
			return ""
		end, function(reader)
			manifest = reader.read_manifest("/tmp/probe.sqlite", nil, nil, nil)
		end)

		local entry = manifest["2026-08-06"] and manifest["2026-08-06"].firefox
		helpers.assert_not_nil(entry, "the entry must exist even with no totals row")
		helpers.assert_eq(entry.char_letter, 120)
		helpers.assert_eq(entry.first_typed_min, "09:12",
			"the earliest keystroke of the day is what the heatmap labels its axis "
				.. "with, and it was never read on this driver")
	end)

	helpers.it("projects the error analysis under the names the dashboard expects", function()
		local manifest
		with_stubbed_sqlite(function(sql)
			if sql:find("FROM agg_app_day_errors", 1, true) then
				return '[{"date":"2026-08-06","app":"code","bs_total":42,'
					.. '"cascade_count":5,"cascade_max_len":11,'
					.. '"recovery_sum":3200,"recovery_count":16}]'
			end
			return ""
		end, function(reader)
			manifest = reader.read_manifest("/tmp/probe.sqlite", nil, nil, nil)
		end)

		local entry = manifest["2026-08-06"].code
		helpers.assert_eq(entry.bs_total, 42)
		helpers.assert_eq(entry.cascade_count_total, 5,
			"the dashboard reads cascade_count_total, not cascade_count — the same "
				.. "number under the wrong key renders as zero, which is worse than "
				.. "missing because it looks like an answer")
		helpers.assert_eq(entry.recovery_time_sum_ms, 3200)
	end)

	helpers.it("keys the activity histogram by hour and by slot", function()
		local manifest
		with_stubbed_sqlite(function(sql)
			if sql:find("FROM agg_app_day_hourly_min5", 1, true) then
				return '[{"date":"2026-08-06","app":"code","slot":"10:05","c":40,"e":1,"es":0}]'
			end
			if sql:find("FROM agg_app_day_hourly", 1, true) then
				return '[{"date":"2026-08-06","app":"code","hour":"10","c":180,"e":4,"em":2,"es":1}]'
			end
			return ""
		end, function(reader)
			manifest = reader.read_manifest("/tmp/probe.sqlite", nil, nil, nil)
		end)

		local entry = manifest["2026-08-06"].code
		helpers.assert_eq(entry.hourly["10"].c, 180)
		helpers.assert_eq(entry.hourly_min5["10:05"].c, 40,
			"the two histograms are separate panels keyed differently, and reading "
				.. "the fine one into the coarse map would silently halve the timeline")
	end)

end)

