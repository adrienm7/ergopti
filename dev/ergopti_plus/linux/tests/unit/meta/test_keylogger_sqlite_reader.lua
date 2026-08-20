--- tests/unit/meta/test_keylogger_sqlite_reader.lua
--- Regression coverage for the Linux read-only dashboard projection.

local helpers = require("tests.helpers")
local reader = helpers.load_module("modules.keylogger.sqlite_reader")

helpers.describe("keylogger sqlite_reader", function()
  helpers.it("exports the manifest and split-range projection APIs", function()
    helpers.assert_true(type(reader.read_manifest) == "function")
    helpers.assert_true(type(reader.read_ngrams) == "function")
    helpers.assert_true(type(reader.read_range_split_today) == "function")
  end)

  helpers.it("returns stable empty contracts when SQLite is unavailable", function()
    local manifest = reader.read_manifest("", nil, nil, nil)
    local range = reader.read_range_split_today("", nil, nil, nil)
    helpers.assert_eq(type(manifest), "table")
    helpers.assert_eq(type(range.historical.c), "table")
    helpers.assert_eq(type(range.today), "table")
	helpers.assert_eq(type(range.historical.sc_kb), "table")
  end)

  helpers.it("uses read-only JSON queries and the canonical aggregate tables", function()
    local path = helpers.driver_root() .. "/modules/keylogger/sqlite_reader.lua"
    local fh = assert(io.open(path, "r"))
    local src = fh:read("*a"); fh:close()
    -- The invocation is composed by modules/keylogger/sqlite_command.lua now
    -- (the script travels on stdin instead of through a file in /tmp), so the
    -- assertion follows the mechanism: the reader must still ask for JSON, and
    -- must still go through the audited builder to get it.
    helpers.assert_true(src:find("SqliteCommand.build", 1, true) ~= nil,
      "reader must compose its sqlite3 invocation through the audited builder")
    helpers.assert_true(src:find('flags = { "-json" }', 1, true) ~= nil,
      "reader must request JSON output from sqlite3")
    helpers.assert_true(src:find("FROM agg_app_day", 1, true) ~= nil)
    -- The single-character table used to be the only one named here, in the
    -- source and in the reader alike. It is now reached through the code→table
    -- map, so the assertion follows the map — and covers all nine families
    -- rather than the one that happened to work.
    for _, table_name in ipairs({
      "ngram_chars", "ngram_bigrams", "ngram_trigrams", "ngram_quadgrams",
      "ngram_pentagrams", "ngram_hexagrams", "ngram_heptagrams",
      "ngram_words", "ngram_word_bigrams",
    }) do
      helpers.assert_true(src:find(table_name, 1, true) ~= nil,
        "reader must name '" .. table_name .. "' — eight of these nine were "
          .. "handed to the dashboard as permanently empty maps")
    end
	helpers.assert_true(src:find("FROM ngram_scancodes", 1, true) ~= nil,
	  "reader must expose persisted hardware scancodes to the heatmap")
	helpers.assert_true(src:find("source_count", 1, true) ~= nil,
	  "reader must retain hotstring/LLM provenance instead of dropping esrc_json")
    helpers.assert_true(src:find("GROUP BY date, app", 1, true) ~= nil)
  end)
end)
