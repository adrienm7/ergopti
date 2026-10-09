--- tests/unit/modules/keylogger/test_metrics_instant_open_projection.lua

--- ==============================================================================
--- MODULE: Metrics Instant Open — Paced And Incremental Projection
--- DESCRIPTION:
--- The typing dashboard used to project every n-gram of all time in one
--- synchronous pass on the main thread when it opened (about ten seconds on a
--- months-long history). The paced reader splits that work into one statement
--- per day and table, and the incremental projection re-reads only days after
--- its cached watermark. Both must give exactly what the one-pass read gives.
---
--- FEATURES & RATIONALE:
--- 1. Paced equivalence: day windows add up to the single-window dict.
--- 2. Incremental reuse: an unchanged past reads only today's slice.
--- 3. Invalidation: a changed past (fingerprint) rebuilds from scratch.
--- 4. Extension: a new day is read alone and merged into the cached history.
--- ==============================================================================

local helpers = require("tests.helpers")
local FakeSqlite = require("tests.support.fake_ngram_sqlite")

local TODAY = "2026-09-30"

--- Rows over three past days and today, with shared tokens across days,
--- error-source maps, several apps, shortcuts and keycodes.
local function dataset()
	local tables = {
		ngram_chars = {}, ngram_bigrams = {}, ngram_trigrams = {}, ngram_quadgrams = {},
		ngram_pentagrams = {}, ngram_hexagrams = {}, ngram_heptagrams = {}, ngram_words = {},
		ngram_word_bigrams = {}, ngram_shortcuts = {}, ngram_shortcut_bigrams = {}, ngram_keycodes = {},
	}
	local days = { "2026-09-27", "2026-09-28", "2026-09-29", TODAY }
	for day_index, date in ipairs(days) do
		for _, app in ipairs({ "Code", "Mail" }) do
			for token_index, token in ipairs({ "a", "b", "é", "a\"b" }) do
				local weight = day_index * 10 + token_index
				local esrc = (weight % 3 == 0) and '{"hotstring":1,"none":2}'
					or ((weight % 3 == 1) and '{"llm":2,"typo":1}' or "{}")
				table.insert(tables.ngram_chars, { date = date, app = app, token = token, c = weight,
					td = weight * 100, e = weight % 2, esrc_json = esrc })
				table.insert(tables.ngram_bigrams, { date = date, app = app, token = token .. token, c = weight + 1,
					td = weight * 90, e = 0, esrc_json = "{}" })
				table.insert(tables.ngram_words, { date = date, app = app, token = "mot" .. token_index, c = 1,
					td = 700, e = 0, esrc_json = esrc })
			end
			table.insert(tables.ngram_shortcuts, { date = date, app = app, token = "cmd+c", c = day_index })
			table.insert(tables.ngram_keycodes, { date = date, app = app, keycode = 12, c = day_index * 3 })
		end
	end
	return tables
end

--- Loads a fresh reader over `sqlite`.
local function load_reader(sqlite)
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["hs.sqlite3"] = nil
	return helpers.load_with_stubs("modules.keylogger.sqlite_reader", { sqlite3 = sqlite })
end

--- A pacer that yields nothing but counts pause checks.
local function counting_pacer()
	local pacer = { pauses = 0 }
	function pacer.pause() pacer.pauses = pacer.pauses + 1 end
	return pacer
end

local function assert_same_dict(expected, actual, label)
	for code, tokens in pairs(expected) do
		for token, item in pairs(tokens) do
			local other = actual[code] and actual[code][token]
			helpers.assert_true(other ~= nil, label .. ": missing " .. code .. "/" .. token)
			for _, field in ipairs({ "c", "t", "e", "hs", "llm", "o" }) do
				helpers.assert_eq(other[field], item[field], label .. ": " .. code .. "/" .. token .. "." .. field)
			end
		end
	end
	for code, tokens in pairs(actual) do
		for token in pairs(tokens) do
			helpers.assert_true(expected[code] and expected[code][token] ~= nil,
				label .. ": unexpected " .. code .. "/" .. token)
		end
	end
end

helpers.describe("metrics-instant-open: paced reader", function()
	helpers.it("reads the all-time history day by day with the one-pass result", function()
		helpers.with_fresh_modules({ "modules.keylogger.sqlite_reader", "infra.logger", "hs.sqlite3" }, function()
			local reader = load_reader(FakeSqlite.new(dataset()))
			local apps = { "Code", "Mail" }
			local one_pass = reader.read_ngrams("/fake/db.sqlite", "2026-09-27", "2026-09-29", apps)
			local pacer = counting_pacer()
			local paced = reader.read_ngrams("/fake/db.sqlite", "2026-09-27", "2026-09-29", apps, pacer)
			assert_same_dict(one_pass, paced, "paced")
			helpers.assert_true(pacer.pauses > 0, "a paced read must offer pause points")
			helpers.assert_eq(paced.sc["cmd+c"].c, 12, "day windows accumulate counts instead of overwriting them")
			helpers.assert_eq(paced.kc["12"].c, 36)
			helpers.assert_true(one_pass.c["a"].hs > 0 and one_pass.c["a"].o > 0,
				"the dataset must exercise the error-source merge")
		end)
	end)

	helpers.it("merges a later window into a cached history exactly", function()
		helpers.with_fresh_modules({ "modules.keylogger.sqlite_reader", "infra.logger", "hs.sqlite3" }, function()
			local reader = load_reader(FakeSqlite.new(dataset()))
			local whole = reader.read_ngrams("/fake/db.sqlite", "2026-09-27", "2026-09-29", nil)
			local merged = reader.read_ngrams("/fake/db.sqlite", "2026-09-27", "2026-09-28", nil)
			reader.merge_ngrams(merged, reader.read_ngrams("/fake/db.sqlite", "2026-09-29", "2026-09-29", nil))
			assert_same_dict(whole, merged, "merged")
		end)
	end)
end)

helpers.describe("metrics-instant-open: incremental projection", function()
	local owners = { "modules.keylogger.sqlite_reader", "infra.logger", "hs.sqlite3", "hs.json",
		"ui.metrics_typing.projection", "infra.paced_json", "json" }

	local function load(tables)
		local sqlite = FakeSqlite.new(tables)
		local reader = load_reader(sqlite)
		package.loaded["infra.paced_json"] = nil
		package.loaded["ui.metrics_typing.projection"] = nil
		local projection = require("ui.metrics_typing.projection")
		return reader, projection, sqlite
	end

	local function historical_reads(sqlite)
		return sqlite.statements.ngram_bigrams or 0
	end

	helpers.it("reuses unchanged past days and reads only today's slice", function()
		helpers.with_fresh_modules(owners, function()
			local reader, projection, sqlite = load(dataset())
			local first = projection.session(reader, "/fake/db.sqlite", TODAY, counting_pacer())
				.range("2026-09-27", TODAY, { "Code", "Mail" })
			local cold_reads = historical_reads(sqlite)
			helpers.assert_true(cold_reads >= 3, "a cold history reads each past day")
			local second = projection.session(reader, "/fake/db.sqlite", TODAY, counting_pacer())
				.range("2026-09-27", TODAY, { "Mail", "Code" })
			helpers.assert_eq(historical_reads(sqlite) - cold_reads, 1,
				"an unchanged past reads only today's per-app slice")
			helpers.assert_eq(second, first, "the reused projection publishes the same payload")
		end)
	end)

	helpers.it("rebuilds from scratch when a past day changes", function()
		helpers.with_fresh_modules(owners, function()
			local tables = dataset()
			local reader, projection, sqlite = load(tables)
			projection.session(reader, "/fake/db.sqlite", TODAY, counting_pacer()).range("2026-09-27", TODAY, nil)
			local before = historical_reads(sqlite)
			-- A late ingest or a foreign device adds typing to a past day
			table.insert(tables.ngram_chars, { date = "2026-09-28", app = "Code", token = "z", c = 5,
				td = 500, e = 0, esrc_json = "{}" })
			table.insert(tables.ngram_bigrams, { date = "2026-09-28", app = "Code", token = "zz", c = 5,
				td = 500, e = 0, esrc_json = "{}" })
			local payload = projection.session(reader, "/fake/db.sqlite", TODAY, counting_pacer())
				.range("2026-09-27", TODAY, nil)
			helpers.assert_true(historical_reads(sqlite) - before >= 4, "every past day is read again")
			helpers.assert_true(payload:find('"zz":', 1, true) ~= nil, "the rebuilt history holds the new row")
		end)
	end)

	helpers.it("extends the cached history by the new day after midnight", function()
		helpers.with_fresh_modules(owners, function()
			local reader, projection, sqlite = load(dataset())
			projection.session(reader, "/fake/db.sqlite", "2026-09-29", counting_pacer()).range("2026-09-27", "2026-09-29", nil)
			local before = historical_reads(sqlite)
			local payload = projection.session(reader, "/fake/db.sqlite", TODAY, counting_pacer())
				.range("2026-09-27", TODAY, nil)
			-- One read of 2026-09-29 for the history, one of today's slice
			helpers.assert_eq(historical_reads(sqlite) - before, 2, "only the day that became past is read")
			local decoded = require("json").decode(payload)
			assert_same_dict(reader.read_ngrams("/fake/db.sqlite", "2026-09-27", "2026-09-29", nil),
				decoded.historical, "extended")
		end)
	end)

	helpers.it("drops every cached history on reset", function()
		helpers.with_fresh_modules(owners, function()
			local reader, projection, sqlite = load(dataset())
			projection.session(reader, "/fake/db.sqlite", TODAY, counting_pacer()).range("2026-09-27", TODAY, nil)
			local before = historical_reads(sqlite)
			projection.reset()
			projection.session(reader, "/fake/db.sqlite", TODAY, counting_pacer()).range("2026-09-27", TODAY, nil)
			helpers.assert_true(historical_reads(sqlite) - before >= 4, "a reset forces a full projection")
		end)
	end)
end)
