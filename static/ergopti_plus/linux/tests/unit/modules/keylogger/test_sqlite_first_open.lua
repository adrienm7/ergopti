--- tests/unit/modules/keylogger/test_sqlite_first_open.lua

--- ==============================================================================
--- MODULE: The Metrics Database On A First Start
--- DESCRIPTION:
--- The schema sets "PRAGMA journal_mode = DELETE", which the sqlite3 CLI
--- answers by printing "delete". The writer read any output as an error, so
--- every first start logged "SQLite error: delete", dropped the database and
--- kept the session's metrics in a JSON file the metrics windows never read.
--- Runs against the real sqlite3 CLI when it is installed (CI installs it).
--- ==============================================================================

local helpers = require("tests.helpers")

local HAS_SQLITE = (function()
	local status = os.execute("command -v sqlite3 >/dev/null 2>&1")
	return status == true or status == 0
end)()

helpers.describe("sqlite_writer: bootstrapping a new database", function()

	helpers.it("opens a fresh database and creates the schema", function()
		local writer = helpers.load_module("modules.keylogger.sqlite_writer")
		local dir = os.tmpname()
		os.remove(dir)
		local path = dir .. "/metrics.sqlite"
		local opened = writer.open_db(path)
		if not HAS_SQLITE then
			helpers.assert_true(not opened, "without sqlite3 the writer refuses, it does not pretend")
			return
		end
		helpers.assert_true(opened, "the first open succeeds")
		helpers.assert_true(writer.is_available())
		local pipe = io.popen("sqlite3 '" .. path .. "' \"SELECT count(*) FROM sqlite_master WHERE type='table';\"")
		local tables = tonumber(pipe:read("*l"))
		pipe:close()
		os.execute("rm -rf '" .. dir .. "'")
		helpers.assert_true(tables and tables > 5, "the schema's tables exist: " .. tostring(tables))
	end)

	helpers.it("reopens the canonical Linux schema without rebuilding the device registry", function()
		local writer = helpers.load_module("modules.keylogger.sqlite_writer")
		local dir = os.tmpname()
		os.remove(dir)
		local path = dir .. "/metrics.sqlite"
		local opened = writer.open_db(path)
		if not HAS_SQLITE then
			helpers.assert_eq(opened, false, "without sqlite3 opening must be refused")
			return
		end
		local ok, failure = xpcall(function()
			helpers.assert_true(opened, "native schema must bootstrap")
			local before = assert(writer.query_rows("PRAGMA schema_version;"))[1]
			writer.close_db()
			helpers.assert_true(writer.open_db(path), "existing Linux schema must reopen")
			local after = assert(writer.query_rows("PRAGMA schema_version;"))[1]
			helpers.assert_eq(after, before, "opening a current registry must not execute schema migrations")
		end, debug.traceback)
		writer.close_db()
		os.execute("rm -rf '" .. dir .. "'")
		if not ok then error(failure, 0) end
	end)

	helpers.it("native event ID reservations retain batches across independent writer instances", function()
		local first = helpers.load_module("modules.keylogger.sqlite_writer")
		local second = helpers.load_module("modules.keylogger.sqlite_writer")
		local dir = os.tmpname()
		os.remove(dir)
		local path = dir .. "/metrics.sqlite"
		local ok, failure = xpcall(function()
			local opened = first.open_db(path)
			if not HAS_SQLITE then
				helpers.assert_eq(opened, false, "without SQLite the native writer must refuse")
				return
			end
			helpers.assert_true(opened)
			helpers.assert_true(second.open_db(path))
			helpers.assert_true(first.insert_typing_events("owned-device", { { app = "owned-app", text = "a" } }))
			helpers.assert_true(second.insert_typing_events("owned-device", { { app = "owned-app", text = "b" } }))
			helpers.assert_true(first.insert_typing_events("owned-device", { { app = "owned-app", text = "c" } }))
			local rows = assert(first.query_rows("SELECT id,text FROM events_typing ORDER BY id;"))
			helpers.assert_eq(table.concat(rows, ","), "1|a,2|b,3|c", "each acknowledged native batch requires its own durable ID")
		end, debug.traceback)
		first.close_db()
		second.close_db()
		os.execute("rm -rf '" .. dir .. "'")
		if not ok then error(failure, 0) end
	end)

	helpers.it("native event ID refusal rolls back a partially changed allocator cursor", function()
		local writer = helpers.load_module("modules.keylogger.sqlite_writer")
		local dir = os.tmpname()
		os.remove(dir)
		local path = dir .. "/metrics.sqlite"
		local ok, failure = xpcall(function()
			local opened = writer.open_db(path)
			if not HAS_SQLITE then
				helpers.assert_eq(opened, false, "without SQLite the native writer must refuse")
				return
			end
			helpers.assert_true(opened)
			helpers.assert_true(writer.insert_typing_events("owned-device", { { app = "owned-app", text = "a" } }))
			local before = writer.get_meta("linux_next_event_id")
			helpers.assert_true(writer.exec_sql("CREATE TRIGGER owned_refusal AFTER UPDATE ON meta "
				.. "WHEN NEW.key='linux_next_event_id' BEGIN SELECT RAISE(FAIL,'owned refusal'); END;"))
			helpers.assert_eq(writer.insert_typing_events("owned-device", { { app = "owned-app", text = "b" } }), false)
			helpers.assert_eq(writer.get_meta("linux_next_event_id"), before, "a refused reservation must roll back the native cursor")
			helpers.assert_true(writer.exec_sql("DROP TRIGGER owned_refusal;"))
			helpers.assert_true(writer.insert_typing_events("owned-device", { { app = "owned-app", text = "b" } }))
			helpers.assert_eq(table.concat(assert(writer.query_rows("SELECT id,text FROM events_typing ORDER BY id;")), ","), "1|a,2|b")
		end, debug.traceback)
		writer.close_db()
		os.execute("rm -rf '" .. dir .. "'")
		if not ok then error(failure, 0) end
	end)

	helpers.it("native event cursor guard refuses malformed metadata without consuming a raw batch", function()
		local writer = helpers.load_module("modules.keylogger.sqlite_writer")
		local dir = os.tmpname()
		os.remove(dir)
		local ok, failure = xpcall(function()
			local opened = writer.open_db(dir .. "/metrics.sqlite")
			if not HAS_SQLITE then
				helpers.assert_eq(opened, false, "without SQLite the native writer must refuse")
				return
			end
			helpers.assert_true(opened)
			for _, cursor in ipairs({ "oops", "0", "-7", "12oops", "9223372036854775807" }) do
				helpers.assert_true(writer.set_meta("linux_next_event_id", cursor))
				helpers.assert_eq(writer.insert_typing_events("owned-device", { { app = "owned-app", text = "a" } }), false)
				helpers.assert_eq(writer.get_meta("linux_next_event_id"), cursor, "refusal must preserve unusable metadata")
			end
			helpers.assert_eq(assert(writer.query_rows("SELECT count(*) FROM events_typing;"))[1], "0")
			helpers.assert_true(writer.set_meta("linux_next_event_id", "00041"))
			helpers.assert_true(writer.insert_typing_events("owned-device", { { app = "owned-app", text = "a" } }))
			helpers.assert_eq(assert(writer.query_rows("SELECT id,text FROM events_typing;"))[1], "41|a")
		end, debug.traceback)
		writer.close_db()
		os.execute("rm -rf '" .. dir .. "'")
		if not ok then error(failure, 0) end
	end)

	helpers.it("native event cursor guard retains the exact boundary and refuses an exhausted range", function()
		local writer = helpers.load_module("modules.keylogger.sqlite_writer")
		local dir = os.tmpname()
		os.remove(dir)
		local ok, failure = xpcall(function()
			local opened = writer.open_db(dir .. "/metrics.sqlite")
			if not HAS_SQLITE then
				helpers.assert_eq(opened, false, "without SQLite the native writer must refuse")
				return
			end
			helpers.assert_true(opened)
			helpers.assert_true(writer.set_meta("linux_next_event_id", "9007199254740989"))
			helpers.assert_true(writer.insert_typing_events("owned-device", { { app = "owned-app", text = "a" }, { app = "owned-app", text = "b" } }))
			helpers.assert_eq(table.concat(assert(writer.query_rows("SELECT id,text FROM events_typing ORDER BY id;")), ","),
				"9007199254740989|a,9007199254740990|b")
			helpers.assert_eq(writer.insert_typing_events("owned-device", { { app = "owned-app", text = "c" } }), false)
			helpers.assert_eq(writer.get_meta("linux_next_event_id"), "9007199254740991")
			helpers.assert_eq(assert(writer.query_rows("SELECT count(*) FROM events_typing;"))[1], "2")
		end, debug.traceback)
		writer.close_db()
		os.execute("rm -rf '" .. dir .. "'")
		if not ok then error(failure, 0) end
	end)

	helpers.it("finds sqlite3 on a system that has no `which`", function()
		-- Arch's base image ships sqlite3 but not `which`; the probe used it and
		-- disabled SQLite there. Any command starting with it fails here.
		local writer = helpers.load_module("modules.keylogger.sqlite_writer")
		local real_execute = os.execute
		os.execute = function(cmd)
			if type(cmd) == "string" and cmd:match("^%s*which%s") then return 127 end
			return real_execute(cmd)
		end
		local dir = os.tmpname()
		os.remove(dir)
		local ok, opened = pcall(writer.open_db, dir .. "/metrics.sqlite")
		os.execute = real_execute
		os.execute("rm -rf '" .. dir .. "'")
		helpers.assert_true(ok, tostring(opened))
		helpers.assert_eq(opened == true, HAS_SQLITE, "sqlite3 is found exactly when it is installed")
	end)

end)
