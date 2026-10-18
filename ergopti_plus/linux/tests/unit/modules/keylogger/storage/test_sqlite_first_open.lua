--- tests/unit/modules/keylogger/storage/test_sqlite_first_open.lua

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

	helpers.it("native device registration retains existing creation and import metadata", function()
		local writer = helpers.load_module("modules.keylogger.sqlite_writer")
		local dir = os.tmpname()
		os.remove(dir)
		local ok, failure = xpcall(function()
			local opened = writer.open_db(dir .. "/metrics.sqlite")
			if not HAS_SQLITE then
				helpers.assert_eq(opened, false, "without SQLite opening must be refused")
				return
			end
			helpers.assert_true(opened)
			writer.register_device("owned-device", "Original", "linux", "1", "signature")
			helpers.assert_true(writer.exec_sql("UPDATE devices SET created_at='original-created',imported_data_sql_size=37,"
				.. "imported_data_sql_sha256='owned-digest';"))
			writer.register_device("owned-device", "Updated", "linux", "2", "new-signature")
			local rows = assert(writer.query_rows("SELECT name,os_version,host_signature,created_at,imported_data_sql_size,imported_data_sql_sha256 FROM devices;"))
			helpers.assert_eq(rows[1], "Updated|2|new-signature|original-created|37|owned-digest")
		end, debug.traceback)
		writer.close_db()
		os.execute("rm -rf '" .. dir .. "'")
		if not ok then error(failure, 0) end
	end)

	helpers.it("native device registration refuses an update and acknowledges its healthy retry", function()
		local writer = helpers.load_module("modules.keylogger.sqlite_writer")
		local dir = os.tmpname()
		os.remove(dir)
		local ok, failure = xpcall(function()
			local opened = writer.open_db(dir .. "/metrics.sqlite")
			if not HAS_SQLITE then
				helpers.assert_eq(opened, false, "without SQLite opening must be refused")
				return
			end
			helpers.assert_true(opened)
			writer.register_device("owned-device", "Original", "linux", "1", "signature")
			helpers.assert_true(writer.exec_sql("CREATE TRIGGER owned_refusal BEFORE UPDATE ON devices BEGIN SELECT RAISE(FAIL,'owned refusal'); END;"))
			helpers.assert_eq(writer.register_device("owned-device", "Refused", "linux", "2", "new-signature"), false)
			helpers.assert_eq(assert(writer.query_rows("SELECT name,os_version,host_signature FROM devices;"))[1], "Original|1|signature")
			helpers.assert_true(writer.exec_sql("DROP TRIGGER owned_refusal;"))
			helpers.assert_eq(writer.register_device("owned-device", "Updated", "linux", "2", "new-signature"), true)
			helpers.assert_eq(assert(writer.query_rows("SELECT name,os_version,host_signature FROM devices;"))[1], "Updated|2|new-signature")
		end, debug.traceback)
		writer.close_db()
		os.execute("rm -rf '" .. dir .. "'")
		if not ok then error(failure, 0) end
	end)

	helpers.it("native AFTER UPDATE refusal rolls back device fields and trigger writes", function()
		local writer = helpers.load_module("modules.keylogger.sqlite_writer")
		local dir = os.tmpname()
		os.remove(dir)
		local ok, failure = xpcall(function()
			local opened = writer.open_db(dir .. "/metrics.sqlite")
			if not HAS_SQLITE then
				helpers.assert_eq(opened, false, "without SQLite opening must be refused")
				return
			end
			helpers.assert_true(opened)
			helpers.assert_true(writer.register_device("owned-device", "Original", "linux", "1", "signature"))
			local before = table.concat(assert(writer.query_rows("SELECT hex(name),hex(os_version),hex(host_signature),hex(created_at),hex(updated_at) FROM devices;")))
			helpers.assert_true(writer.exec_sql("CREATE TABLE owned_trigger_writes (name TEXT); "
				.. "CREATE TRIGGER owned_after_refusal AFTER UPDATE ON devices BEGIN "
				.. "INSERT INTO owned_trigger_writes VALUES(NEW.name); SELECT RAISE(FAIL,'owned refusal'); END;"))
			helpers.assert_eq(writer.register_device("owned-device", "Refused", "linux", "2", "refused-signature"), false)
			helpers.assert_eq(table.concat(assert(writer.query_rows("SELECT hex(name),hex(os_version),hex(host_signature),hex(created_at),hex(updated_at) FROM devices;"))), before)
			helpers.assert_eq(assert(writer.query_rows("SELECT count(*) FROM owned_trigger_writes;"))[1], "0")
			helpers.assert_true(writer.exec_sql("DROP TRIGGER owned_after_refusal;"))
			helpers.assert_true(writer.register_device("owned-device", "Updated", "linux", "2", "new-signature"))
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

helpers.describe("semantic media: native SQLite storage and dashboard parity", function()
	if not HAS_SQLITE then
		helpers.it("semantic media: SQLite unavailable is an explicit native prerequisite refusal", function()
			local writer = helpers.load_module("modules.keylogger.sqlite_writer")
			helpers.assert_eq(writer.open_db("/tmp/ergopti-media-unavailable.sqlite"), false)
		end)
		return
	end

	local IDS = { "media.play_pause", "media.next_track", "media.previous_track", "media.brightness_up", "media.brightness_down" }
	local function fixture(body)
		local writer = helpers.load_module("modules.keylogger.sqlite_writer")
		local reader = helpers.load_module("modules.keylogger.sqlite_reader")
		local dir = os.tmpname()
		os.remove(dir)
		local path = dir .. "/metrics.sqlite"
		local ok, err = xpcall(function()
			helpers.assert_true(writer.open_db(path), "actual SQLite CLI must acknowledge opening")
			local file = assert(io.open(require("infra.paths").shared("data/db/media_schema.sql"), "r"))
			local schema = assert(file:read("*a"))
			assert(file:close() == true)
			helpers.assert_true(writer.exec_sql(schema), "independent fixture provisions the committed additive schema")
			body(writer, reader, path)
		end, debug.traceback)
		writer.close_db()
		os.execute("rm -rf '" .. dir .. "'")
		if not ok then error(err, 0) end
	end

	local function events()
		local out = {}
		for index, id in ipairs(IDS) do
			for _ = 1, index == 1 and 3 or 1 do
				out[#out + 1] = { action = "physical_media_press", media_id = id,
					capture = "owned-capture", device = "18446744073709551615", app = "Owned App",
					timestamp = "2026-10-15 12:00:00.000" }
			end
			out[#out + 1] = { action = "physical_media_release", media_id = id,
				capture = "owned-capture", device = "18446744073709551615", app = "Owned App",
				timestamp = "2026-10-15 12:00:00.500", hold_ms = ({ 50, 200, 201, 0, 300 })[index] }
		end
		return out
	end

	helpers.it("semantic media: projects independently seeded media without numeric aliases", function()
		fixture(function(writer, reader, path)
			for index, id in ipairs(IDS) do
				helpers.assert_true(writer.exec_sql(string.format(
					"INSERT INTO ngram_media_keys VALUES ('fixture','2026-10-15','Owned App','%s',%d);"
					.. "INSERT INTO agg_app_day_media_hold VALUES ('fixture','2026-10-15','Owned App','%s',200,1,200,1,0);",
					id, index, id)))
			end
			helpers.assert_true(writer.exec_sql("INSERT INTO agg_app_day_kc_hold VALUES ('fixture','2026-10-15','Owned App',122,77,1,77,1,0);"))
			local manifest, complete = reader.read_manifest(path, "2026-10-15", "2026-10-15", { "Owned App" })
			helpers.assert_true(complete, "all native query receipts must be accepted")
			local entry = manifest["2026-10-15"]["Owned App"]
			helpers.assert_eq(type(entry.media_keys), "table", "existing reader must expose the separate semantic bucket")
			for index, id in ipairs(IDS) do
				helpers.assert_eq(entry.media_keys[id], index)
				helpers.assert_eq(entry.media_hold[id].tap, 1)
				helpers.assert_eq(entry.media_hold[id].hold, 0)
			end
			helpers.assert_eq(entry.kc_hold["122"].s, 77, "original numeric/volume identity is unchanged")
			helpers.assert_nil(entry.kc_hold["media.play_pause"])
			helpers.assert_eq(entry.chars, 0, "media is never typed text")
		end)
	end)

	helpers.it("semantic media: reader sums devices and respects dates and applications", function()
		fixture(function(writer, reader, path)
			helpers.assert_true(writer.exec_sql([[
INSERT INTO ngram_media_keys VALUES ('a','2026-10-15','Owned App','media.play_pause',2),('b','2026-10-15','Owned App','media.play_pause',3),('a','2026-10-14','Owned App','media.play_pause',11),('a','2026-10-15','Other App','media.play_pause',17);
INSERT INTO agg_app_day_media_hold VALUES ('a','2026-10-15','Owned App','media.play_pause',100,1,100,1,0),('b','2026-10-15','Owned App','media.play_pause',300,1,300,0,1);
]]))
			local manifest, complete = reader.read_manifest(path, "2026-10-15", "2026-10-15", { "Owned App" })
			helpers.assert_true(complete)
			local entry = manifest["2026-10-15"]["Owned App"]
			helpers.assert_eq(type(entry.media_keys), "table", "filtered media projection must exist")
			helpers.assert_eq(entry.media_keys["media.play_pause"], 5)
			local hold = entry.media_hold["media.play_pause"]
			helpers.assert_eq(hold.s, 400)
			helpers.assert_eq(hold.n, 2)
			helpers.assert_eq(hold.m, 300, "maxima must not be summed across devices")
			helpers.assert_eq(hold.tap, 1)
			helpers.assert_eq(hold.hold, 1)
			helpers.assert_nil(manifest["2026-10-14"])
			helpers.assert_nil(manifest["2026-10-15"]["Other App"])
		end)
	end)

	helpers.it("semantic media: writes raw and derived rows with the shared inclusive threshold", function()
		fixture(function(writer, reader, path)
			helpers.assert_eq(type(writer.insert_media_events), "function", "native media storage port must be enrolled")
			local input = events()
			local before = require("json").encode(input)
			helpers.assert_true(writer.insert_media_events("owned-device", input, 200))
			helpers.assert_eq(require("json").encode(input), before, "writer must not clear or replace caller-owned pending events")
			helpers.assert_eq(table.concat(assert(writer.query_rows("SELECT COUNT(*) FROM events_system;"))), "12")
			helpers.assert_eq(table.concat(assert(writer.query_rows("SELECT SUM(c) FROM ngram_media_keys;"))), "7")
			helpers.assert_eq(table.concat(assert(writer.query_rows("SELECT SUM(count),SUM(tap_count),SUM(hold_count) FROM agg_app_day_media_hold;"))), "5|3|2")
			helpers.assert_eq(table.concat(assert(writer.query_rows("SELECT COUNT(*) FROM ngram_scancodes;"))), "0")
			local manifest, complete = reader.read_manifest(path)
			helpers.assert_true(complete)
			helpers.assert_eq(manifest["2026-10-15"]["Owned App"].media_keys["media.play_pause"], 3)
			writer.close_db()
			helpers.assert_true(writer.open_db(path))
			helpers.assert_eq(table.concat(assert(writer.query_rows("SELECT SUM(c) FROM ngram_media_keys;"))), "7", "reopening must not replay a committed batch")
		end)
	end)

	helpers.it("semantic media: native derived refusal rolls back raw rows and permits an unchanged retry", function()
		fixture(function(writer)
			helpers.assert_eq(type(writer.insert_media_events), "function", "native media port API admission")
			local input = events()
			local before = require("json").encode(input)
			helpers.assert_true(writer.exec_sql("CREATE TRIGGER media_refusal AFTER INSERT ON ngram_media_keys BEGIN SELECT RAISE(FAIL,'owned media refusal'); END;"))
			helpers.assert_eq(writer.insert_media_events("owned-device", input, 200), false)
			helpers.assert_eq(require("json").encode(input), before, "failed native write must retain exact pending data")
			helpers.assert_eq(table.concat(assert(writer.query_rows("SELECT COUNT(*) FROM events_system;"))), "0", "derived refusal must roll back the whole raw batch")
			helpers.assert_eq(table.concat(assert(writer.query_rows("SELECT COUNT(*) FROM ngram_media_keys;"))), "0")
			helpers.assert_true(writer.exec_sql("DROP TRIGGER media_refusal;"))
			helpers.assert_true(writer.insert_media_events("owned-device", input, 200))
			helpers.assert_eq(table.concat(assert(writer.query_rows("SELECT COUNT(*) FROM events_system;"))), "12")
			helpers.assert_eq(table.concat(assert(writer.query_rows("SELECT SUM(c) FROM ngram_media_keys;"))), "7")
		end)
	end)

	helpers.it("semantic media: rebuild is partitioned and malformed raw rows cannot erase good projections", function()
		fixture(function(writer)
			helpers.assert_eq(type(writer.rebuild_media), "function", "native media rebuild API admission")
			helpers.assert_true(writer.insert_media_events("owned-device", events(), 200))
			helpers.assert_true(writer.exec_sql("INSERT INTO ngram_media_keys VALUES ('foreign','2026-10-15','Owned App','media.play_pause',19);"))
			helpers.assert_true(writer.rebuild_media("owned-device", 200))
			helpers.assert_true(writer.rebuild_media("owned-device", 200), "rebuild replay must be idempotent")
			helpers.assert_eq(table.concat(assert(writer.query_rows("SELECT SUM(c) FROM ngram_media_keys WHERE device_id='owned-device';"))), "7")
			helpers.assert_eq(table.concat(assert(writer.query_rows("SELECT SUM(c) FROM ngram_media_keys WHERE device_id='foreign';"))), "19")
			helpers.assert_true(writer.exec_sql("CREATE TRIGGER media_rebuild_refusal AFTER INSERT ON ngram_media_keys BEGIN SELECT RAISE(FAIL,'owned rebuild refusal'); END;"))
			helpers.assert_eq(writer.rebuild_media("owned-device", 200), false)
			helpers.assert_eq(table.concat(assert(writer.query_rows("SELECT SUM(c) FROM ngram_media_keys WHERE device_id='owned-device';"))), "7", "a refused native rebuild must roll back its preceding derived deletion")
			helpers.assert_true(writer.exec_sql("DROP TRIGGER media_rebuild_refusal;"))
			helpers.assert_true(writer.exec_sql([[INSERT INTO events_system(device_id,id,ts,date,action,metadata_json) VALUES ('owned-device',999,'2026-10-15 12:00:00','2026-10-15','physical_media_press','{"capture":"owned","device":"1","app":"Owned App","media_id":"media.unknown"}');]]))
			helpers.assert_eq(writer.rebuild_media("owned-device", 200), false)
			helpers.assert_eq(table.concat(assert(writer.query_rows("SELECT SUM(c) FROM ngram_media_keys WHERE device_id='owned-device';"))), "7", "failed rebuild retains the original admitted projection")
		end)
	end)

	helpers.it("semantic media: rejects fabricated numeric aliases before native ID allocation", function()
		fixture(function(writer)
			helpers.assert_eq(type(writer.insert_media_events), "function", "native media port API admission")
			local before = writer.get_meta("linux_next_event_id")
			for _, invalid in ipairs({ { media_id = "media.unknown" }, { keycode = 164 }, { scancode = 164 }, { device = "collector-uuid" }, { capture = "" } }) do
				local input = events()
				for key, value in pairs(invalid) do input[1][key] = value end
				local ok, accepted = pcall(writer.insert_media_events, "owned-device", input, 200)
				helpers.assert_true(ok, "bad data must become a truthful refusal")
				helpers.assert_eq(accepted, false)
				helpers.assert_eq(writer.get_meta("linux_next_event_id"), before, "invalid data cannot consume native ID authority")
			end
			helpers.assert_eq(table.concat(assert(writer.query_rows("SELECT COUNT(*) FROM events_system;"))), "0")
		end)
	end)

	for _, failure in ipairs({ "close-refusal", "read-throw", "receipt-loss", "diagnostic-noise" }) do
		helpers.it("semantic media: retains commit uncertainty after native " .. failure, function()
			fixture(function(writer, _, path)
				local input = events()
				local before = require("json").encode(input)
				local original = io.popen
				local close_calls = 0
				io.popen = function(command, mode)
					local pipe = original(command, mode)
					if not command:find("ngram_media_keys", 1, true) then return pipe end
					return {
						read = function(_, format)
							local body = pipe:read(format)
							if failure == "read-throw" then error("owned terminal read refusal") end
							if failure == "receipt-loss" then return "missing terminal marker" end
							if failure == "diagnostic-noise" then return "owned unexpected diagnostic\n" .. body end
							return body
						end,
						close = function()
							close_calls = close_calls + 1
							local accepted, kind, status = pipe:close()
							if failure == "close-refusal" then return nil, "owned close refusal" end
							return accepted, kind, status
						end,
					}
				end
				local ok, accepted = pcall(writer.insert_media_events, "owned-device", input, 200)
				io.popen = original
				helpers.assert_true(ok, "uncertain terminal I/O must become a truthful refusal")
				helpers.assert_eq(accepted, false)
				helpers.assert_eq(close_calls, 1)
				helpers.assert_eq(require("json").encode(input), before)
				helpers.assert_eq(writer.close_db(), false, "unknown terminal ownership cannot be acknowledged as clean")
				helpers.assert_eq(writer.open_db(path), false, "unknown COMMIT cannot authorize replacement/replay")
				helpers.assert_eq(writer.insert_media_events("owned-device", input, 200), false)
				helpers.assert_eq(close_calls, 1, "an ambiguously consumed pipe is never closed twice")
				local independent = original("sqlite3 '" .. path .. "' 'SELECT COUNT(*) FROM events_system;'", "r")
				local actual = independent:read("*l")
				assert(independent:close() == true)
				helpers.assert_eq(actual, "12", "actual SQLite COMMIT may precede a lost observer receipt")
			end)
		end)
	end


	for _, failure in ipairs({ "nil", "throw" }) do
		helpers.it("semantic media: reader refuses valid native rows after close " .. failure, function()
			fixture(function(writer, reader, path)
				helpers.assert_true(writer.exec_sql("INSERT INTO ngram_media_keys VALUES ('fixture','2026-10-15','Owned App','media.play_pause',3);"
					.. "INSERT INTO agg_app_day_kc_hold VALUES ('fixture','2026-10-15','Owned App',122,77,1,77,1,0);"))
				local original = io.popen
				local closes = 0
				io.popen = function(command, mode)
					local pipe = original(command, mode)
					if not command:find("ngram_media_keys", 1, true)
						and not command:find("agg_app_day_media_hold", 1, true) then return pipe end
					return {
						read = function(_, format) return pipe:read(format) end,
						close = function()
							closes = closes + 1
							assert(pipe:close() == true)
							if failure == "throw" then error("owned media reader close threw") end
							return nil, "owned media reader close refused"
						end,
					}
				end
				local called, manifest, complete = pcall(reader.read_manifest, path, "2026-10-15", "2026-10-15")
				io.popen = original
				helpers.assert_true(called, "media reader close failure must become an incomplete projection")
				helpers.assert_eq(complete, false, "valid stdout is not native cleanup acknowledgement")
				local entry = manifest["2026-10-15"]["Owned App"]
				helpers.assert_nil(entry.media_keys["media.play_pause"], "unretired media query may not publish rows")
				helpers.assert_eq(entry.kc_hold["122"].s, 77, "old numeric read path remains independent")
				helpers.assert_eq(closes, 1, "first ambiguous pipe blocks further media query acquisition")
				local again, accepted = reader.read_manifest(path, "2026-10-15", "2026-10-15")
				helpers.assert_eq(accepted, false, "retained exact pipe debt cannot qualify a later media cache")
				helpers.assert_nil(again["2026-10-15"]["Owned App"].media_keys["media.play_pause"])
				helpers.assert_eq(closes, 1, "an ambiguous consumed pipe is never closed twice")
			end)
		end)
	end

end)
