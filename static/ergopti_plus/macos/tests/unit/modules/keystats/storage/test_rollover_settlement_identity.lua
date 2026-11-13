--- tests/unit/modules/keystats/storage/test_rollover_settlement_identity.lua

--- A repeated intent and a distinct same-day intent have different owners.
local function child()
	local root, temporary = assert(arg[3]), assert(arg[2])
	local driver, shared = root .. "/static/ergopti_plus/macos", root .. "/static/ergopti_plus/_shared"
	package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;" .. shared .. "/?.lua;"
		.. shared .. "/?/init.lua;" .. package.path
	local json = require("core.text.engine.json")
	local function request(message)
		message.kind = "request"
		assert(io.stdout:write(json.encode(message) .. "\n"))
		assert(io.stdout:flush())
		return assert(json.decode(assert(io.stdin:read("*l"))))
	end
	local sqlite = require("tests.support.keystats.rebuild_sqlite_bridge").new(request)
	local db = sqlite.open(temporary .. "/db.sqlite")
	for _, name in ipairs({ "schema.sql", "media_schema.sql" }) do
		local file = assert(io.open(shared .. "/metrics/data/db/" .. name, "rb"))
		local schema = assert(file:read("*a"))
		assert(file:close())
		assert(db:exec(schema) == sqlite.OK)
	end
	local helpers = require("tests.helpers")
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["modules.keystats.sqlite_writer"] = {
		get_db = function() return db end,
		quarantine_db = function() return true end,
	}
	package.loaded["modules.keystats.export"] = { get_native_app_category = function() return nil end }
	local aggregator = helpers.load_with_stubs("modules.keystats.aggregator", { sqlite3 = sqlite })
	aggregator.init({ device_id = "device" })
	package.loaded["modules.keystats.aggregator"] = aggregator
	local manager = helpers.load_with_stubs("modules.keystats.log_manager", { sqlite3 = sqlite })
	local function upvalue(fn, name, replacement)
		for i = 1, math.huge do
			local found, value = debug.getupvalue(fn, i)
			assert(found, "missing " .. name)
			if found == name then
				if replacement ~= nil then debug.setupvalue(fn, i, replacement) end
				return value
			end
		end
	end
	local reset = upvalue(upvalue(manager.init, "_init"), "_reset_rollover_cache")
	assert(db:exec([[INSERT OR REPLACE INTO meta(key,value) VALUES
		('today_log_offset','0'),('today_log_date','2026-10-17'),('ngram_ctx_json','{}'),
		('local_data_sql_outbox',''),('aggregate_cache_revision','6'),('rev','0');]]) == sqlite.OK)
	local function snapshot(word)
		aggregator.reset_ngram_ctx()
		aggregator.reset_batch()
		local events = {}
		for char in word:gmatch(".") do events[#events + 1] = { char, 100, {} } end
		aggregator.walk_typing({ timestamp = "2026-10-17 23:59:59", app = "Editor", events = events })
		assert(db:exec("BEGIN TRANSACTION") == sqlite.OK)
		assert(aggregator.flush() == true and db:exec("COMMIT") == sqlite.OK)
		local encoded = assert(json.encode(aggregator.get_ngram_ctx())):gsub("'", "''")
		assert(db:exec("UPDATE meta SET value='" .. encoded .. "' WHERE key='ngram_ctx_json';") == sqlite.OK)
	end
	local first = { path = "/ledger", resolved = "/ledger", dev = 1, ino = 2, offset = 3, batch = "marker" }
	local second = { path = "/ledger", resolved = "/ledger", dev = 1, ino = 2, offset = 4, batch = "marker" }
	snapshot("hi")
	local one = reset("2026-10-17", first)
	local repeated = reset("2026-10-17", first)
	snapshot("go")
	local two = reset("2026-10-17", second)
	aggregator.walk_typing({ timestamp = "2026-10-17 23:59:59", app = "Editor", events = { { "z", 100, {} } } })
	local pending_refused = reset("2026-10-17", { path = "/ledger", resolved = "/ledger", dev = 1, ino = 2, offset = 5, batch = "marker" }) == false
	local pending_retained = aggregator.has_pending_batch() == true
	aggregator.reset_batch()
	assert(db:exec("UPDATE meta SET value='3' WHERE key='aggregate_cache_revision'") == sqlite.OK)
	local stale_reset = reset("2026-10-17", { path = "/ledger", resolved = "/ledger", dev = 1, ino = 2, offset = 6, batch = "marker" })
	local replay_started
	upvalue(manager.ingest_once, "_start_aggregate_recovery", function(owner, state)
		replay_started = owner == db and state.offset == 0
	end)
	local ingestion_refused = manager.ingest_once() == false
	local rows = {}
	for row in db:nrows("SELECT token,c FROM ngram_words ORDER BY token") do rows[#rows + 1] = row end
	assert(db:close() == sqlite.OK)
	print(json.encode({ kind = "done", first = one, repeated = repeated, second = two, pending_refused = pending_refused, pending_retained = pending_retained, stale_reset = stale_reset, replay_started = replay_started, ingestion_refused = ingestion_refused, rows = rows }))
end

if arg and arg[0] and arg[0]:match("test_rollover_settlement_identity%.lua$") then child(); return end
local helpers = require("tests.helpers")
local quote = require("core.text.engine.utils_core").shell_quote
local source = assert(debug.getinfo(1, "S").source):gsub("^@", "")
helpers.describe("rollover settlement exact identity", function()
	helpers.it("retries one intent once and settles a different same-day intent", function()
		local script = [[
import importlib.util,sys,tempfile
from pathlib import Path
root=Path(sys.argv[1]).resolve()
spec=importlib.util.spec_from_file_location('bridge',root/'static/ergopti_plus/macos/tests/support/keystats/rebuild_sqlite_bridge.py')
bridge=importlib.util.module_from_spec(spec);spec.loader.exec_module(bridge)
with tempfile.TemporaryDirectory(prefix='ergopti-settle-identity-') as tmp:
 result=bridge.run_fixture(sys.argv[2],Path(sys.argv[3]).resolve(),root,tmp)
 assert result['first'] and result['repeated'] and result['second'],result
 assert result['pending_refused'] and result['pending_retained'],result
 assert result['stale_reset'] and result['replay_started'] and result['ingestion_refused'],result
 assert result['rows']==[{'token':'go','c':1},{'token':'hi','c':1}],result
print('PASS: exact settlement identity')
]]
		local executable = os.getenv("LUA") or arg[-1]
		local command = "python3 -c " .. quote(script) .. " " .. quote(helpers.driver_root() .. "../../..")
			.. " " .. quote(executable) .. " " .. quote(source) .. " 2>&1"
		local pipe = assert(io.popen(command, "r"))
		local output = assert(pipe:read("*a"))
		local ok = pipe:close()
		helpers.assert_eq(ok, true, output)
		helpers.assert_eq(output, "PASS: exact settlement identity\n")
	end)
end)
