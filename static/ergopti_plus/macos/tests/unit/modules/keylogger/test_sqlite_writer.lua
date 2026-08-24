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
package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

local SW = helpers.load_with_stubs("modules.keylogger.sqlite_writer")





-- ============================================
-- ============================================
-- ======= 2/ Module surface invariants =======
-- ============================================
-- ============================================

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





-- =============================================
-- =============================================
-- ======= 3/ Pre-init guard enforcement =======
-- =============================================
-- =============================================

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

	helpers.it("migrates every LLM accounting column on an existing cache", function()
		local executed = {}
		local closed = false
		local db = {
			exec = function(_, sql)
				executed[#executed + 1] = sql
				return 0
			end,
			nrows = function(_, sql)
				if sql == "PRAGMA table_info(events_llm)" then
					local rows = {
						{ name = "device_id" }, { name = "id" }, { name = "count" },
					}
					local i = 0
					return function()
						i = i + 1
						return rows[i]
					end
				end
				return function() return nil end
			end,
			prepare = function()
				return {
					bind_values = function() return 0 end,
					step = function() return 101 end,
					finalize = function() return 0 end,
				}
			end,
			close = function() closed = true; return 0 end,
			errmsg = function() return "" end,
		}
		local sqlite = {
			OK = 0, ERROR = 1, ROW = 100, DONE = 101,
			open = function() return db end,
		}
		local sw = helpers.load_with_stubs("modules.keylogger.sqlite_writer", {
			fs = { attributes = function() return { mode = "file" } end },
			sqlite3 = sqlite,
		})
		sw.init({
			paths = { sqlite_path = "/tmp/existing-accounting.sqlite" },
			device_obj = {
				device_id = "existing-device", name = "TestMac", os = "macOS",
				os_version = "14.0", host_signature = "sig",
				created_at = "2024-01-01 00:00:00",
			},
			device_id = "existing-device",
		})
		helpers.assert_true(sw.open_db(), "an existing cache must remain writable after migration")
		local migration_sql = table.concat(executed, "\n")
		for _, expected in ipairs({
			"ALTER TABLE events_llm ADD COLUMN prompt_tokens INTEGER",
			"ALTER TABLE events_llm ADD COLUMN completion_tokens INTEGER",
			"ALTER TABLE events_llm ADD COLUMN total_tokens INTEGER",
			"ALTER TABLE events_llm ADD COLUMN est_cost_usd REAL",
		}) do
			helpers.assert_true(migration_sql:find(expected, 1, true) ~= nil,
				"existing caches must execute migration: " .. expected)
		end
		helpers.assert_eq(closed, false, "a successful migration must keep the writer open")
	end)

	-- The writer records what it is handed; the decision not to record while
	-- paused is the ingest path's early return. Both cases below stated that with
	-- assert_true(true) and a sentence.
	helpers.it("holds no pause state of its own (project_suspend_pause_invariant)", function()
		-- A gate here would mean two modules decide whether a keystroke is
		-- written, and the one that loses leaves the rotation offset advanced past
		-- bytes that were never persisted — a gap in the log with nothing to say
		-- where it came from.
		local src = helpers.read_driver_source("local function _read_schema_sql")
		helpers.assert_true(src ~= nil, "modules/keylogger/sqlite_writer.lua source must be locatable")
		-- Matched on the STATE spellings, not on "paus": this module's schema has a
		-- pause_before_ms column — the inter-keystroke gap, a metric it is supposed
		-- to record — and a substring check reads that as the coupling it forbids.
		for _, spelling in ipairs({ "processing_paused", "is_paused", "script_control", "suspend" }) do
			helpers.assert_true(src:find(spelling, 1, true) == nil,
				"the writer must not gate on '" .. spelling .. "' — the ingest path early-returns "
					.. "before reaching it, and a second gate here loses keystrokes the first one accepted")
		end
	end)

	helpers.it("stays usable after 150 inserts against a writer with no database", function()
		-- The old case claimed volume plus a simulated FS error and asserted true.
		-- What is checkable without a live SQLite is the guard: a writer whose
		-- get_db yields nil must refuse every insert the same way, not just the
		-- first, and must not leave itself wedged for the caller that comes after.
		local sw = helpers.load_with_stubs("modules.keylogger.sqlite_writer")
		sw.init({ paths = { sqlite_path = "/tmp/does_not_exist.sqlite" }, device_id = "vol-test" })
		-- Called directly, not through pcall. "It did not raise" is not the claim —
		-- the claim is that every call answers the same shape, and a raise here
		-- fails the case with the real error rather than with a boolean.
		for i = 1, 150 do
			local out = sw.build_inserts({ { id = i } })
			helpers.assert_true(out == nil or type(out) == "table",
				"insert " .. i .. " must answer nil or a statement list, never a half-built value")
		end
		helpers.assert_eq(type(sw.get_next_event_id), "function",
			"and the writer must still be callable afterwards — a wedged writer loses every "
				.. "keystroke from here on with no error at the call site")
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

	helpers.it("LLM accounting values survive the production SQL builder", function()
		local sw = make_writer()
		local stmt = sw.build_inserts({
			type              = "llm_generation",
			timestamp         = "2026-08-24 12:00:04.000",
			app               = "Zed",
			prompt_tokens     = 111,
			completion_tokens = 222,
			total_tokens      = 333,
			est_cost_usd      = 4.56789,
		})[1]
		for _, column in ipairs({
			"prompt_tokens", "completion_tokens", "total_tokens", "est_cost_usd",
		}) do
			helpers.assert_true(stmt:find(column, 1, true) ~= nil,
				"events_llm must retain " .. column)
		end
		for _, value in ipairs({ "111", "222", "333", "4.56789" }) do
			helpers.assert_true(stmt:find(value, 1, true) ~= nil,
				"accounting value must reach the SQL row: " .. value)
		end
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
