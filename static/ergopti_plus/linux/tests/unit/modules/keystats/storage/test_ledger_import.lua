--- tests/unit/modules/keystats/storage/test_ledger_import.lua

--- ==============================================================================
--- MODULE: Linux Foreign Metrics Ledger Import
--- DESCRIPTION:
--- Linux exported its own ledger but never read the other devices' ones, so a
--- Linux machine syncing the metrics folder showed none of a Mac's or a PC's
--- metrics. These tests import real by_device/<id>/data.sql files into a real
--- store through the sqlite3 CLI: the raw rows must arrive, the aggregates must
--- be rebuilt, the watermark must follow the macOS contract, and no statement
--- outside the ledger grammar may reach the store.
--- ==============================================================================

local helpers = require("tests.helpers")
local it = helpers.it

local HAS_SQLITE = (function()
	local status = os.execute("command -v sqlite3 >/dev/null 2>&1")
	return status == true or status == 0
end)()

local Import = require("modules.keystats.ledger_import")
local Rebuild = require("modules.keystats.ledger_rebuild")
local Digest = require("infra.openssl_digest")
local quote = require("text_utils").shell_quote

local FOREIGN = "0b6f4c1e-3a2d-4f5b-9c8e-1d2e3f4a5b6c"
local LOCAL = "linux-import-host"

local function temp_dir()
	local uv = require("luv")
	return assert(uv.fs_mkdtemp(uv.os_tmpdir() .. "/ergopti-import-XXXXXX"))
end

local function shared_sql(name)
	local handle = assert(io.open(helpers.driver_root() .. "/../_shared/data/db/" .. name, "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

local function schema_sql()
	local handle = assert(io.open(helpers.driver_root() .. "/../_shared/data/db/schema.sql", "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

local function sqlite(db, script)
	local input = os.tmpname()
	local handle = assert(io.open(input, "wb"))
	handle:write(script)
	handle:close()
	local pipe = assert(io.popen("sqlite3 -bail -noheader " .. quote(db) .. " < " .. quote(input) .. " 2>&1; echo \"#$?\""))
	local output = pipe:read("*a")
	pipe:close()
	os.remove(input)
	local body, status = output:match("^(.*)#(%d+)\n$")
	if status ~= "0" then return nil, body end
	return body
end

local function write(path, text, mode)
	local handle = assert(io.open(path, mode or "wb"))
	handle:write(text)
	handle:close()
end

local function scalar(db, sql)
	local output = assert(sqlite(db, sql))
	return (output:gsub("\n$", ""))
end

--- A store, a metrics folder holding one foreign device, and its importer.
local function fixture(options)
	options = options or {}
	local dir = temp_dir()
	local db = dir .. "/metrics.sqlite"
	local schema = schema_sql()
	assert(sqlite(db, ".output /dev/null\n" .. schema))
	if options.purge then
		assert(sqlite(db, shared_sql("media_schema.sql") .. "\n" .. shared_sql("purge_schema.sql")))
	end
	local folder = dir .. "/metrics/by_device/" .. FOREIGN
	assert(os.execute("mkdir -p " .. quote(folder)))
	write(folder .. "/device.json", string.format(
		'{"device_id":"%s","name":"Mac","os":"%s","os_version":"26.1","host_signature":"sig","created_at":"2026-11-01 08:00:00.000","schema_version":1}\n',
		FOREIGN, options.os or "darwin"))
	local store = {}
	function store.query_rows(sql)
		local output = sqlite(db, sql)
		if output == nil then return nil end
		local lines = {}
		for line in output:gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
		return lines
	end
	function store.exec_sql(sql) return sqlite(db, sql) ~= nil end
	local warnings = {}
	local rebuild_calls = 0
	local importer = Import.new({
		metrics_dir = dir .. "/metrics", local_device_id = LOCAL, schema = schema, store = store,
		fs = Import.native_ports(), digest_stream = Digest.stream,
		rebuild = function(device_id)
			rebuild_calls = rebuild_calls + 1
			if options.rebuild_fails and rebuild_calls == 1 then error("simulated rebuild failure") end
			return Rebuild.render({ store = store, device_id = device_id, schema = schema,
				decrypt = function(value) return value end,
				statement = require("modules.keystats.sqlite_writer").derived_statement })
		end,
		now_ts = function() return "2026-11-06 10:00:00.000" end,
		logger = { info = function() end, debug = function() end,
			warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end },
	})
	return { dir = dir, db = db, ledger = folder .. "/data.sql", importer = importer, warnings = warnings }
end

local HEADER = "-- ergopti metrics — device " .. FOREIGN .. " — schema_version 1\n"
	.. "-- This file is APPEND-ONLY. Do not edit by hand.\nPRAGMA foreign_keys = OFF;\n"

local function batch(...)
	return "\n-- === ingest batch 2026-11-06 09:00:00 (offset 0 -> 1, 1 entry(ies)) ===\nBEGIN TRANSACTION;\n"
		.. table.concat({ ... }, "\n") .. "\nCOMMIT;\n"
end

local function typing(id, events_json, device)
	return string.format("INSERT OR IGNORE INTO events_typing (device_id, id, ts, date, app, app_category, title, url, "
		.. "field_role, layout, document_path, is_fullscreen, in_meeting, mouse_clicks, mouse_scrolls, mouse_distance_px, "
		.. "pause_before_ms, battery_level, audio_volume, wpm, text, rich_text, events_json) VALUES ('%s', %d, "
		.. "'2026-11-05 09:15:00.000', '2026-11-05', 'Safari', NULL, 'Docs', '', '', 'macos-azerty', '', 0, 0, 2, 0, 40, "
		.. "0, 0, 0, 42.5, 'it''s', '', '%s');", device or FOREIGN, id, events_json)
end

local EVENTS = '[["h",0,{}],["e",120,{}],["l",130,{}],["l",110,{}],["o",125,{}],[" ",140,{}]]'

local function drain(f)
	for _ = 1, 50 do
		local status = f.importer:step()
		if status == "idle" then return end
	end
	error("the importer never caught up")
end

local function sha_of(path)
	local handle = assert(io.open(path, "rb"))
	local bytes = handle:read("*a")
	handle:close()
	return Digest.sha256(bytes), #bytes
end

helpers.describe("Linux foreign metrics ledger import", function()
	it("linux-import-admit: literals of every exported form pass, re-rendered unchanged", function()
		local columns = Import.raw_columns(schema_sql())
		local text = "-- a comment with ' and COMMIT;\nBEGIN TRANSACTION;\n"
			.. "INSERT OR IGNORE INTO events_system (device_id, id, ts, date, action, metadata_json) VALUES ('d', 7, "
			.. "'2026-11-05 10:00:00', '2026-11-05', 'passive_period', CAST(X'7B7D00' AS TEXT));\n"
			.. "INSERT OR IGNORE INTO events_av (device_id, id, ts, date, kind, app, meta_json) VALUES ('d', 8, 'x\n-- y', "
			.. "'2026-11-05', 'k', '', NULL);\nCOMMIT;\n"
		local statements, reason = Import.admit(text, "d", columns)
		helpers.assert_eq(reason, nil)
		helpers.assert_eq(#statements, 2)
		helpers.assert_true(statements[1]:find("CAST(X'7B7D00' AS TEXT)", 1, true) ~= nil)
		helpers.assert_true(statements[2]:find("'x\n-- y'", 1, true) ~= nil)
		helpers.assert_eq(Import.last_complete_batch(text), #text)
		helpers.assert_eq(Import.last_complete_batch(text:sub(1, -3)), 0)
	end)

	-- Every driver writes a CR or a NUL in text as a char() concatenation
	-- (_shared/lua/sqlite/literal.lua, Windows SQLite_Q). The importer read only
	-- plain literals, refused such a statement and retried the same batch on
	-- every tick: that device's ledger was stuck for good (KML-001,
	-- linux-import-control-bytes).
	it("linux-import-control-bytes: a CR or NUL written as char() passes, as its exact bytes", function()
		local columns = Import.raw_columns(schema_sql())
		local Literal = require("sqlite.literal")
		local row = "INSERT OR IGNORE INTO events_av (device_id, id, ts, date, kind, app, meta_json) VALUES ('d', %d, "
			.. "'%s', '2026-11-05', 'k', '', NULL);\n"
		local text = "BEGIN TRANSACTION;\n" .. string.format(row, 1, Literal.escape("l1\r\nl2"))
			.. string.format(row, 2, Literal.escape("a\0b'c")) .. string.format(row, 3, "x'||char(13)||'") .. "COMMIT;\n"
		local statements, reason = Import.admit(text, "d", columns)
		helpers.assert_eq(reason, nil)
		helpers.assert_eq(#statements, 3)
		helpers.assert_true(statements[1]:find("CAST(X'6C310D0A6C32' AS TEXT)", 1, true) ~= nil, "CR LF kept")
		helpers.assert_true(statements[2]:find("CAST(X'6100622763' AS TEXT)", 1, true) ~= nil, "NUL and quote kept")
		helpers.assert_true(statements[3]:find("CAST(X'780D' AS TEXT)", 1, true) ~= nil, "a trailing CR")
		for _, hostile in ipairs({ "a'||char(65)||'b", "a'||lower('B')||'", "a'||char(13)", "a'||(SELECT 1)||'" }) do
			local refused = Import.admit("BEGIN TRANSACTION;\n" .. string.format(row, 4, hostile) .. "COMMIT;\n", "d", columns)
			helpers.assert_nil(refused, "only char(0) and char(13) between literals: " .. hostile)
		end
	end)

	it("linux-import-refusal: subqueries, ATTACH, functions, other devices and unknown tables never pass", function()
		local columns = Import.raw_columns(schema_sql())
		local row = "INSERT OR IGNORE INTO events_system (device_id, id, ts, date, action, metadata_json) VALUES (%s);"
		for _, hostile in ipairs({
			"ATTACH DATABASE '/tmp/x' AS x;",
			"DELETE FROM agg_app_day;",
			string.format(row, "'d', 1, (SELECT ts FROM meta), 'd', 'a', NULL"),
			string.format(row, "'d', 1, load_extension('x'), 'd', 'a', NULL"),
			string.format(row, "'other', 1, 't', 'd', 'a', NULL"),
			string.format(row, "'d', 1.5, 't', 'd', 'a', NULL"),
			"INSERT OR IGNORE INTO meta (device_id, id) VALUES ('d', 1);",
			"INSERT OR IGNORE INTO events_system (device_id, id, rowid) VALUES ('d', 1, 2);",
			string.format(row, "'d', 1, 't', 'd', 'a', NULL); DROP TABLE meta; --"),
		}) do
			local statements = Import.admit("BEGIN TRANSACTION;\n" .. hostile .. "\nCOMMIT;\n", "d", columns)
			helpers.assert_eq(statements, nil, hostile)
		end
	end)

	if not HAS_SQLITE then return end

	it("linux-import-roundtrip: a foreign ledger lands raw, rebuilt and watermarked", function()
		local f = fixture()
		write(f.ledger, HEADER .. batch(typing(1, EVENTS),
			"INSERT OR IGNORE INTO events_app_switch (device_id, id, ts, date, prev_app, next_app, duration_ms) VALUES ('"
				.. FOREIGN .. "', 2, '2026-11-05 09:20:00.000', '2026-11-05', 'Safari', 'Mail', 60000);",
			"INSERT OR IGNORE INTO events_system (device_id, id, ts, date, action, metadata_json) VALUES ('"
				.. FOREIGN .. "', 3, '2026-11-05 12:00:00.000', '2026-11-05', 'passive_period', '{\"kind\":\"sleep\",\"duration_ms\":5000}');",
			"INSERT OR IGNORE INTO events_system (device_id, id, ts, date, action, metadata_json) VALUES ('"
				.. FOREIGN .. "', 4, '2026-11-05 03:10:00.000', '2026-11-05', 'wake', '{}');"))
		drain(f)
		helpers.assert_eq(scalar(f.db, "SELECT count(*) FROM events_typing WHERE device_id='" .. FOREIGN .. "';"), "1")
		helpers.assert_eq(scalar(f.db, "SELECT text FROM events_typing WHERE device_id='" .. FOREIGN .. "';"), "it's")
		helpers.assert_eq(scalar(f.db, "SELECT os FROM devices WHERE device_id='" .. FOREIGN .. "';"), "darwin")
		helpers.assert_eq(scalar(f.db, "SELECT chars FROM agg_app_day WHERE device_id='" .. FOREIGN .. "' AND app='Safari';"), "6")
		helpers.assert_eq(scalar(f.db, "SELECT app_time_ms FROM agg_app_day WHERE device_id='" .. FOREIGN .. "' AND app='Safari';"), "60000")
		helpers.assert_eq(scalar(f.db, "SELECT sleep_ms || ' ' || passive_count FROM agg_system_day WHERE device_id='" .. FOREIGN .. "';"), "5000 1")
		helpers.assert_eq(scalar(f.db, "SELECT night_wake_count FROM agg_system_day WHERE device_id='" .. FOREIGN .. "';"), "1")
		helpers.assert_eq(scalar(f.db, "SELECT count(*) FROM agg_app_day_hourly WHERE device_id='" .. FOREIGN .. "' AND hour='09';") ~= "0", true)
		local digest, size = sha_of(f.ledger)
		helpers.assert_eq(scalar(f.db, "SELECT imported_data_sql_size || ' ' || imported_data_sql_sha256 FROM devices WHERE device_id='"
			.. FOREIGN .. "';"), size .. " " .. digest)
		helpers.assert_eq(scalar(f.db, "SELECT count(*) FROM meta WHERE key LIKE 'linux_ledger_import_pending:%';"), "0")
	end)

	-- Windows records its Wi-Fi changes as events_network network_change rows
	-- and counts the connectivity and SSID transitions among them
	-- (keystats_reader_db.ahk "wifi-day"); the Linux rebuild read only
	-- events_system wifi_change, so an imported Windows device showed none
	-- (KML-002, linux-import-wifi-changes).
	it("linux-import-wifi-changes: a foreign device's network_change transitions are its Wi-Fi changes", function()
		local f = fixture()
		local function change(id, meta)
			return "INSERT OR IGNORE INTO events_network (device_id, id, ts, date, kind, app, meta_json) VALUES ('"
				.. FOREIGN .. "', " .. id .. ", '2026-11-05 09:0" .. id .. ":00.000', '2026-11-05', 'network_change', 'Code', '"
				.. meta .. "');"
		end
		write(f.ledger, HEADER .. batch(typing(1, EVENTS),
			change(2, '{"connection_state":"connected"}'),
			change(3, '{"connection_state":"disconnected","prev_connection_state":"connected"}'),
			change(4, '{"connection_state":"connected","prev_connection_state":"disconnected"}'),
			change(5, '{"connection_state":"connected","prev_connection_state":"connected","ssid_hash":"b","prev_ssid_hash":"a"}'),
			change(6, '{"connection_state":"connected","prev_connection_state":"connected","ssid_hash":"b","prev_ssid_hash":"b"}'),
			"INSERT OR IGNORE INTO events_system (device_id, id, ts, date, action, metadata_json) VALUES ('"
				.. FOREIGN .. "', 7, '2026-11-05 10:00:00.000', '2026-11-05', 'wifi_change', '{}');"))
		drain(f)
		helpers.assert_eq(scalar(f.db, "SELECT wifi_changes FROM agg_system_day WHERE device_id='" .. FOREIGN .. "';"), "4",
			"a disconnect, a reconnect, an SSID change and the legacy row; no baseline, no signal-only row")
	end)

	-- A Linux sibling stamps ts in UTC and date in its local time: a passive
	-- period at 23:30 in New York is ts 04:30 the next day. The rebuild put the
	-- system row on ts's day, a day later than the sibling counted it (KML-004,
	-- linux-import-system-date).
	it("linux-import-system-date: a system row lands on its own date column", function()
		local f = fixture()
		write(f.ledger, HEADER .. batch(typing(1, EVENTS),
			"INSERT OR IGNORE INTO events_system (device_id, id, ts, date, action, metadata_json) VALUES ('"
				.. FOREIGN .. "', 2, '2026-11-06 04:30:00', '2026-11-05', 'passive_period', '{\"kind\":\"sleep\",\"duration_ms\":5000}');"))
		drain(f)
		helpers.assert_eq(scalar(f.db, "SELECT group_concat(date) FROM agg_system_day WHERE device_id='" .. FOREIGN .. "';"), "2026-11-05")
	end)

	-- KMD-1 (decided by the maintainer on 2026-11-11): a row stores its UTC
	-- instant and the offset it was recorded at; its hour and a night wake are
	-- read in that local time. A Linux row without one held UTC and is read
	-- with this device's current offset; a macOS one held local time.
	local function offset_typing(id, ts, date, offset)
		return string.format("INSERT OR IGNORE INTO events_typing (device_id, id, ts, date, app, app_category, title, url, "
			.. "field_role, layout, document_path, is_fullscreen, in_meeting, mouse_clicks, mouse_scrolls, mouse_distance_px, "
			.. "pause_before_ms, battery_level, audio_volume, wpm, text, rich_text, events_json, utc_offset_min) VALUES ('%s', %d, "
			.. "'%s', '%s', 'Safari', NULL, 'Docs', '', '', 'macos-azerty', '', 0, 0, 2, 0, 40, 0, 0, 0, 42.5, 'it''s', '', '%s', %s);",
			FOREIGN, id, ts, date, EVENTS, offset == nil and "NULL" or tostring(offset))
	end
	local function hours(f)
		return scalar(f.db, "SELECT group_concat(hour) FROM (SELECT DISTINCT hour FROM agg_app_day_hourly WHERE device_id='"
			.. FOREIGN .. "' ORDER BY hour);")
	end

	it("linux-import-utc-offset: an hour and a night wake are read in the local time the row was recorded in", function()
		local f = fixture()
		write(f.ledger, HEADER .. batch(offset_typing(1, "2026-11-05 22:15:00.000", "2026-11-05", 60),
			"INSERT OR IGNORE INTO events_system (device_id, id, ts, date, action, metadata_json, utc_offset_min) VALUES ('"
				.. FOREIGN .. "', 2, '2026-11-05 03:10:00.000', '2026-11-05', 'wake', '{}', 300);"))
		drain(f)
		helpers.assert_eq(hours(f), "23", "22:15 UTC at +01:00 is 23:15 lived")
		helpers.assert_eq(scalar(f.db, "SELECT night_wake_count FROM agg_system_day WHERE device_id='" .. FOREIGN .. "';"), "0",
			"03:10 UTC at +05:00 is an 08:10 wake, no night wake")
	end)

	it("linux-import-utc-offset: an older Linux row is read with this device's offset, an older macOS row as local", function()
		local LocalTime = require("keystats.local_time")
		local linux = fixture({ os = "linux" })
		write(linux.ledger, HEADER .. batch(offset_typing(1, "2026-11-05 09:15:00", "2026-11-05", nil)))
		drain(linux)
		local expected = LocalTime.local_ts("2026-11-05 09:15:00", nil, true, LocalTime.offset_at(os.time())):sub(12, 13)
		helpers.assert_eq(hours(linux), expected, "an older Linux ts is UTC")
		local mac = fixture()
		write(mac.ledger, HEADER .. batch(offset_typing(1, "2026-11-05 09:15:00.000", "2026-11-05", nil)))
		drain(mac)
		helpers.assert_eq(hours(mac), "09", "an older macOS ts is local time")
	end)

	it("linux-import-incremental: only appended complete batches are applied, a torn tail waits", function()
		local f = fixture()
		write(f.ledger, HEADER .. batch(typing(1, EVENTS)))
		drain(f)
		write(f.ledger, batch(typing(2, EVENTS)) .. "\nBEGIN TRANSACTION;\n" .. typing(3, EVENTS), "ab")
		drain(f)
		helpers.assert_eq(scalar(f.db, "SELECT group_concat(id) FROM events_typing WHERE device_id='" .. FOREIGN .. "';"), "1,2")
		helpers.assert_eq(scalar(f.db, "SELECT chars FROM agg_app_day WHERE device_id='" .. FOREIGN .. "';"), "12")
		write(f.ledger, "\nCOMMIT;\n", "ab")
		drain(f)
		helpers.assert_eq(scalar(f.db, "SELECT chars FROM agg_app_day WHERE device_id='" .. FOREIGN .. "';"), "18")
		local digest, size = sha_of(f.ledger)
		helpers.assert_eq(scalar(f.db, "SELECT imported_data_sql_size || ' ' || imported_data_sql_sha256 FROM devices WHERE device_id='"
			.. FOREIGN .. "';"), size .. " " .. digest)
	end)

	it("linux-import-replaced-generation: a prefix whose digest changed is replayed from byte 0", function()
		local f = fixture()
		write(f.ledger, HEADER .. batch(typing(1, EVENTS)))
		drain(f)
		-- A regenerated ledger: same device, a different first batch, longer.
		write(f.ledger, HEADER .. "-- regenerated\n" .. batch(typing(5, EVENTS)) .. batch(typing(6, EVENTS)))
		drain(f)
		helpers.assert_eq(scalar(f.db, "SELECT group_concat(id) FROM events_typing WHERE device_id='" .. FOREIGN .. "';"), "1,5,6")
		local digest = sha_of(f.ledger)
		helpers.assert_eq(scalar(f.db, "SELECT imported_data_sql_sha256 FROM devices WHERE device_id='" .. FOREIGN .. "';"), digest)
	end)

	it("linux-import-hostile-ledger: a refused statement imports nothing and keeps the watermark", function()
		local f = fixture()
		write(f.ledger, HEADER .. batch(typing(1, EVENTS), "DELETE FROM agg_app_day;"))
		drain(f)
		helpers.assert_eq(scalar(f.db, "SELECT count(*) FROM events_typing;"), "0")
		helpers.assert_eq(scalar(f.db, "SELECT count(*) FROM devices WHERE device_id='" .. FOREIGN .. "';"), "0")
		helpers.assert_true(#f.warnings == 1 and f.warnings[1]:find("outside the ledger grammar", 1, true) ~= nil)
		local other = fixture()
		write(other.ledger, HEADER .. batch(typing(1, EVENTS, "someone-else")))
		drain(other)
		helpers.assert_eq(scalar(other.db, "SELECT count(*) FROM events_typing;"), "0")
		-- An OS the devices table does not admit would be dropped by INSERT OR
		-- IGNORE and leave no watermark: the device is refused by name instead.
		local unknown = fixture()
		write(unknown.ledger, HEADER .. batch(typing(1, EVENTS)))
		write(unknown.dir .. "/metrics/by_device/" .. FOREIGN .. "/device.json",
			'{"device_id":"' .. FOREIGN .. '","os":"macos","name":"Mac"}')
		drain(unknown)
		helpers.assert_eq(scalar(unknown.db, "SELECT count(*) FROM events_typing;"), "0")
		helpers.assert_true(unknown.warnings[1]:find("no known OS", 1, true) ~= nil)
	end)

	it("linux-import-pending-rebuild: raw rows without aggregates are rebuilt at the next catch-up", function()
		local f = fixture({ rebuild_fails = true })
		write(f.ledger, HEADER .. batch(typing(1, EVENTS)))
		f.importer:step()
		helpers.assert_eq(scalar(f.db, "SELECT count(*) FROM events_typing;"), "1")
		helpers.assert_eq(scalar(f.db, "SELECT count(*) FROM agg_app_day;"), "0")
		helpers.assert_eq(scalar(f.db, "SELECT count(*) FROM meta WHERE key='linux_ledger_import_pending:" .. FOREIGN .. "';"), "1")
		drain(f)
		helpers.assert_eq(scalar(f.db, "SELECT chars FROM agg_app_day WHERE device_id='" .. FOREIGN .. "';"), "6")
		helpers.assert_eq(scalar(f.db, "SELECT count(*) FROM meta WHERE key LIKE 'linux_ledger_import_pending:%';"), "0")
	end)

	it("linux-import-own-folder: this device's own ledger and unidentified folders are not imported", function()
		local f = fixture()
		local own = f.dir .. "/metrics/by_device/" .. LOCAL
		assert(os.execute("mkdir -p " .. quote(own)))
		write(own .. "/data.sql", HEADER:gsub(FOREIGN, LOCAL) .. batch(typing(1, EVENTS, LOCAL)))
		write(f.ledger, HEADER .. batch(typing(1, EVENTS)))
		write(f.dir .. "/metrics/by_device/" .. FOREIGN .. "/device.json", '{"device_id":"not-this-folder"}')
		drain(f)
		helpers.assert_eq(scalar(f.db, "SELECT count(*) FROM events_typing;"), "0")
	end)

	-- A Purge is a tombstone row in the owning writer's ledger. A sibling's
	-- ledger replayed afterwards must not bring the purged rows back, and a
	-- sibling's tombstone purges this device too, Linux rows compared in UTC.
	local function system_row(device, id, ts, date, action, metadata)
		return string.format("INSERT OR IGNORE INTO events_system (device_id, id, ts, date, action, metadata_json) "
			.. "VALUES ('%s', %d, '%s', '%s', '%s', %s);", device, id, ts, date, action,
			metadata and ("'" .. metadata .. "'") or "NULL")
	end
	local LINUX_DEVICE = "INSERT INTO devices (device_id, name, os, os_version, host_signature, created_at, updated_at) "
		.. "VALUES ('" .. LOCAL .. "', 'host', 'linux', '', '', '', '');"
	local TOMBSTONE_UTC = '{"utc":"2026-11-06 09:00:00"}'

	it("linux-import-purge-no-resurrection: a sibling ledger replayed after a local purge stays purged", function()
		if not HAS_SQLITE then return end
		local f = fixture({ purge = true })
		assert(sqlite(f.db, LINUX_DEVICE .. "\n"
			.. system_row(LOCAL, 1, "2026-11-05 08:00:00", "2026-11-05", "wake")
			.. "\n" .. system_row(LOCAL, 2, "2026-11-06 10:00:00.000", "2026-11-06", "metrics_purge", TOMBSTONE_UTC)))
		helpers.assert_eq(scalar(f.db, "SELECT count(*) FROM events_system WHERE action='wake';"), "0")
		write(f.ledger, HEADER .. batch(typing(1, EVENTS),
			"INSERT OR IGNORE INTO events_app_switch (device_id, id, ts, date, prev_app, next_app, duration_ms) VALUES ('"
				.. FOREIGN .. "', 2, '2026-11-06 11:00:00.000', '2026-11-06', 'Safari', 'Mail', 60000);"))
		drain(f)
		helpers.assert_eq(scalar(f.db, "SELECT count(*) FROM events_typing;"), "0", "the purged sibling row came back")
		helpers.assert_eq(scalar(f.db, "SELECT count(*) FROM agg_app_day WHERE date='2026-11-05';"), "0")
		helpers.assert_eq(scalar(f.db, "SELECT count(*) FROM events_app_switch WHERE device_id='" .. FOREIGN .. "';"), "1",
			"a row after the tombstone must survive")
	end)

	it("linux-import-purge-from-sibling: a sibling's tombstone purges every device, Linux rows in UTC", function()
		if not HAS_SQLITE then return end
		local f = fixture({ purge = true })
		assert(sqlite(f.db, LINUX_DEVICE .. "\n"
			.. system_row(LOCAL, 1, "2026-11-06 08:59:59", "2026-11-06", "wake")
			.. "\n" .. system_row(LOCAL, 2, "2026-11-06 09:00:01", "2026-11-06", "sleep")))
		write(f.ledger, HEADER .. batch(typing(1, EVENTS)))
		drain(f)
		helpers.assert_eq(scalar(f.db, "SELECT count(*) FROM agg_app_day WHERE device_id='" .. FOREIGN .. "';"), "1")
		write(f.ledger, batch(system_row(FOREIGN, 7, "2026-11-06 10:00:00.000", "2026-11-06", "metrics_purge",
			TOMBSTONE_UTC)), "ab")
		drain(f)
		helpers.assert_eq(scalar(f.db, "SELECT count(*) FROM events_typing;"), "0")
		helpers.assert_eq(scalar(f.db, "SELECT count(*) FROM agg_app_day;"), "0")
		helpers.assert_eq(scalar(f.db, "SELECT group_concat(action) FROM events_system WHERE device_id='" .. LOCAL .. "';"),
			"sleep", "a Linux row is compared with the tombstone's UTC instant")
	end)
end)
