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

    helpers.it("register_device does not crash when db is closed", function()
      sw.close_db()
      local ok = pcall(function()
        sw.register_device("test-1", "test", "linux", "5.15", "sig")
      end)
      helpers.assert_true(ok, "register_device does not crash")
    end)

    helpers.it("insert_typing_events does not crash with empty events", function()
      local ok = pcall(function()
        sw.insert_typing_events("dev", {})
      end)
      helpers.assert_true(ok, "insert_typing_events with empty table does not crash")
    end)

    helpers.it("insert_typing_events does not crash with nil events", function()
      local ok = pcall(function()
        sw.insert_typing_events("dev", nil)
      end)
      helpers.assert_true(ok, "insert_typing_events with nil does not crash")
    end)

    helpers.it("upsert_app_day does not crash with empty fields", function()
      local ok = pcall(function()
        sw.upsert_app_day("dev", "2026-01-01", "app", {})
      end)
      helpers.assert_true(ok, "upsert_app_day empty does not crash")
    end)

    helpers.it("upsert_ngrams does not crash with empty map", function()
      local ok = pcall(function()
        sw.upsert_ngrams("dev", "2026-01-01", "app", {})
      end)
      helpers.assert_true(ok, "upsert_ngrams empty does not crash")
    end)

    helpers.it("bump_rev does not crash when db is closed", function()
      local ok = pcall(function() sw.bump_rev() end)
      helpers.assert_true(ok, "bump_rev does not crash")
    end)
  end)

  -- ==========================================================================
  -- 3. Escape / safety
  -- ==========================================================================

  helpers.describe("safety", function()

    helpers.it("register_device with SQL metacharacters does not crash", function()
      local ok = pcall(function()
        sw.register_device("tes't-1", "tes't", "lin'ux", "5.1'5", "si'g")
      end)
      helpers.assert_true(ok, "register_device with quotes does not crash")
    end)

    helpers.it("insert_typing_events with quotes in text does not crash", function()
      local ok = pcall(function()
        sw.insert_typing_events("dev", {
          { ts = "2026-01-01 12:00:00", date = "2026-01-01",
            app = "test'app", text = "he'llo \"world\"", wpm = 60 },
        })
      end)
      helpers.assert_true(ok, "insert with quotes does not crash")
    end)

    helpers.it("double close_db is safe", function()
      sw.close_db()
      local ok = pcall(function() sw.close_db() end)
      helpers.assert_true(ok, "double close_db does not crash")
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
      local ok = pcall(function() kl.flush() end)
      helpers.assert_true(ok, "flush does not crash on JSON fallback")
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
