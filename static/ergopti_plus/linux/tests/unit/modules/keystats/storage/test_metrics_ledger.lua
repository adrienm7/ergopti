--- tests/unit/modules/keystats/storage/test_metrics_ledger.lua

--- ==============================================================================
--- MODULE: Linux Per-Device Metrics Ledger
--- DESCRIPTION:
--- Linux kept its metrics in one local metrics.sqlite and published no
--- by_device/<id>/data.sql, so a Mac or a PC syncing the metrics folder never
--- saw this device. These tests export a real store through the real sqlite3
--- CLI and the native file ports, then replay the ledger into an empty store:
--- the rows must come back byte for byte, in the canonical framing the macOS
--- scanner and the Windows frame index admit.
--- ==============================================================================

local helpers = require("tests.helpers")
local it = helpers.it

local HAS_SQLITE = (function()
	local status = os.execute("command -v sqlite3 >/dev/null 2>&1")
	return status == true or status == 0
end)()

local Ledger = require("modules.keystats.metrics_ledger")
local Queries = require("keystats.queries")
local quote = require("text_utils").shell_quote

local DEVICE = "linux-ledger-host"

local function temp_dir()
	local uv = require("luv")
	return assert(uv.fs_mkdtemp(uv.os_tmpdir() .. "/ergopti-ledger-XXXXXX"))
end

local function schema_sql()
	local root = helpers.driver_root()
	local handle = assert(io.open(root .. "/../_shared/data/db/schema.sql", "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

--- Runs a script through the real CLI on stdin; returns the output, nil on failure.
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

local function new_store(db)
	assert(sqlite(db, ".output /dev/null\n" .. schema_sql()))
	local store = {}
	function store.query_rows(sql)
		local output = sqlite(db, sql)
		if output == nil then return nil end
		local lines = {}
		for line in output:gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
		return lines
	end
	function store.exec_sql(sql) return sqlite(db, sql) ~= nil end
	function store.get_meta(key)
		local output = sqlite(db, "SELECT hex(value) FROM meta WHERE key='" .. key .. "';")
		local hex = output and output:match("^(%x*)\n")
		if not hex then return nil end
		return (hex:gsub("%x%x", function(pair) return string.char(tonumber(pair, 16)) end))
	end
	return store
end

local function logger()
	return { info = function() end, warn = function() end }
end

local TS = "2026-11-06 10:00:00.000"

--- One row of every raw family, with text that stresses the literal framing.
local function insert_rows(db, first_id, date)
	local tricky = "l'été\nsecond line\0after nul; COMMIT;\n-- === day rollover x -> 2000-01-01 ==="
	local rows = {
		{ "events.typing", { app = "kate", app_category = nil, title = tricky, url = "", field_role = "", layout = "ergopti",
			document_path = "", is_fullscreen = 0, in_meeting = 0, mouse_clicks = 1, mouse_scrolls = 2, mouse_distance_px = 30,
			pause_before_ms = 0, battery_level = 0, audio_volume = 0, wpm = 72.5, text = tricky, rich_text = "",
			events_json = "[[\"a\",0,{\"sk\":30}]]" } },
		{ "events.app_switch", { prev_app = "kate", next_app = "firefox", duration_ms = 1200 } },
		{ "events.window_switch", { app = "kate", prev_title = "a", next_title = "b", duration_ms = 5 } },
		{ "events.shortcut", { app = "kate", key = "ctrl+s" } },
		{ "events.system", { action = "lock", metadata_json = "{\"k\":1}" } },
		{ "events.hotstring", { app = "kate", kind = "fired", trigger = "btw", replacement = "by the way", h_type = "user",
			net_saved_chars = 7 } },
		{ "events.session", { kind = "session_start", duration_ms = 0 } },
		{ "events.roi", { app = "kate", kind = "new_trigger_candidate", meta_json = require("json").encode({ word = tricky, occurrences = 5 }) } },
		{ "events.llm", { app = "kate", kind = "suggested", context = "ctx", predictions_json = "[]", prediction = "p",
			all_predictions_json = "[]", chosen_index = 0, deletes = 0, deleted_text = "", net_saved_chars = 0, count = 1,
			prompt_tokens = 1, completion_tokens = 1, total_tokens = 2, est_cost_usd = 0 } },
	}
	local script = {}
	for index, entry in ipairs(rows) do
		local params = entry[2]
		params.device_id, params.id, params.ts, params.date = DEVICE, first_id + index - 1, TS, date
		script[#script + 1] = Queries.render(entry[1], "cli_json", params)
	end
	-- events_clipboard is rendered by the shared clipboard module, outside the catalogue.
	local clipboard_id = first_id + #rows
	script[#script + 1] = require("keystats.clipboard_events").insert_sql({ device_id = DEVICE, id = clipboard_id,
		ts = TS, date = date, kind = "clipboard_paste", app = "kate",
		meta_json = require("json").encode({ copy_lag_ms = 12, source_app = tricky }) })
	assert(sqlite(db, table.concat(script, "\n")))
	-- INSERT OR IGNORE drops a row a CHECK refuses: prove every family landed.
	local count = assert(sqlite(db, "SELECT (SELECT count(*) FROM events_typing)"
		.. "+(SELECT count(*) FROM events_app_switch)+(SELECT count(*) FROM events_window_switch)"
		.. "+(SELECT count(*) FROM events_shortcut)+(SELECT count(*) FROM events_system)"
		.. "+(SELECT count(*) FROM events_hotstring)+(SELECT count(*) FROM events_session)"
		.. "+(SELECT count(*) FROM events_llm)+(SELECT count(*) FROM events_roi)"
		.. "+(SELECT count(*) FROM events_clipboard);"))
	assert(tonumber(count) == clipboard_id, "a fixture row was refused by the schema")
	return clipboard_id
end

local DUMP = "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'events_%' ORDER BY name;"

--- Every raw row, hex-encoded, for an exact comparison of two stores.
local function dump(db)
	local out = {}
	for name in assert(sqlite(db, DUMP)):gmatch("([^\n]+)\n") do
		local columns = {}
		for column in assert(sqlite(db, "SELECT name FROM pragma_table_info('" .. name .. "');")):gmatch("([^\n]+)\n") do
			columns[#columns + 1] = "quote(hex(" .. column .. "))||typeof(" .. column .. ")"
		end
		out[#out + 1] = name .. ":" .. assert(sqlite(db, "SELECT " .. table.concat(columns, "||'|'||")
			.. " FROM " .. name .. " ORDER BY device_id, id;"))
	end
	return table.concat(out, "\n")
end

local function make_ledger(dir, store, identity)
	return Ledger.new({
		metrics_dir = dir .. "/metrics",
		identity = identity or { device_id = DEVICE, name = "host", os = "linux", os_version = "",
			host_signature = "machine", created_at = TS, schema_version = 1 },
		store = store, fs = Ledger.native_ports(), now_ts = function() return TS end, logger = logger(),
	})
end

local function run_to_idle(ledger)
	for _ = 1, 50 do
		local status, reason = ledger:step()
		if status == "idle" then return end
		assert(status == "more", "ledger step failed: " .. tostring(reason))
	end
	error("ledger never became idle")
end

local function read(path)
	local handle = assert(io.open(path, "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

local function replay(ledger_text)
	local db = temp_dir() .. "/replay.sqlite"
	assert(sqlite(db, ".output /dev/null\n" .. schema_sql()))
	local ok, detail = sqlite(db, ledger_text)
	assert(ok ~= nil, "the ledger does not replay: " .. tostring(detail))
	return db
end

helpers.describe("Linux metrics ledger export", function()
	if not HAS_SQLITE then return end

	it("linux-ledger-roundtrip: every raw family replays byte for byte into an empty store", function()
		local dir = temp_dir()
		local db = dir .. "/metrics.sqlite"
		local store = new_store(db)
		insert_rows(db, 1, "2026-11-05")
		local ledger = make_ledger(dir, store)
		helpers.assert_true(ledger:prepare())
		run_to_idle(ledger)
		local text = read(ledger.path)
		helpers.assert_eq(text:sub(1, #Ledger.header(DEVICE)), Ledger.header(DEVICE))
		helpers.assert_eq(dump(replay(text)), dump(db))
	end)

	it("linux-ledger-framing: one canonical INSERT per statement line and a rollover between days", function()
		local dir = temp_dir()
		local db = dir .. "/metrics.sqlite"
		local store = new_store(db)
		local last = insert_rows(db, 1, "2026-11-05")
		local ledger = make_ledger(dir, store)
		assert(ledger:prepare())
		run_to_idle(ledger)
		insert_rows(db, last + 1, "2026-11-06")
		run_to_idle(ledger)
		local text = read(ledger.path)
		-- Outside literals, every line is a comment, a PRAGMA, BEGIN, COMMIT or one
		-- INSERT whose tuple starts with this device and its id (macOS scanner).
		local in_string, starts = false, {}
		local line_start = 1
		for i = 1, #text do
			local ch = text:sub(i, i)
			if ch == "'" then in_string = not in_string end
			if ch == "\n" then
				if not in_string then starts[#starts + 1] = line_start end
				line_start = i + 1
			end
		end
		local typing, rollovers = 0, 0
		for _, at in ipairs(starts) do
			local line = text:sub(at, (text:find("\n", at, true) or #text + 1) - 1)
			if line:match("^INSERT") then
				helpers.assert_true(line:match("^INSERT OR IGNORE INTO events_[%w_]+ %(device_id, id, ") ~= nil, line:sub(1, 80))
				helpers.assert_true(line:find("VALUES %('" .. DEVICE:gsub("%-", "%%-") .. "', %d+, ") ~= nil, line:sub(1, 120))
				if line:match("^INSERT OR IGNORE INTO events_typing ") then typing = typing + 1 end
			elseif line:match("^%-%- === day rollover ") then
				helpers.assert_eq(line, "-- === day rollover 2026-11-05 -> 2026-11-06 ===")
				rollovers = rollovers + 1
			else
				helpers.assert_true(line == "" or line == "BEGIN TRANSACTION;" or line == "COMMIT;"
					or line:match("^%-%- ") ~= nil or line == "PRAGMA foreign_keys = OFF;", "unexpected line: " .. line)
			end
		end
		helpers.assert_eq(typing, 2)
		helpers.assert_eq(rollovers, 1)
		helpers.assert_eq(dump(replay(text)), dump(db))
	end)

	it("linux-ledger-incremental: a later step appends only the new rows and commits its cursor", function()
		local dir = temp_dir()
		local db = dir .. "/metrics.sqlite"
		local store = new_store(db)
		local last = insert_rows(db, 1, "2026-11-05")
		local ledger = make_ledger(dir, store)
		assert(ledger:prepare())
		run_to_idle(ledger)
		local before = read(ledger.path)
		helpers.assert_eq(store.get_meta(Ledger.META.cursor), tostring(last))
		last = insert_rows(db, last + 1, "2026-11-05")
		run_to_idle(ledger)
		local after = read(ledger.path)
		helpers.assert_eq(after:sub(1, #before), before)
		helpers.assert_eq(store.get_meta(Ledger.META.cursor), tostring(last))
		helpers.assert_eq(store.get_meta(Ledger.META.size), tostring(#after))
		-- A fresh process extends the same file rather than regenerating it.
		local reopened = make_ledger(dir, store)
		assert(reopened:prepare())
		helpers.assert_eq(reopened:status().rebuilding, false)
	end)

	it("linux-ledger-meta-once: a fresh process reads its recorded position in one query", function()
		-- Each sqlite3 query is a process (about 4 ms at boot); the four meta
		-- keys used to be four get_meta calls on the boot path.
		local dir = temp_dir()
		local db = dir .. "/metrics.sqlite"
		local store = new_store(db)
		insert_rows(db, 1, "2026-11-05")
		local first = make_ledger(dir, store)
		assert(first:prepare())
		run_to_idle(first)
		local counted, meta_reads, queries = {}, 0, 0
		for name, fn in pairs(store) do counted[name] = fn end
		counted.get_meta = function(...) meta_reads = meta_reads + 1; return store.get_meta(...) end
		counted.query_rows = function(...) queries = queries + 1; return store.query_rows(...) end
		local reopened = make_ledger(dir, counted)
		assert(reopened:prepare())
		helpers.assert_eq(reopened:status().rebuilding, false, "the recorded position was read back")
		helpers.assert_eq(meta_reads, 0)
		helpers.assert_eq(queries, 1)
	end)

	it("linux-ledger-meta-decode: values survive the line framing and junk is counted", function()
		local Json = require("json")
		local recorded, malformed = Ledger.decode_meta({
			Json.encode(Ledger.META.date) .. "\t" .. Json.encode("2026-11-05"),
			Json.encode(Ledger.META.device) .. "\t" .. Json.encode("dev\0ice\nx"),
			Json.encode("unrelated_key") .. "\t" .. Json.encode("v"),
			"not a row",
		})
		helpers.assert_eq(recorded.date, "2026-11-05")
		helpers.assert_eq(recorded.device, "dev\0ice\nx")
		helpers.assert_eq(malformed, 2)
		helpers.assert_eq(next((Ledger.decode_meta(nil))), nil, "a refused query records nothing")
		local _, broken = Ledger.decode_meta(true)
		helpers.assert_eq(broken, 1, "an answer that is not a list of lines is malformed, never iterated")
	end)

	it("linux-ledger-divergence: a size other than the recorded one regenerates the whole file", function()
		local dir = temp_dir()
		local db = dir .. "/metrics.sqlite"
		local store = new_store(db)
		insert_rows(db, 1, "2026-11-05")
		local ledger = make_ledger(dir, store)
		assert(ledger:prepare())
		run_to_idle(ledger)
		local good = read(ledger.path)
		-- A crash between an append and its cursor commit leaves extra bytes.
		local handle = assert(io.open(ledger.path, "ab"))
		handle:write("\n-- === ingest batch torn ===\nBEGIN TRANSACTION;\nINSERT OR IGNORE INTO events_sys")
		handle:close()
		local reopened = make_ledger(dir, store)
		assert(reopened:prepare())
		helpers.assert_eq(reopened:status().rebuilding, true)
		run_to_idle(reopened)
		helpers.assert_eq(read(ledger.path), good)
	end)

	it("linux-ledger-rewrite: rows rewritten in place reach the ledger after a requested rebuild", function()
		local dir = temp_dir()
		local db = dir .. "/metrics.sqlite"
		local store = new_store(db)
		insert_rows(db, 1, "2026-11-05")
		local ledger = make_ledger(dir, store)
		assert(ledger:prepare())
		run_to_idle(ledger)
		assert(sqlite(db, "UPDATE events_typing SET text='enc:v1:cipher';"))
		ledger:request_rebuild()
		run_to_idle(ledger)
		local text = read(ledger.path)
		helpers.assert_true(text:find("'enc:v1:cipher'", 1, true) ~= nil, "rewritten text exported")
		helpers.assert_eq(dump(replay(text)), dump(db))
	end)

	it("linux-ledger-layout: device.json and the Git exclusion are the ones macOS and Windows read", function()
		local dir = temp_dir()
		local store = new_store(dir .. "/metrics.sqlite")
		local ledger = make_ledger(dir, store)
		assert(ledger:prepare())
		local identity = require("json").decode(read(dir .. "/metrics/by_device/" .. DEVICE .. "/device.json"))
		helpers.assert_eq(identity.device_id, DEVICE)
		helpers.assert_eq(identity.os, "linux")
		helpers.assert_eq(identity.host_signature, "machine")
		helpers.assert_eq(read(dir .. "/metrics/.gitignore"), Ledger.GITIGNORE)
	end)
end)

helpers.describe("Linux metrics ledger identity", function()
	local function resolve(entries, files, registered)
		return Ledger.resolve_identity({
			metrics_dir = "/m", host_signature = "machine-a", hostname = "box", os_version = "6.1",
			legacy_registered = function(id) return registered == id end,
			random_bytes = function(n) return string.rep("\255", n) end, now_ts = TS,
			list = function() return entries end,
			read = function(path)
				if files[path] then return files[path], "ok" end
				return nil, "absent"
			end,
		})
	end

	it("linux-ledger-identity: this host's device.json wins over every other folder", function()
		local identity, created = resolve({ { name = "linux-box", kind = "directory" },
			{ name = "5f0e0000-0000-4000-8000-000000000000", kind = "directory" } }, {
			["/m/by_device/linux-box/device.json"] = '{"device_id":"linux-box","host_signature":"machine-b"}',
			["/m/by_device/5f0e0000-0000-4000-8000-000000000000/device.json"] =
				'{"device_id":"5f0e0000-0000-4000-8000-000000000000","host_signature":"machine-a"}',
		})
		helpers.assert_eq(identity.device_id, "5f0e0000-0000-4000-8000-000000000000")
		helpers.assert_eq(created, false)
	end)

	it("linux-ledger-identity: a store recorded before the ledger keeps its linux-<host> id", function()
		local identity, created = resolve({}, {}, "linux-box")
		helpers.assert_eq(identity.device_id, "linux-box")
		helpers.assert_eq(created, true)
		helpers.assert_eq(identity.host_signature, "machine-a")
	end)

	it("linux-ledger-identity: a new store, or a hostname another host owns, gets a UUID v4", function()
		helpers.assert_eq(resolve({}, {}).device_id, "ffffffff-ffff-4fff-bfff-ffffffffffff")
		local taken = resolve({ { name = "linux-box", kind = "directory" } },
			{ ["/m/by_device/linux-box/device.json"] = '{"device_id":"linux-box","host_signature":"machine-b"}' }, "linux-box")
		helpers.assert_eq(taken.device_id, "ffffffff-ffff-4fff-bfff-ffffffffffff")
	end)

	it("linux-ledger-identity: an unreadable or mismatched identity refuses instead of minting another", function()
		local identity, reason = resolve({ { name = "x", kind = "directory" } }, { ["/m/by_device/x/device.json"] = "{" })
		helpers.assert_nil(identity)
		helpers.assert_contains(reason, "malformed")
		identity, reason = resolve({ { name = "linux-other", kind = "directory" } },
			{ ["/m/by_device/linux-other/device.json"] = '{"device_id":"linux-box","host_signature":"machine-a"}' })
		helpers.assert_nil(identity)
		helpers.assert_contains(reason, "does not match its folder")
		identity = Ledger.resolve_identity({ host_signature = "" })
		helpers.assert_nil(identity)
	end)
end)

-- The macOS suite replays this exact ledger through its foreign-ledger scanner
-- (test_linux_ledger_admission.lua), so the two drivers are pinned together.
local FIXTURE = "/../_shared/tests/fixtures/keystats/linux_ledger.sql"

helpers.describe("Linux metrics ledger cross-driver fixture", function()
	if not HAS_SQLITE then return end

	it("linux-ledger-fixture: the exporter still writes the ledger the macOS scanner is tested on", function()
		local dir = temp_dir()
		local db = dir .. "/metrics.sqlite"
		local store = new_store(db)
		local last = insert_rows(db, 1, "2026-11-05")
		local ledger = make_ledger(dir, store)
		assert(ledger:prepare())
		run_to_idle(ledger)
		insert_rows(db, last + 1, "2026-11-06")
		run_to_idle(ledger)
		local produced = read(ledger.path)
		local path = helpers.driver_root() .. FIXTURE
		if os.getenv("ERGOPTI_UPDATE_LEDGER_FIXTURE") == "1" then
			local handle = assert(io.open(path, "wb"))
			handle:write(produced)
			handle:close()
		end
		helpers.assert_eq(produced, read(path),
			"regenerate with ERGOPTI_UPDATE_LEDGER_FIXTURE=1 and rerun the macOS admission test")
	end)
end)
