--- tests/unit/modules/keylogger/test_sqlite_writer.lua

--- ==============================================================================
--- MODULE: keylogger.sqlite_writer Unit Tests
--- DESCRIPTION:
--- Verifies the INSERT-builder functions and the initialization guard of the
--- SQLite writer.  All SQLite I/O is routed through the in-memory stub, so no
--- real database file is created during the test run.
---
--- FEATURES & RATIONALE:
--- 1. Builder Correctness: Each builder must embed the device_id and produce a
---    syntactically valid INSERT OR IGNORE statement.
--- 2. Guard Enforcement: Functions called before M.init() must be safe no-ops.
--- 3. No Disk Access: The hs.sqlite3 stub intercepts all open() calls, keeping
---    the tests hermetic.
--- ==============================================================================

local helpers = require("tests.helpers")




-- =====================================
-- =====================================
-- ======= 1/ Module loading ===========
-- =====================================
-- =====================================

-- lib.logger must load first so every subsequent require can resolve it.
package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

local SW = helpers.load_with_stubs("modules.keylogger.sqlite_writer")




-- =============================================
-- =============================================
-- ======= 2/ Module surface invariants =======
-- =============================================
-- =============================================

helpers.describe("sqlite_writer — public surface", function()
	helpers.it("exposes init, open_db, close_db, get_db, build_inserts", function()
		helpers.assert_eq(type(SW.init),         "function")
		helpers.assert_eq(type(SW.open_db),      "function")
		helpers.assert_eq(type(SW.close_db),     "function")
		helpers.assert_eq(type(SW.get_db),       "function")
		helpers.assert_eq(type(SW.build_inserts), "function")
	end)

	helpers.it("get_db returns nil before open_db", function()
		helpers.assert_nil(SW.get_db())
	end)
end)




-- ==============================================
-- ==============================================
-- ======= 3/ Pre-init guard enforcement =======
-- ==============================================
-- ==============================================

helpers.describe("sqlite_writer — pre-init guard", function()
	helpers.it("open_db returns false when called before init", function()
		-- Module is freshly loaded — _initialized is false.
		local result = SW.open_db()
		helpers.assert_eq(result, false)
	end)

	helpers.it("build_inserts returns empty table when called before init", function()
		-- Calling build_inserts before init: _device_id is nil but the function
		-- dispatches to builders which embed it via _sql_str.  The guard only
		-- covers open_db, so build_inserts can still run — just with nil device_id.
		-- We just verify it does not throw.
		local result = SW.build_inserts({ type = "unknown_type" })
		helpers.assert_eq(type(result), "table")
	end)
end)




-- =========================================
-- =========================================
-- ======= 4/ init() validation ============
-- =========================================
-- =========================================

helpers.describe("sqlite_writer — init validation", function()
	helpers.it("init rejects nil deps", function()
		-- Re-load a fresh instance.
		local sw2 = helpers.load_with_stubs("modules.keylogger.sqlite_writer")
		-- init with nil must not throw; get_db remains nil.
		sw2.init(nil)
		helpers.assert_nil(sw2.get_db())
	end)

	helpers.it("init rejects deps missing device_id", function()
		local sw2 = helpers.load_with_stubs("modules.keylogger.sqlite_writer")
		sw2.init({ paths = {}, device_obj = {}, device_id = 42 })  -- device_id not string
		helpers.assert_nil(sw2.get_db())
	end)

	helpers.it("init accepts valid deps and marks initialized", function()
		local sw2 = helpers.load_with_stubs("modules.keylogger.sqlite_writer")
		sw2.init({
			paths      = { sqlite_path = "/tmp/test_db.sqlite" },
			device_obj = {
				device_id      = "test-device-uuid-1234",
				name           = "TestMac",
				os             = "macOS",
				os_version     = "14.0",
				host_signature = "sig",
				created_at     = "2024-01-01 00:00:00",
			},
			device_id  = "test-device-uuid-1234",
		})
		-- open_db would attempt to open the stub SQLite; it should return true.
		local ok = sw2.open_db()
		helpers.assert_eq(ok, true)
	end)
end)




-- ===========================================
-- ===========================================
-- ======= 5/ INSERT builder output ===========
-- ===========================================
-- ===========================================

local DEVICE_ID = "deadbeef-cafe-1234-5678-aabbccddeeff"

local function make_writer()
	local sw = helpers.load_with_stubs("modules.keylogger.sqlite_writer")
	sw.init({
		paths      = { sqlite_path = "/tmp/test_sw.sqlite" },
		device_obj = {
			device_id      = DEVICE_ID,
			name           = "TestMac",
			os             = "macOS",
			os_version     = "14.0",
			host_signature = "sig",
			created_at     = "2024-01-01 00:00:00",
		},
		device_id  = DEVICE_ID,
	})
	return sw
end

helpers.describe("sqlite_writer — build_inserts", function()
	helpers.it("typing entry produces one INSERT string", function()
		local sw = make_writer()
		local stmts = sw.build_inserts({
			type      = "typing",
			timestamp = "2024-01-01 12:00:00.000",
			app       = "Zed",
			text      = "hello",
		})
		helpers.assert_eq(#stmts, 1)
		helpers.assert_true(type(stmts[1]) == "string")
		helpers.assert_true(stmts[1]:find("INSERT OR IGNORE INTO events_typing") ~= nil)
		-- Use plain=true (4th arg) to avoid Lua interpreting DEVICE_ID hyphens as
		-- pattern quantifiers (the '-' in Lua patterns means lazy repeat).
		helpers.assert_true(stmts[1]:find(DEVICE_ID, 1, true) ~= nil)
	end)

	helpers.it("app_switch entry produces one INSERT string", function()
		local sw = make_writer()
		local stmts = sw.build_inserts({
			type        = "app_switch",
			timestamp   = "2024-01-01 12:00:01.000",
			prev_app    = "Zed",
			next_app    = "Terminal",
			duration_ms = 3000,
		})
		helpers.assert_eq(#stmts, 1)
		helpers.assert_true(stmts[1]:find("events_app_switch") ~= nil)
	end)

	helpers.it("shortcut entry produces one INSERT string", function()
		local sw = make_writer()
		local stmts = sw.build_inserts({
			type      = "shortcut",
			timestamp = "2024-01-01 12:00:02.000",
			app       = "Zed",
			key       = "cmd+s",
		})
		helpers.assert_eq(#stmts, 1)
		helpers.assert_true(stmts[1]:find("events_shortcut") ~= nil)
	end)

	helpers.it("hotstring entry produces one INSERT with 'fired' kind", function()
		local sw = make_writer()
		local stmts = sw.build_inserts({
			type        = "hotstring",
			timestamp   = "2024-01-01 12:00:03.000",
			app         = "Zed",
			trigger     = "teh",
			replacement = "the",
			h_type      = "text",
		})
		helpers.assert_eq(#stmts, 1)
		helpers.assert_true(stmts[1]:find("events_hotstring") ~= nil)
		helpers.assert_true(stmts[1]:find("'fired'") ~= nil)
	end)

	helpers.it("llm_accepted entry produces one INSERT with 'accepted' kind", function()
		local sw = make_writer()
		local stmts = sw.build_inserts({
			type      = "llm_accepted",
			timestamp = "2024-01-01 12:00:04.000",
			app       = "Zed",
			context   = "some context",
			prediction = "hello world",
		})
		helpers.assert_eq(#stmts, 1)
		helpers.assert_true(stmts[1]:find("events_llm") ~= nil)
		helpers.assert_true(stmts[1]:find("'accepted'") ~= nil)
	end)

	helpers.it("session_start entry produces one INSERT", function()
		local sw = make_writer()
		local stmts = sw.build_inserts({
			type      = "session_start",
			timestamp = "2024-01-01 09:00:00.000",
		})
		helpers.assert_eq(#stmts, 1)
		helpers.assert_true(stmts[1]:find("events_session") ~= nil)
		helpers.assert_true(stmts[1]:find("'session_start'") ~= nil)
	end)

	helpers.it("unknown type produces empty table", function()
		local sw = make_writer()
		local stmts = sw.build_inserts({ type = "unicorn", timestamp = "2024-01-01 00:00:00.000" })
		helpers.assert_eq(#stmts, 0)
	end)

	helpers.it("event ids increment across successive calls", function()
		local sw = make_writer()
		local base_entry = { type = "shortcut", timestamp = "2024-01-01 12:00:00.000", app = "A", key = "x" }
		local s1 = sw.build_inserts(base_entry)
		local s2 = sw.build_inserts(base_entry)
		-- The event id is embedded as a bare integer in the VALUES list.
		-- Extract the id from each statement and verify s2's id = s1's id + 1.
		local id1 = tonumber(s1[1]:match(", (%d+), '2024"))
		local id2 = tonumber(s2[1]:match(", (%d+), '2024"))
		helpers.assert_true(id1 ~= nil, "id1 must be parseable")
		helpers.assert_true(id2 ~= nil, "id2 must be parseable")
		helpers.assert_eq(id2, id1 + 1)
	end)

	helpers.it("text with single quotes is escaped", function()
		local sw = make_writer()
		local stmts = sw.build_inserts({
			type      = "typing",
			timestamp = "2024-01-01 12:00:00.000",
			app       = "Zed",
			text      = "it's a test",
		})
		-- Escaped apostrophe must appear as '' in the SQL string.
		helpers.assert_true(stmts[1]:find("it''s a test") ~= nil,
			"single quote must be SQL-escaped")
	end)
end)
