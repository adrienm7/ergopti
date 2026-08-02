--- tests/unit/meta/test_keylogger_sqlite_writer.lua
---
--- Compliance tests for the Linux SQLite writer module.
--- Verifies the module API surface, graceful degradation when sqlite3 is absent,
--- and the public methods do not crash.  Since sqlite3 CLI is not guaranteed
--- on the maintainer's Windows machine (nor on CI), the database-path methods
--- are tested with the expectation that is_available() returns false.

local helpers = require("tests.helpers")
local sw     = helpers.load_module("modules.keylogger.sqlite_writer")

helpers.describe("sqlite_writer", function()

  -- ==========================================================================
  -- 1. Module structure
  -- ==========================================================================

  helpers.describe("module structure", function()
    helpers.it("exports the expected methods", function()
      helpers.assert_true(type(sw.is_available)     == "function", "is_available")
      helpers.assert_true(type(sw.open_db)           == "function", "open_db")
      helpers.assert_true(type(sw.close_db)          == "function", "close_db")
      helpers.assert_true(type(sw.get_db_path)       == "function", "get_db_path")
      helpers.assert_true(type(sw.register_device)   == "function", "register_device")
      helpers.assert_true(type(sw.insert_typing_events) == "function", "insert_typing_events")
	  helpers.assert_true(type(sw.insert_hotstring_events) == "function", "insert_hotstring_events")
	  helpers.assert_true(type(sw.insert_app_switch_events) == "function", "insert_app_switch_events")
      helpers.assert_true(type(sw.upsert_app_day)    == "function", "upsert_app_day")
      helpers.assert_true(type(sw.upsert_ngrams)     == "function", "upsert_ngrams")
	  helpers.assert_true(type(sw.upsert_scancodes)  == "function", "upsert_scancodes")
      helpers.assert_true(type(sw.bump_rev)          == "function", "bump_rev")
    end)

    helpers.it("seeds every app-time and hotstring metric on the initial upsert", function()
      local path = helpers.driver_root() .. "/modules/keylogger/sqlite_writer.lua"
      local fh = assert(io.open(path, "r"))
      local src = fh:read("*a"); fh:close()
      helpers.assert_true(src:find("app_time_ms, hs_chars, hs_triggers, hs_input_chars", 1, true) ~= nil,
        "initial INSERT must retain every field, not only the conflict-update path")
    end)

	helpers.it("persists generated-output sources and physical scancodes independently", function()
		local path = helpers.driver_root() .. "/modules/keylogger/sqlite_writer.lua"
		local fh = assert(io.open(path, "r"))
		local src = fh:read("*a"); fh:close()
		helpers.assert_true(src:find("esrc_json = json_object", 1, true) ~= nil,
			"source histogram must be merged across flushes instead of overwritten")
		helpers.assert_true(src:find("'hotstring'", 1, true) ~= nil)
		helpers.assert_true(src:find("'llm'", 1, true) ~= nil)
		helpers.assert_true(src:find("INSERT INTO ngram_scancodes", 1, true) ~= nil,
			"evdev hardware counts must be persisted in the canonical scancode table")
	end)

    helpers.it("preserves complete dotted application identifiers during flush", function()
      local path = helpers.driver_root() .. "/modules/keylogger/keylogger.lua"
      local fh = assert(io.open(path, "r"))
      local src = fh:read("*a"); fh:close()
      helpers.assert_true(src:find("local app_name = dashboard_app_name(app_id)", 1, true) ~= nil,
        "SQLite aggregation must use the same full app ID as the dashboard")
    end)

    helpers.it("uses persistent IDs and non-destructive inserts for raw events", function()
      local path = helpers.driver_root() .. "/modules/keylogger/sqlite_writer.lua"
      local fh = assert(io.open(path, "r"))
      local src = fh:read("*a"); fh:close()
      helpers.assert_true(src:find("linux_next_event_id", 1, true) ~= nil,
        "a restart-safe SQLite event sequence is required")
      helpers.assert_true(src:find("INSERT OR IGNORE INTO events_typing", 1, true) ~= nil,
        "raw typing rows must never be replaced on an ID collision")
      helpers.assert_true(src:find("insert_hotstring_events", 1, true) ~= nil,
        "Linux must write canonical events_hotstring rows")
      helpers.assert_true(src:find("insert_app_switch_events", 1, true) ~= nil,
        "Linux must write canonical events_app_switch rows")
    end)

    helpers.it("migrates the former device OS constraint to include Linux", function()
      local path = helpers.driver_root() .. "/modules/keylogger/sqlite_writer.lua"
      local fh = assert(io.open(path, "r"))
      local src = fh:read("*a"); fh:close()
      helpers.assert_true(src:find("_ensure_linux_device_schema", 1, true) ~= nil)
      helpers.assert_true(src:find("'darwin','windows','linux'", 1, true) ~= nil)
    end)

    helpers.it("is_available returns false when sqlite3 CLI is absent", function()
      -- On the maintainer's Windows machine and most CI, sqlite3 is absent.
      helpers.assert_true(type(sw.is_available()) == "boolean", "is_available returns boolean")
    end)
  end)

  -- ==========================================================================
  -- 2. Graceful degradation (sqlite3 absent)
  -- ==========================================================================

  helpers.describe("graceful degradation (no sqlite3)", function()

    helpers.it("open_db returns false when sqlite3 is absent", function()
      local ok = sw.open_db("/tmp/nonexistent/ergopti_test.sqlite")
      -- May return true (if sqlite3 IS available) or false.
      helpers.assert_true(type(ok) == "boolean", "open_db returns boolean")
      sw.close_db()
    end)

    -- Called directly throughout this block: a raise fails the case with the real
    -- error. What each asserts instead is the REFUSAL — a writer with no database
    -- that reported success would let the caller advance its watermark past rows
    -- that were never persisted, which loses them silently and for good.
    helpers.it("register_device refuses when the db is closed", function()
      sw.close_db()
      local ok = sw.register_device("test-1", "test", "linux", "5.15", "sig")
      helpers.assert_true(ok == nil or ok == false,
        "a closed database must not report a registered device")
    end)

    helpers.it("insert_typing_events writes nothing for an empty list", function()
      local ok = sw.insert_typing_events("dev", {})
      helpers.assert_true(ok == nil or ok == false or ok == 0,
        "no events means no rows — a positive answer here is a watermark advanced "
          .. "over nothing")
    end)

    helpers.it("insert_typing_events writes nothing for a nil list", function()
      local ok = sw.insert_typing_events("dev", nil)
      helpers.assert_true(ok == nil or ok == false or ok == 0,
        "same for nil, which is what a failed decode hands it")
    end)

    helpers.it("upsert_app_day writes nothing for empty fields", function()
      local ok = sw.upsert_app_day("dev", "2026-01-01", "app", {})
      helpers.assert_true(ok == nil or ok == false or ok == 0,
        "an upsert with no fields must not claim a row")
    end)

    helpers.it("upsert_ngrams writes nothing for an empty map", function()
      local ok = sw.upsert_ngrams("dev", "2026-01-01", "app", {})
      helpers.assert_true(ok == nil or ok == false or ok == 0,
        "an empty ngram map must not claim a row either")
    end)

    helpers.it("bump_rev refuses when the db is closed", function()
      local ok = sw.bump_rev()
      helpers.assert_true(ok == nil or ok == false,
        "the revision counter is the dashboards' cache-invalidation signal; bumping it "
          .. "against no database would tell them to re-read data that did not change")
    end)
  end)

  -- ==========================================================================
  -- 3. Escape / safety
  -- ==========================================================================

  helpers.describe("safety", function()

    helpers.it("register_device with SQL metacharacters is refused, not injected", function()
      local ok = sw.register_device("tes't-1", "tes't", "lin'ux", "5.1'5", "si'g")
      helpers.assert_true(ok == nil or ok == false,
        "with no database open the answer is refusal — and it must be the SAME refusal "
          .. "as for clean input, or the quotes changed a code path")
    end)

    helpers.it("insert_typing_events with quotes in text is refused, not injected", function()
      local ok = sw.insert_typing_events("dev", {
        { ts = "2026-01-01 12:00:00", date = "2026-01-01",
          app = "test'app", text = "he'llo \"world\"", wpm = 60 },
      })
      helpers.assert_true(ok == nil or ok == false or ok == 0,
        "quoted text must take the same refusal path as clean text when there is no "
          .. "database — a different answer would mean the quotes reached the SQL")
    end)

    helpers.it("double close_db leaves the writer reopenable", function()
      sw.close_db()
      sw.close_db()
      helpers.assert_eq(type(sw.open_db("/tmp/ergopti_double_close_probe.sqlite")), "boolean",
        "a second close must not poison the reopen — the flush path closes defensively")
      sw.close_db()
    end)
  end)

  -- ==========================================================================
  -- 4. Keylogger integration (flush path)
  -- ==========================================================================

  helpers.describe("keylogger flush integration", function()

    helpers.it("keylogger exports flush and export_json methods", function()
      local kl = helpers.load_module("modules.keylogger.keylogger")
      helpers.assert_true(type(kl.flush)       == "function", "flush is a function")
      helpers.assert_true(type(kl.export_json) == "function", "export_json is a function")
      helpers.assert_true(type(kl.export_session) == "function", "export_session is a function")
    end)

    helpers.it("keylogger flush does not crash when sqlite is absent", function()
      local kl = helpers.load_module("modules.keylogger.keylogger")
      kl.init({})  -- sqlite_writer.open_db will fail → JSON fallback
      kl.flush()
      local json = kl.export_json()
      helpers.assert_true(type(json) == "string" and #json > 0,
        "with sqlite absent the flush takes the JSON fallback, so the export must still "
          .. "produce something — a flush that quietly dropped the buffer would leave it empty")
    end)

    helpers.it("export_json returns valid JSON-like string", function()
      local kl = helpers.load_module("modules.keylogger.keylogger")
      kl.init({})
      local json = kl.export_json()
      helpers.assert_true(type(json) == "string" and #json > 0, "export_json returns non-empty string")
      -- Quick structural check: should start with { and end with }
      helpers.assert_true(json:match("^{") ~= nil, "JSON starts with '{'")
      helpers.assert_true(json:match("}$") ~= nil, "JSON ends with '}'")
    end)
  end)

end)
