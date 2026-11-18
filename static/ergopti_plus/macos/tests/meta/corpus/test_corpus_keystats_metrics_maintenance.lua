--- tests/meta/corpus/test_corpus_keystats_metrics_maintenance.lua

--- ==============================================================================
--- MODULE: Dashboard Export and Purge Corpus Consumer (macOS)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/keystats/metrics_maintenance_vectors.json
--- through the macOS owners: the dashboard request of
--- modules/keystats/log_manager.lua, the events_system row of
--- modules/keystats/sqlite_writer.lua and the store that writer opens, which
--- installs _shared/metrics/data/db/purge_schema.sql. Linux replays the shared
--- helper and Windows its own module.
---
--- FEATURES & RATIONALE:
--- 1. The child runs in a zone east of UTC. macOS stores a row's ts in UTC
---    (maintainer decision KMD-1) while the tombstone's ts is local time, so a
---    Purge that looked its tombstone up by that local ts never found it and
---    answered "refused" after deleting the metrics. Under UTC, the zone of the
---    hosted runners, the two coincide and the defect stayed green.
--- 2. The three devices' ledgers replay in each of their six orders into
---    stores opened by the real writer: whichever order a sync delivers them
---    in, a purged row never comes back and a later row survives.
--- 3. SQL and transactions are real SQLite, reached through the Python bridge
---    of tests/support/keystats/rebuild_sqlite_bridge.py.
--- ==============================================================================

local function child()
	local root, temporary = assert(arg[3]), assert(arg[2])
	local driver, shared = root .. "/static/ergopti_plus/macos", root .. "/static/ergopti_plus/_shared"
	package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;" .. shared .. "/?.lua;" .. shared .. "/?/init.lua;"
		.. package.path
	local json = require("core.text.engine.json")
	local function request(message)
		message.kind = "request"
		assert(io.stdout:write(json.encode(message) .. "\n")); assert(io.stdout:flush())
		return assert(json.decode(assert(io.stdin:read("*l"))))
	end
	local sqlite = require("tests.support.keystats.rebuild_sqlite_bridge").new(request)
	local handle = assert(io.open(shared .. "/tests/corpus/keystats/metrics_maintenance_vectors.json", "rb"))
	local vectors = json.decode(assert(handle:read("*a"))); assert(handle:close())
	local helpers = require("tests.helpers")
	package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
	package.loaded["modules.keystats.text_cipher"] = { is_enabled = function() return false end,
		encrypt = function(_, _, value) return value end }
	local Maintenance = require("metrics.engine.maintenance")
	local Queries = require("metrics.engine.queries")

	--- Opens a store through the real writer, as the engine does at start.
	--- @param name string File stem under the fixture directory.
	--- @param device_id string The local device.
	--- @return table writer
	local function open_writer(name, device_id)
		local writer = helpers.load_with_stubs("modules.keystats.sqlite_writer", { sqlite3 = sqlite, json = json })
		writer.init({ paths = { sqlite_path = temporary .. "/" .. name .. ".sqlite" }, device_id = device_id,
			device_obj = { device_id = device_id, name = device_id, os = "darwin", host_signature = "", created_at = "" } })
		assert(writer.open_db(), "the writer opens its store")
		return writer
	end

	--- Returns the named upvalue of a function, and its index.
	local function upvalue(fn, wanted)
		for index = 1, math.huge do
			local name, value = debug.getupvalue(fn, index)
			if name == nil then return nil end
			if name == wanted then return value, index end
		end
	end

	local tombstone = Maintenance.tombstone(vectors.tombstone.epoch)
	assert(tombstone.ts ~= tombstone.metadata.utc, "the fixture zone must not be UTC")

	-- 1/ The Purge, through the real request, ingest and writer.
	local writer = open_writer("ingest", "mac-device")
	local db = writer.get_db()
	package.loaded["modules.keystats.sqlite_writer"] = writer
	package.loaded["modules.keystats.export"] = { get_native_app_category = function() return nil end,
		sync_foreign_data_sql = function() return {} end }
	local aggregator = helpers.load_with_stubs("modules.keystats.aggregator", { sqlite3 = sqlite, json = json })
	aggregator.init({ device_id = "mac-device" }); package.loaded["modules.keystats.aggregator"] = aggregator
	local before = os.date("%Y-%m-%d %H:%M:%S", math.floor(vectors.tombstone.epoch) - 1) .. ".000"
	local batches, offset = { { { entry = { type = "typing", timestamp = before, app = "Editor", text = "a",
		events = { { "a", 100, {} } } } } } }, 0
	package.loaded["modules.keystats.rotation"] = { get_date = function() return tombstone.date end,
		get_offset = function() return offset end, set_offset = function(n) offset = n end,
		read_new_entries = function()
			local batch = table.remove(batches, 1)
			if batch then return batch, offset + 1, "eof" end
			return {}, offset, "eof"
		end }
	local manager = helpers.load_with_stubs("modules.keystats.log_manager", { sqlite3 = sqlite, json = json })
	local _, outbox = upvalue(manager.ingest_once, "_flush_local_data_sql_outbox")
	debug.setupvalue(manager.ingest_once, outbox, function() return true end)
	local require_state = assert(upvalue(manager.request_metrics_maintenance, "_require_state"))
	debug.setupvalue(require_state, select(2, upvalue(require_state, "_state")), {})
	local Timestamp = assert(upvalue(manager.request_metrics_maintenance, "Timestamp"))
	debug.setupvalue(manager.request_metrics_maintenance, select(2, upvalue(manager.request_metrics_maintenance,
		"Timestamp")), setmetatable({ now_epoch = function() return vectors.tombstone.epoch end }, { __index = Timestamp }))
	-- The journal is the rotation stub: what the request appends is the next batch.
	manager.flush_buffer = function() end
	manager.append_log = function(entry) batches[#batches + 1] = { { entry = entry } } end
	local replies = {}
	local function count(sql) local n; for row in db:nrows(sql) do n = row.n end; return n end
	assert(manager.request_metrics_maintenance("purge", function(ok, path) replies[#replies + 1] = { ok, path } end))
	local typing_before = count("SELECT COUNT(*) AS n FROM events_typing")
	local replies_after_typing = #replies
	manager.ingest_once()
	local replies_after_tombstone = #replies
	local row
	for found in db:nrows("SELECT ts, date, utc_offset_min, json_extract(metadata_json, '$.utc') AS utc FROM events_system"
		.. " WHERE action = " .. "'" .. vectors.tombstone.action .. "'") do row = found end
	manager.ingest_once()
	local purge_reply = replies[1]
	local typing_after = count("SELECT COUNT(*) AS n FROM events_typing")

	-- 2/ The Export, through the same request.
	assert(manager.request_metrics_maintenance("export", function(ok, path) replies[#replies + 1] = { ok, path } end))
	local export_reply = replies[2]
	assert(writer.close_db())
	local probe = "x"
	local export_query = Queries.render(vectors.export.query, "native", { path = probe })

	-- 3/ The ledgers, in every device order, into stores the writer opens.
	local function permutations(items)
		if #items <= 1 then return { items } end
		local out = {}
		for index, item in ipairs(items) do
			local rest = {}
			for other, value in ipairs(items) do if other ~= index then rest[#rest + 1] = value end end
			for _, tail in ipairs(permutations(rest)) do out[#out + 1] = { item, table.unpack(tail) } end
		end
		return out
	end
	local function quote(value) return "'" .. tostring(value):gsub("'", "''") .. "'" end
	local replay, devices = vectors.replay, {}
	for _, device in ipairs(replay.devices) do devices[#devices + 1] = device.device_id end
	local orders = {}
	for index, order in ipairs(permutations(devices)) do
		local store = open_writer("replay-" .. index, replay.devices[1].device_id)
		local replay_db = store.get_db()
		local function exec(sql) assert(replay_db:exec(sql) == sqlite.OK, replay_db:errmsg()) end
		for _, device in ipairs(replay.devices) do
			exec(Queries.render("devices.upsert", "native", { device_id = device.device_id, name = device.device_id,
				os = device.os, os_version = "", host_signature = "", created_at = "", updated_at = "" }))
		end
		for _, derived in ipairs(replay.derived) do
			exec("INSERT INTO " .. derived.table .. " (device_id, date) VALUES (" .. quote(derived.device_id) .. ", "
				.. quote(derived.date) .. ");")
		end
		for _, device_id in ipairs(order) do
			for _, ledger_row in ipairs(replay.ledgers[device_id]) do
				assert(ledger_row.table == "events_system", "the vectors replay system rows only")
				exec("INSERT OR IGNORE INTO events_system (device_id, id, ts, date, action, metadata_json) VALUES ("
					.. quote(device_id) .. ", " .. ledger_row.id .. ", " .. quote(ledger_row.ts) .. ", "
					.. quote(ledger_row.date) .. ", " .. quote(ledger_row.action) .. ", "
					.. quote(ledger_row.metadata_json or "{}") .. ");")
			end
		end
		local raw, derived = {}, {}
		for found in replay_db:nrows("SELECT device_id, id, action FROM events_system ORDER BY device_id, id;") do
			raw[#raw + 1] = found.device_id .. ":" .. found.id .. ":" .. found.action
		end
		for found in replay_db:nrows("SELECT device_id, date FROM agg_system_day ORDER BY device_id, date;") do
			derived[#derived + 1] = found.device_id .. ":" .. found.date
		end
		assert(store.close_db())
		orders[#orders + 1] = { order = order, raw = raw, derived = derived }
	end

	print(json.encode({ kind = "done", tombstone = tombstone, typing_before = typing_before,
		replies_after_typing = replies_after_typing, replies_after_tombstone = replies_after_tombstone,
		row = row, purge_ok = purge_reply and purge_reply[1], typing_after = typing_after,
		export_ok = export_reply and export_reply[1], export_path = export_reply and export_reply[2],
		export_name = Maintenance.export_file_name(vectors.tombstone.epoch),
		export_query = export_query, export_query_expected = "VACUUM INTO " .. quote(probe) .. ";", orders = orders }))
end
if arg and arg[0] and arg[0]:match("test_corpus_keystats_metrics_maintenance%.lua$") then child(); return end

local helpers = require("tests.helpers")
local quote = require("core.text.engine.utils_core").shell_quote
local source = assert(debug.getinfo(1, "S").source):gsub("^@", "")

helpers.describe("metrics maintenance corpus on macOS", function()
	helpers.it("corpus-metrics-maintenance: the macOS owners replay the shared tombstone, export and ledgers", function()
		local script = [=[
import importlib.util,json,os,re,sys,tempfile
from pathlib import Path
root=Path(sys.argv[1]).resolve()
path=root/'static/ergopti_plus/macos/tests/support/keystats/rebuild_sqlite_bridge.py'
spec=importlib.util.spec_from_file_location('rebuild_bridge',path)
bridge=importlib.util.module_from_spec(spec);spec.loader.exec_module(bridge)
vectors=json.loads((root/'static/ergopti_plus/_shared/tests/corpus/keystats/metrics_maintenance_vectors.json').read_text('utf-8'))
tomb,export,replay=vectors['tombstone'],vectors['export'],vectors['replay']
# A POSIX zone east of UTC, needing no zone database: local ts and UTC differ.
os.environ['TZ']='ERG-1'
with tempfile.TemporaryDirectory(prefix='ergopti-maintenance-corpus-') as tmp:
 downloads=Path(tmp)/'Downloads';downloads.mkdir()
 os.environ['XDG_DOWNLOAD_DIR']=str(downloads)
 r=bridge.run_fixture(sys.argv[2],Path(sys.argv[3]).resolve(),root,tmp)
 t=r['tombstone']
 assert t['action']==tomb['action'] and t['metadata']['utc']==tomb['utc'],t
 assert t['ts'].endswith(tomb['millis']) and re.search(tomb['ts_pattern'],t['ts']),t
 assert re.search(tomb['date_pattern'],t['date']) and t['ts'][:10]==t['date'],t
 assert r['typing_before']==1 and r['replies_after_typing']==0,r
 assert r['row']['ts']==tomb['utc'] and r['row']['utc']==tomb['utc'],('the row stores the UTC instant',r['row'])
 assert r['row']['date']==t['date'] and r['row']['utc_offset_min'] is not None,r['row']
 assert r['replies_after_tombstone']==1 and r['purge_ok'] is True,('a purge answers once its tombstone committed',r)
 assert r['typing_after']==0,r
 assert re.search(export['name_pattern'],r['export_name']),r['export_name']
 assert r['export_name'].startswith(export['prefix']) and r['export_name'].endswith(export['extension']),r
 assert r['export_ok'] is True and re.search(export['name_pattern'],Path(r['export_path']).name),r
 assert Path(r['export_path']).parent==downloads and Path(r['export_path']).is_file(),r
 assert r['export_query']==r['export_query_expected'],r
 orders=r['orders']
 import math
 assert len({tuple(o['order']) for o in orders})==math.factorial(len(replay['devices']))==len(orders),orders
 assert all(sorted(o['order'])==sorted(d['device_id'] for d in replay['devices']) for o in orders),orders
 for o in orders:
  assert o['raw']==replay['surviving'],(o['order'],o['raw'])
  assert o['derived']==replay['surviving_derived'],(o['order'],o['derived'])
print('PASS: macOS replays the maintenance corpus')
]=]
		local lua = os.getenv("LUA") or arg[-1]
		local command = "python3 -c " .. quote(script) .. " " .. quote(helpers.driver_root() .. "../../..") .. " "
			.. quote(lua) .. " " .. quote(source) .. " 2>&1"
		local pipe = assert(io.popen(command, "r")); local output = pipe:read("*a"); local ok = pipe:close()
		helpers.assert_eq(ok, true, output)
		helpers.assert_eq(output, "PASS: macOS replays the maintenance corpus\n")
	end)
end)
