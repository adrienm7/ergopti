--- tests/unit/modules/keystats/storage/test_sqlite_reader_projection_readonly.lua

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

package.loaded["tests.support.modules.keystats.storage.sqlite_reader_projection_fixture"] = nil
local Fixture = require("tests.support.modules.keystats.storage.sqlite_reader_projection_fixture")
local helpers, Json, EXPECTED, with_stubbed_sqlite, queried =
	Fixture.helpers, Fixture.Json, Fixture.EXPECTED, Fixture.with_stubbed_sqlite, Fixture.queried




helpers.describe("linux-sqlite-readonly", function()
	for _, method in ipairs({ "read_system_days", "read_manifest", "read_ngrams", "read_range_split_today", "read_user_categories" }) do
		helpers.it("linux-sqlite-readonly: " .. method .. " opens every source through native readonly JSON", function()
			local statements, commands = with_stubbed_sqlite(function() return "[]" end, function(reader)
				local result = reader[method]("/db/metrics.sqlite", "2026-10-03", "2026-10-03", {})
				helpers.assert_type(result, "table")
			end)
			helpers.assert_true(#commands > 0 and #commands == #statements, "the selected public API must actually dispatch every query")
			for _, command in ipairs(commands) do
				helpers.assert_contains(command, "'-readonly'", "projection must refuse creation at SQLite open, before SQL executes")
				helpers.assert_contains(command, "'-json'", "readonly open must retain the real output ABI")
				helpers.assert_contains(command, "'/db/metrics.sqlite'")
			end
		end)
	end
end)

helpers.describe("linux-sqlite-category-projection", function()
	helpers.it("category projection joins all overrides in one readonly command with exact device quoting", function()
		local app, category = "owned ' été app\0tail", "Productivity\r\n\0tail"
		local statements = with_stubbed_sqlite(function()
			return Json.encode({ { app_json = Json.encode(app), score_json = Json.encode("-2"), category_json = Json.encode(category) },
				{ app_json = Json.encode("zero"), score_json = Json.encode("0"), category_json = "null" } })
		end, function(reader)
			local categories = reader.read_user_categories("/db/metrics.sqlite", "local ' device")
			helpers.assert_eq(categories[app], { type = category, score = -2 })
			helpers.assert_eq(categories.zero, { type = "Unknown", score = 0 })
		end)
		helpers.assert_eq(#statements, 1, "Category count cannot multiply CLI requests")
		helpers.assert_contains(statements[1], "owned.device_id = 'local '' device'")
		helpers.assert_contains(statements[1], "LEFT JOIN agg_app_day")
	end)
	helpers.it("category projection distinguishes an accepted empty map from native query refusal", function()
		with_stubbed_sqlite(function() return "[]" end, function(reader)
			helpers.assert_eq(reader.read_user_categories("/db/metrics.sqlite", "local"), {})
		end)
		with_stubbed_sqlite(function() return { body = "[]", status = 1 } end, function(reader)
			helpers.assert_nil(reader.read_user_categories("/db/metrics.sqlite", "local"))
		end)
	end)
	helpers.it("invalid category metadata cannot publish a partially accepted override map", function()
		for _, value in ipairs({ "private-invalid-score", "2\0tail", "1e999" }) do
			with_stubbed_sqlite(function()
				return Json.encode({ { app_json = Json.encode("first"), score_json = Json.encode("1"), category_json = Json.encode("Productivity") },
					{ app_json = Json.encode("second"), score_json = Json.encode(value), category_json = "null" } })
			end, function(reader)
				helpers.assert_nil(reader.read_user_categories("/db/metrics.sqlite", "local"))
			end)
		end
	end)
	-- The manifest read the category raw, and the CLI's JSON mode cuts raw TEXT
	-- at NUL: a saved "row\0tail" reached the dashboard as "row".
	helpers.it("linux-sqlite-manifest-category-nul: the manifest quotes the category before the CLI", function()
		local category = "Updated\r\nrow\0tail"
		local statements = with_stubbed_sqlite(function(sql)
			if sql:find("FROM agg_app_day ", 1, true) then
				return Json.encode({ { date = "2000-01-01", app = "owned", chars = 1, category_json = Json.encode(category) },
					{ date = "2000-01-01", app = "plain", chars = 1, category_json = "null" } })
			end
			return "[]"
		end, function(reader)
			local manifest, complete = reader.read_manifest("/db/metrics.sqlite")
			helpers.assert_eq(manifest["2000-01-01"].owned.category, category, "the complete category reaches the dashboard")
			helpers.assert_eq(manifest["2000-01-01"].plain.category, "Unknown", "no saved category keeps the default")
			helpers.assert_eq(complete, true)
		end)
		local base
		for _, sql in ipairs(statements) do
			if sql:find("FROM agg_app_day ", 1, true) then base = sql end
		end
		helpers.assert_contains(base, "json_quote(MAX(category)) AS category_json")
	end)
	helpers.it("linux-sqlite-manifest-category-nul: an invalid quoted category leaves the manifest incomplete", function()
		with_stubbed_sqlite(function(sql)
			if sql:find("FROM agg_app_day ", 1, true) then
				return Json.encode({ { date = "2000-01-01", app = "owned", chars = 1, category_json = "{not json" } })
			end
			return "[]"
		end, function(reader)
			local manifest, complete = reader.read_manifest("/db/metrics.sqlite")
			helpers.assert_eq(manifest["2000-01-01"].owned.category, "Unknown")
			helpers.assert_eq(complete, false, "a projection that could not read the category is never cached")
		end)
	end)
	-- decode_lossless answers nil for malformed text instead of raising, so a
	-- pcall around it accepted a corrupt category as "no category saved".
	helpers.it("linux-sqlite-manifest-category-nul: a malformed saved category refuses the override map", function()
		with_stubbed_sqlite(function()
			return Json.encode({ { app_json = Json.encode("first"), score_json = Json.encode("1"), category_json = "{not json" } })
		end, function(reader)
			helpers.assert_nil(reader.read_user_categories("/db/metrics.sqlite", "local"))
		end)
	end)
	helpers.it("category projection rejects an absent device before opening SQLite", function()
		local statements = with_stubbed_sqlite(function() error("must not dispatch") end, function(reader)
			helpers.assert_nil(reader.read_user_categories("/db/metrics.sqlite", ""))
		end)
		helpers.assert_eq(#statements, 0)
	end)
end)

helpers.describe("linux-sqlite-calendar-split", function()
	local fixtures = {
		{ name = "ordinary", day = { year = 2026, month = 5, day = 14, hour = 12 }, previous = "2026-05-13" },
		{ name = "midnight", day = { year = 2026, month = 5, day = 14, hour = 0, min = 1 }, previous = "2026-05-13" },
		{ name = "leap", day = { year = 2024, month = 3, day = 1, hour = 12 }, previous = "2024-02-29" },
		{ name = "year", day = { year = 2027, month = 1, day = 1, hour = 12 }, previous = "2026-12-31" },
		{ name = "month", day = { year = 2026, month = 5, day = 1, hour = 12 }, previous = "2026-04-30" },
		{ name = "clock crosses midnight after captured today", day = { year = 2026, month = 12, day = 31, hour = 23, min = 59, sec = 59 }, advance = 2, previous = "2026-12-30" },
	}
	for _, fixture in ipairs(fixtures) do
		helpers.it("linux-sqlite-calendar-split: " .. fixture.name .. " uses the preceding captured calendar day", function()
			local native_date, native_time = os.date, os.time
			local captured = native_time(fixture.day)
			os.date = function(format, timestamp) return native_date(format, timestamp or captured) end
			os.time = function(date) return date and native_time(date) or (captured + (fixture.advance or 0)) end
			local ok, err = xpcall(function()
				local statements = with_stubbed_sqlite(function() return "[]" end, function(reader)
					reader.read_range_split_today("/db/metrics.sqlite")
				end)
				-- The CLI is a declared test double; date normalization delegates
				-- to the runtime's native calendar functions rather than a fake.
				helpers.assert_contains(statements[1], "date <= '" .. fixture.previous .. "'")
			end, debug.traceback)
			os.date, os.time = native_date, native_time
			if not ok then error(err, 0) end
		end)
	end
end)

helpers.describe("sqlite-range-date-boundary", function()
	for _, fixture in ipairs({
		{ name = "unbounded", includes = true, historical = "2026-10-17" },
		{ name = "today exact", first = "2026-10-18", last = "2026-10-18", includes = true, historical = "2026-10-17" },
		{ name = "today lower inclusive", first = "2026-10-18", includes = true, historical = "2026-10-17" },
		{ name = "today upper inclusive", last = "2026-10-18", includes = true, historical = "2026-10-17" },
		{ name = "historical", last = "2026-10-17", includes = false, historical = "2026-10-17" },
		{ name = "future", first = "2026-10-19", includes = false, historical = "2026-10-17" },
		{ name = "invalid SQL bounds ignored", first = "invalid", last = false, includes = true, historical = "2026-10-17" },
	}) do
		helpers.it("(sqlite-range-date-boundary) shared date policy keeps " .. fixture.name, function()
			with_stubbed_sqlite(function() return "[]" end, function(reader)
				local bounds = reader.split_bounds(fixture.first, fixture.last, "2026-10-18")
				helpers.assert_eq(bounds.today, "2026-10-18")
				helpers.assert_eq(bounds.includes_today, fixture.includes)
				helpers.assert_eq(bounds.historical_end, fixture.historical)
			end)
		end)
	end

	for _, fixture in ipairs({
		{ name = "historical day", first = "2020-01-01", last = "2020-01-01" },
		{ name = "future day", first = "2100-01-01", last = "2100-01-01" },
		{ name = "open historical upper bound", last = "2020-01-01" },
		{ name = "open future lower bound", first = "2100-01-01" },
	}) do
		helpers.it("(sqlite-range-date-boundary) " .. fixture.name .. " never queries today's persisted slice", function()
			local result
			local today = os.date("%Y-%m-%d")
			local statements = with_stubbed_sqlite(function(sql)
				if sql:find("date >= '" .. today .. "'", 1, true) then
					return '[{"app":"selected","token_json":"\\\"t\\\"","c":5,"td":0,"e":0,"esrc_json":"{}"}]'
				end
				return "[]"
			end, function(reader)
				result = reader.read_range_split_today("/db/metrics.sqlite", fixture.first, fixture.last, { "selected" })
			end)
			helpers.assert_nil(next(result.today), "Today's rows are outside the inclusive requested interval")
			for _, sql in ipairs(statements) do
				helpers.assert_nil(sql:find("date >= '" .. today .. "'", 1, true), "An excluded slice must not be queried")
			end
		end)
	end
end)

helpers.describe("linux-sqlite-read-receipts", function()
	for _, status in ipairs({ 1, 7, 127, 137, 255 }) do
		helpers.it("linux-sqlite-read-receipts: dashboard rejects valid JSON with status " .. status, function()
			with_stubbed_sqlite(function()
				return { body = '[{"date":"2026-10-03","wifi_changes":42}]', status = status }
			end, function(reader)
				helpers.assert_nil(next(reader.read_system_days("/db/metrics.sqlite", nil, nil)),
					"valid rows cannot hide a failed query receipt")
			end)
		end)
	end

	helpers.it("linux-sqlite-read-receipts: successful dashboard JSON retains real values", function()
		with_stubbed_sqlite(function()
			return { body = '[{"date":"2026-10-03","wifi_changes":42}]', status = 0 }
		end, function(reader)
			local days = reader.read_system_days("/db/metrics.sqlite", nil, nil)
			helpers.assert_eq(days["2026-10-03"].wifi_changes, 42)
		end)
	end)
end)




helpers.describe("sqlite-ngram-text-receipts", function()
	helpers.it("sqlite-ngram-text-receipts: escaped native token bytes remain distinct", function()
		with_stubbed_sqlite(function(sql)
			if not sql:find("FROM ngram_chars", 1, true) then return "[]" end
			local rows = {}
			for index, token in ipairs({ "a", "a\0b", "\0", "été" }) do
				rows[index] = { token_json = Json.encode(token), c = index, td = index * 10,
					e = index, esrc_json = '{}', source_rows = 1 }
			end
			return Json.encode(rows)
		end, function(reader)
			local chars = reader.read_ngrams("/owned/metrics.sqlite").c
			for index, token in ipairs({ "a", "a\0b", "\0", "été" }) do
				helpers.assert_not_nil(chars[token], "native JSON token must retain all original bytes")
				helpers.assert_eq(chars[token].c, index, "distinct tokens cannot merge counters")
				helpers.assert_eq(chars[token].t, index * 10)
			end
		end)
	end)
end)




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
				return '[{"token_json":"\\\"ab\\\"","c":7,"td":840,"e":1,"esrc_json":"{}"}]'
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
				return '[{"token_json":"\\\"abc\\\"","c":4,"td":1200,"e":2,"esrc_json":"{}"}]'
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
				return '[{"token_json":"\\\"bonjour\\\"","c":3,"td":900,"e":0,"esrc_json":"{}"},'
					.. '{"token_json":"\\\"bonjour\\\"","c":5,"td":1500,"e":1,"esrc_json":"{}"}]'
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
				return '[{"app":"firefox","token_json":"\\\"ab\\\"","c":2,"td":200,"e":0,"esrc_json":"{}"}]'
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
			"agg_app_day_buckets", "agg_app_day_burst", "agg_app_day_session",
			"agg_app_day_ergo", "agg_app_day_titles", "agg_app_day_layouts",
			"agg_app_day_kc_hold",
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




-- =================================================================
-- =================================================================
-- ======= 4/ Runs and thresholds ==================================
-- =================================================================
-- =================================================================

helpers.describe("sqlite reader: bursts, sessions and pause buckets", function()

	helpers.it("keys the pause buckets by threshold", function()
		local manifest
		with_stubbed_sqlite(function(sql)
			if sql:find("FROM agg_app_day_buckets", 1, true) then
				return '[{"date":"2026-08-06","app":"code","bucket_ms":2000,'
					.. '"time_sum":45000,"credited":300,"hs_in_t":0,"hs_in_c":0,'
					.. '"llm_in_t":0,"llm_in_c":0}]'
			end
			return ""
		end, function(reader)
			manifest = reader.read_manifest("/tmp/probe.sqlite", nil, nil, nil)
		end)

		local entry = manifest["2026-08-06"].code
		helpers.assert_eq(entry.time_buckets["2000"], 45000,
			"the dropdown reads one threshold; keyed by anything else it finds "
				.. "nothing and shows the unfiltered total instead, which is the one "
				.. "number the control exists to avoid")
		helpers.assert_eq(entry.credited_buckets["2000"], 300)
	end)

	helpers.it("merges two devices' burst histograms instead of picking one", function()
		local manifest
		with_stubbed_sqlite(function(sql)
			if sql:find("FROM agg_app_day_burst", 1, true) then
				return '[{"source_rows":1,"date":"2026-08-06","app":"code","count_total":10,"max_cpm":420.5,'
					.. '"max_chars":88,"inter_count":9,"inter_sum":900,"inter_sumsq":90000,'
					.. '"length_buckets_json":"{\\"20\\":3}"},'
					.. '{"source_rows":1,"date":"2026-08-06","app":"code","count_total":4,"max_cpm":380,'
					.. '"max_chars":40,"inter_count":3,"inter_sum":300,"inter_sumsq":30000,'
					.. '"length_buckets_json":"{\\"20\\":2,\\"50\\":1}"}]'
			end
			return ""
		end, function(reader)
			manifest = reader.read_manifest("/tmp/probe.sqlite", nil, nil, nil)
		end)

		local entry = manifest["2026-08-06"].code
		helpers.assert_eq(entry.burst_count_total, 14)
		helpers.assert_eq(entry.burst_max_chars, 88,
			"the longest burst of the day is a record, not a sum: adding two "
				.. "machines' records would invent one nobody typed")
		helpers.assert_eq(entry.burst_length_buckets["20"], 5,
			"the histograms are merged key by key. Taking one row's blob would "
				.. "silently discard the other machine's bursts while the totals "
				.. "beside it stayed right, which is the hardest kind of wrong to spot.")
	end)

	helpers.it("preserves identical burst blob multiplicity (histogram-source-rows)", function()
		with_stubbed_sqlite(function(sql)
			if sql:find("FROM agg_app_day_burst", 1, true) then
				return '[{"date":"2026-08-06","app":"code","count_total":28,'
					.. '"source_rows":2,"length_buckets_json":"{\\"20\\":3}"}]'
			end
			return ""
		end, function(reader)
			local entry = reader.read_manifest("/tmp/probe.sqlite")["2026-08-06"].code
			helpers.assert_eq(entry.burst_count_total, 28)
			helpers.assert_eq(entry.burst_length_buckets["20"], 6,
				"SQL group multiplicity is independent of the already-summed event count")
		end)
	end)

	helpers.it("accumulates session durations across rows", function()
		local manifest
		with_stubbed_sqlite(function(sql)
			if sql:find("FROM agg_app_day_session", 1, true) then
				return '[{"date":"2026-08-06","app":"code","count_total":2,"longest_ms":600000,'
					.. '"longest_chars":2000,"total_active_ms":900000,'
					.. '"durations_json":"[600000,300000]"}]'
			end
			return ""
		end, function(reader)
			manifest = reader.read_manifest("/tmp/probe.sqlite", nil, nil, nil)
		end)

		local entry = manifest["2026-08-06"].code
		helpers.assert_eq(entry.session_count_total, 2)
		helpers.assert_eq(entry.session_longest_ms, 600000)
		helpers.assert_eq(#entry.session_durations, 2,
			"the durations are what the distribution plot is drawn from; an empty "
				.. "array renders an axis and no bars")
	end)

end)




helpers.describe("sqlite reader: the ergonomics record", function()

	helpers.it("takes the longest streak rather than the sum", function()
		local manifest
		with_stubbed_sqlite(function(sql)
			if sql:find("FROM agg_app_day_ergo", 1, true) then
				return '[{"date":"2026-08-06","app":"code","f_max":4,"h_max":9,'
					.. '"ar_count":0,"focus_sum":0,"focus_count":0}]'
			end
			return ""
		end, function(reader)
			manifest = reader.read_manifest("/tmp/probe.sqlite", nil, nil, nil)
		end)

		local entry = manifest["2026-08-06"].code
		helpers.assert_eq(entry.same_finger_streak_max, 4,
			"the longest same-finger run of the day is a record; adding two "
				.. "machines' records would invent a streak nobody typed")
		helpers.assert_eq(entry.same_hand_streak_max, 9)
	end)

end)




helpers.describe("linux-sqlite-null-boundary", function()

	helpers.it("linux-sqlite-null-boundary: only the tagged null scalar is removed", function()
		local Json = require("json")
		with_stubbed_sqlite(function()
			-- Controlled JSON shape checks are units, not native SQLite output.
			return '[{"date":"2026-10-03","battery_min":[],"battery_max":{},"battery_sum":{"keep":null},"battery_count":0}]'
		end, function(reader)
			local day = reader.read_system_days("/db/metrics.sqlite", nil, nil)["2026-10-03"]
			helpers.assert_true(Json.is_array(day.battery_min), "typed empty array identity was removed")
			helpers.assert_type(day.battery_max, "table", "ordinary empty objects must survive")
			helpers.assert_true(not Json.is_array(day.battery_max))
			helpers.assert_true(Json.is_null(day.battery_sum.keep), "the scalar boundary must not recursively normalize")
			helpers.assert_eq(day.battery_count, 0)
		end)
	end)

	helpers.it("linux-sqlite-null-boundary: nullable system scalars retain absent extrema and zero totals", function()
		with_stubbed_sqlite(function()
			return '[{"date":"2026-10-03","wifi_changes":3,"battery_sum":null,"battery_count":null,"battery_min":null,"battery_max":null}]'
		end, function(reader)
			local day = reader.read_system_days("/db/metrics.sqlite", nil, nil)["2026-10-03"]
			helpers.assert_eq(day.wifi_changes, 3)
			helpers.assert_eq(day.battery_sum, 0)
			helpers.assert_eq(day.battery_count, 0)
			helpers.assert_nil(day.battery_min)
			helpers.assert_nil(day.battery_max)
		end)
	end)

	helpers.it("linux-sqlite-null-boundary: optional manifest minutes stay absent without changing nested JSON text", function()
		local Json = require("json")
		with_stubbed_sqlite(function(sql)
			if sql:find("FROM agg_app_day_chars_class", 1, true) then
				return '[{"date":"2026-10-03","app":"café","letter":3,"first_min":null,"last_min":null}]'
			elseif sql:find("FROM agg_app_day_burst", 1, true) then
				return Json.encode({ { date = "2026-10-03", app = "café", source_rows = 1,
					length_buckets_json = Json.encode({ ["nul\0é"] = 2 }) } })
			end
			return "[]"
		end, function(reader)
			local entry = reader.read_manifest("/db/metrics.sqlite", nil, nil)["2026-10-03"]["café"]
			helpers.assert_eq(entry.char_letter, 3)
			helpers.assert_nil(entry.first_typed_min)
			helpers.assert_nil(entry.last_typed_min)
			helpers.assert_eq(entry.burst_length_buckets["nul\0é"], 2)
			-- The legacy decoder contract belongs to its existing callers.
			helpers.assert_type(Json.decode('{"legacy":null}').legacy, "table")
			helpers.assert_true(Json.is_null(Json.decode_lossless('{"tagged":null}').tagged))
		end)
	end)

end)




helpers.describe("linux-manifest-completion", function()
	for _, body in ipairs({ "", "[]", '[{"date":"2026-10-03","app":"owned","llm_chars":3}]' }) do
		helpers.it("linux-manifest-completion: successful CLI body " .. body .. " acknowledges every projection pass", function()
			with_stubbed_sqlite(function(sql)
				if sql:find("FROM agg_app_day ", 1, true) then return body end
				return "[]"
			end, function(reader)
				local manifest, complete = reader.read_manifest("/db/metrics.sqlite")
				helpers.assert_type(manifest, "table")
				helpers.assert_eq(complete, true)
			end)
		end)
	end
	for _, table_name in ipairs({ "agg_app_day", "agg_app_day_errors", "agg_app_day_session" }) do
		helpers.it("linux-manifest-completion: refusal in " .. table_name .. " cannot acknowledge a partial projection", function()
			with_stubbed_sqlite(function(sql)
				if sql:find("FROM " .. table_name .. "[%s;]") then return { body = "[]", status = 1 } end
				if sql:find("FROM agg_app_day ", 1, true) then return '[{"date":"2026-10-03","app":"owned","llm_chars":3}]' end
				return "[]"
			end, function(reader)
				local manifest, complete = reader.read_manifest("/db/metrics.sqlite")
				helpers.assert_eq(complete, false)
				if table_name ~= "agg_app_day" then helpers.assert_eq(manifest["2026-10-03"].owned.llm_chars, 3) end
			end)
		end)
	end
	helpers.it("linux-manifest-completion: malformed native JSON refuses completion", function()
		with_stubbed_sqlite(function() return "[invalid JSON" end, function(reader)
			local manifest, complete = reader.read_manifest("/db/metrics.sqlite")
			helpers.assert_nil(next(manifest))
			helpers.assert_eq(complete, false)
		end)
	end)
	helpers.it("linux-manifest-completion: invalid path keeps the empty first return and refuses completion", function()
		with_stubbed_sqlite(function() error("invalid path must not spawn") end, function(reader)
			local manifest, complete = reader.read_manifest("")
			helpers.assert_nil(next(manifest))
			helpers.assert_eq(complete, false)
		end)
	end)
end)




helpers.describe("linux-sqlite-layouts-seen", function()
	helpers.it("linux-sqlite-layouts-seen: grouped counts use the canonical shared field without a dead alias", function()
		with_stubbed_sqlite(function(sql)
			if sql:find("FROM agg_app_day_layouts", 1, true) then
				helpers.assert_contains(sql, "SUM(count) AS count")
				helpers.assert_contains(sql, "GROUP BY date, app, layout")
				return Json.encode({
					{ date = "2000-01-01", app = "owned", layout = "qwerty", count = 5 },
					{ date = "2000-01-01", app = "owned", layout = "café'owned", count = 2 },
				})
			end
			return "[]"
		end, function(reader)
			local manifest, complete = reader.read_manifest("/db/metrics.sqlite")
			local entry = manifest["2000-01-01"].owned
			helpers.assert_eq(entry.layouts_seen.qwerty, 5)
			helpers.assert_eq(entry.layouts_seen["café'owned"], 2)
			helpers.assert_nil(entry.layouts)
			helpers.assert_eq(entry.chars, 0)
			helpers.assert_eq(complete, true)
		end)
	end)
	helpers.it("linux-sqlite-layouts-seen: existing date and app filters remain on the grouped metadata query", function()
		local apps = { "owned' app" }
		local statements = with_stubbed_sqlite(function() return "[]" end, function(reader)
			reader.read_manifest("/db/metrics.sqlite", "1999-12-31", "2000-01-01", apps)
		end)
		local matches = 0
		for _, sql in ipairs(statements) do
			if sql:find("FROM agg_app_day_layouts", 1, true) then
				matches = matches + 1
				helpers.assert_contains(sql, "date >= '1999-12-31'")
				helpers.assert_contains(sql, "date <= '2000-01-01'")
				helpers.assert_contains(sql, "app IN ('owned'' app')")
			end
		end
		helpers.assert_eq(matches, 1)
		helpers.assert_eq(apps[1], "owned' app")
	end)
	helpers.it("linux-sqlite-layouts-seen: control apps without layout rows retain absent optional maps", function()
		with_stubbed_sqlite(function(sql)
			if sql:find("FROM agg_app_day ", 1, true) then return '[{"date":"2000-01-01","app":"owned","chars":3}]' end
			return "[]"
		end, function(reader)
			local manifest, complete = reader.read_manifest("/db/metrics.sqlite")
			helpers.assert_eq(manifest["2000-01-01"].owned.chars, 3)
			helpers.assert_nil(manifest["2000-01-01"].owned.layouts_seen)
			helpers.assert_nil(manifest["2000-01-01"].owned.layouts)
			helpers.assert_eq(complete, true)
		end)
	end)
	helpers.it("linux-sqlite-layouts-seen: refused receipt preserves the partial first return", function()
		with_stubbed_sqlite(function(sql)
			if sql:find("FROM agg_app_day_layouts", 1, true) then return { body = "[]", status = 1 } end
			if sql:find("FROM agg_app_day ", 1, true) then return '[{"date":"2000-01-01","app":"owned","chars":3}]' end
			return "[]"
		end, function(reader)
			local manifest, complete = reader.read_manifest("/db/metrics.sqlite")
			helpers.assert_eq(manifest["2000-01-01"].owned.chars, 3)
			helpers.assert_nil(manifest["2000-01-01"].owned.layouts_seen)
			helpers.assert_eq(complete, false)
		end)
	end)
end)




helpers.describe("linux-sqlite-switch-projection", function()
	helpers.it("linux-sqlite-switch-projection: grouped destinations reach the shared map without inventing other totals", function()
		with_stubbed_sqlite(function(sql)
			if sql:find("FROM agg_app_day_switches_to", 1, true) then
				helpers.assert_contains(sql, "SUM(count) AS count")
				helpers.assert_contains(sql, "GROUP BY date, app, app_to")
				return Json.encode({
					{ date = "2026-10-05", app = "owned-source", app_to = "owned-destination", count = 7 },
					{ date = "2026-10-05", app = "owned-source", app_to = "café'owned", count = 2 },
				})
			end
			return "[]"
		end, function(reader)
			local manifest, complete = reader.read_manifest("/db/metrics.sqlite")
			local source = manifest["2026-10-05"]["owned-source"]
			helpers.assert_eq(source.switches_to["owned-destination"], 7)
			helpers.assert_eq(source.switches_to["café'owned"], 2)
			helpers.assert_eq(source.chars, 0)
			helpers.assert_nil(manifest["2026-10-05"]["owned-destination"])
			helpers.assert_eq(complete, true)
		end)
	end)
	helpers.it("linux-sqlite-switch-projection: existing date and source app filters cover the alternate schema keys", function()
		local apps = { "owned' source", "café" }
		local statements = with_stubbed_sqlite(function() return "[]" end, function(reader)
			reader.read_manifest("/db/metrics.sqlite", "2026-10-01", "2026-10-05", apps)
		end)
		local matches = 0
		for _, sql in ipairs(statements) do
			if sql:find("FROM agg_app_day_switches_to", 1, true) then
				matches = matches + 1
				helpers.assert_contains(sql, "app_from AS app")
				helpers.assert_contains(sql, "date >= '2026-10-01'")
				helpers.assert_contains(sql, "date <= '2026-10-05'")
				helpers.assert_contains(sql, "app IN ('owned'' source','café')")
			end
		end
		helpers.assert_eq(matches, 1)
		helpers.assert_eq(#apps, 2)
		helpers.assert_eq(apps[1], "owned' source")
	end)
	helpers.it("linux-sqlite-switch-projection: absent transitions retain optional maps and healthy completion", function()
		with_stubbed_sqlite(function(sql)
			if sql:find("FROM agg_app_day ", 1, true) then
				return '[{"date":"2026-10-05","app":"owned-control","chars":3}]'
			end
			return "[]"
		end, function(reader)
			local manifest, complete = reader.read_manifest("/db/metrics.sqlite")
			helpers.assert_eq(manifest["2026-10-05"]["owned-control"].chars, 3)
			helpers.assert_nil(manifest["2026-10-05"]["owned-control"].switches_to)
			helpers.assert_eq(complete, true)
		end)
	end)
	helpers.it("linux-sqlite-switch-projection: failed destination read refuses complete cache admission", function()
		with_stubbed_sqlite(function(sql)
			if sql:find("FROM agg_app_day_switches_to", 1, true) then return { body = "[]", status = 1 } end
			if sql:find("FROM agg_app_day ", 1, true) then
				return '[{"date":"2026-10-05","app":"owned-control","chars":3}]'
			end
			return "[]"
		end, function(reader)
			local manifest, complete = reader.read_manifest("/db/metrics.sqlite")
			helpers.assert_eq(manifest["2026-10-05"]["owned-control"].chars, 3)
			helpers.assert_nil(manifest["2026-10-05"]["owned-control"].switches_to)
			helpers.assert_eq(complete, false)
		end)
	end)
end)


helpers.describe("linux-sqlite-text-nul", function()
	-- Raw TEXT the sqlite3 CLI's JSON mode would cut at the first NUL byte.
	local TEXT = { app = "Fire\0fox", title = "Doc\0A", layout = "fr\0x", app_to = "Term\0inal" }

	--- Answers like the CLI: json_quote keeps every byte, a raw column is cut at NUL.
	local function cli(sql)
		if sql:find("media", 1, true) then return "[]" end
		local row = { date = "2026-10-21", hour = 9, slot = 3, bucket_ms = 100, keycode = 30, scancode = 30,
			c = 1, count = 1, chars = 1, ms = 5, td = 1, e = 0, source_rows = 1, token_json = '"a"' }
		for column, value in pairs(TEXT) do
			if sql:find("json_quote(" .. column .. ") AS " .. column .. "_json", 1, true) then
				row[column .. "_json"] = '"' .. value:gsub("%z", "\\u0000") .. '"'
			else
				row[column] = value:match("^[^%z]*")
			end
		end
		return Json.encode({ row })
	end

	helpers.it("linux-sqlite-text-nul: app, title, layout and destination keep their bytes past a NUL", function()
		local manifest, complete
		local statements = with_stubbed_sqlite(cli, function(reader)
			manifest, complete = reader.read_manifest("/db/metrics.sqlite", "2026-10-21", "2026-10-21", {})
		end)
		helpers.assert_eq(complete, true)
		local day = manifest["2026-10-21"]
		helpers.assert_nil(day["Fire"], "a NUL-cut application id is a different application")
		local entry = day[TEXT.app]
		helpers.assert_true(entry ~= nil, "the complete application id keys the manifest")
		helpers.assert_true(entry.win_titles[TEXT.title] ~= nil and entry.win_titles["Doc"] == nil)
		helpers.assert_true(entry.layouts_seen[TEXT.layout] ~= nil and entry.layouts_seen["fr"] == nil)
		helpers.assert_true(entry.switches_to[TEXT.app_to] ~= nil and entry.switches_to["Term"] == nil)
		for _, sql in ipairs(statements) do
			helpers.assert_nil(sql:match("SELECT date, app,"), "no projection may carry app as raw TEXT: " .. sql)
		end
	end)

	helpers.it("linux-sqlite-text-nul: today's per-application n-grams keep the complete application id", function()
		local range
		with_stubbed_sqlite(cli, function(reader)
			range = reader.read_range_split_today("/db/metrics.sqlite", "2026-10-21", "2026-10-21", {}, "2026-10-21")
		end)
		helpers.assert_true(range.today[TEXT.app] ~= nil)
		helpers.assert_nil(range.today["Fire"])
		helpers.assert_eq(range.today[TEXT.app].c.a.c, 1)
		helpers.assert_eq(range.today[TEXT.app].sc_kb["30"].c, 1)
	end)

	helpers.it("linux-sqlite-text-nul: a malformed or NULL quoted text refuses the projection instead of guessing", function()
		for _, quoted in ipairs({ "null", '"unterminated', "42" }) do
			local manifest, complete
			with_stubbed_sqlite(function(sql)
				if not sql:find("FROM agg_app_day%s") and not sql:find("FROM agg_app_day GROUP") then return "[]" end
				return Json.encode({ { date = "2026-10-21", chars = 1, app_json = quoted } })
			end, function(reader)
				manifest, complete = reader.read_manifest("/db/metrics.sqlite", "2026-10-21", "2026-10-21", {})
			end)
			helpers.assert_eq(complete, false, quoted)
			helpers.assert_nil(next(manifest), quoted)
		end
	end)
end)


helpers.describe("linux-sqlite-dashboard-keys", function()
	-- The shared metrics page reads `win_titles`, as the Windows and macOS
	-- readers project it; the Linux reader landed the rows under `titles`, so its
	-- window-title panel stayed empty (keystats SQL census, PAR-67).
	helpers.it("linux-sqlite-dashboard-keys: window titles land under win_titles", function()
		local manifest
		with_stubbed_sqlite(function(sql)
			if not sql:find("FROM agg_app_day_titles", 1, true) then return "[]" end
			return Json.encode({ { date = "2026-10-01", app_json = Json.encode("Code"),
				title_json = Json.encode("main.lua"), c = 500, ms = 1200000 } })
		end, function(reader)
			manifest = reader.read_manifest("/db/metrics.sqlite", "2026-10-01", "2026-10-01", {})
		end)
		local entry = manifest["2026-10-01"].Code
		helpers.assert_eq(entry.win_titles["main.lua"], { c = 500, ms = 1200000 })
		helpers.assert_nil(entry.titles, "no second key the page never reads")
	end)
end)


helpers.describe("linux-sqlite-catalogue", function()
	-- The manifest SQL is the shared catalogue's (_shared/data/db/queries.sql) in
	-- the CLI dialect: the reader must issue exactly those renderings, each once,
	-- so a statement retyped here cannot drift from macOS and Windows again.
	local Queries = require("keystats.queries")
	for _, case in ipairs({
		{ label = "unfiltered", where = "" },
		{ label = "filtered", first = "2026-10-01", last = "2026-10-02", apps = { "editor" },
			where = " WHERE date >= '2026-10-01' AND date <= '2026-10-02' AND app IN ('editor')" },
	}) do
		helpers.it("linux-sqlite-catalogue: the " .. case.label .. " manifest issues the catalogue renderings", function()
			local statements = with_stubbed_sqlite(function() return "[]" end, function(reader)
				reader.read_manifest("/db/metrics.sqlite", case.first, case.last, case.apps)
			end)
			local expected = {}
			for _, name in ipairs(Queries.names()) do
				if name:match("^manifest%.") and name ~= "manifest.system_day" then
					expected[#expected + 1] = Queries.render(name, "cli_json", { where = case.where })
				end
			end
			table.sort(expected)
			table.sort(statements)
			helpers.assert_eq(statements, expected)
		end)
	end
end)
