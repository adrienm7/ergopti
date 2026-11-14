--- tests/unit/modules/keystats/storage/test_settlement_latest_day.lua

--- A newly opened stream is credited to its latest observed day.
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
	package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
	package.loaded["modules.keystats.sqlite_writer"] = {
		get_db = function() return db end,
		quarantine_db = function() return true end,
	}
	package.loaded["modules.keystats.export"] = { get_native_app_category = function() return nil end }
	local aggregator = helpers.load_with_stubs("modules.keystats.aggregator", { sqlite3 = sqlite })
	aggregator.init({ device_id = "device" })
	package.loaded["modules.keystats.aggregator"] = aggregator

	aggregator.walk_typing({ timestamp = "2026-10-17 23:59:59", app = "Editor",
		events = { { "h", 100, {} }, { "i", 100, {} }, { " ", 100, {} } } })
	aggregator.walk_typing({ timestamp = "2026-10-18 01:00:00", app = "Editor",
		events = { { "g", 3600000, {} }, { "o", 100, {} } } })
	-- An empty entry is not a new typing event and must not move the owner.
	aggregator.walk_typing({ timestamp = "2026-10-19 01:00:00", app = "Editor", events = {} })
	assert(aggregator.settle_contexts() == true)
	assert(db:exec("BEGIN TRANSACTION") == sqlite.OK)
	assert(aggregator.flush() == true and db:exec("COMMIT") == sqlite.OK)
	local rows, sessions, bursts = {}, {}, {}
	for row in db:nrows("SELECT date, token, c FROM ngram_words ORDER BY token") do rows[#rows + 1] = row end
	for row in db:nrows("SELECT date, count_total FROM agg_app_day_session ORDER BY date") do sessions[#sessions + 1] = row end
	for row in db:nrows("SELECT date, count_total FROM agg_app_day_burst ORDER BY date") do bursts[#bursts + 1] = row end
	assert(db:close() == sqlite.OK)
	print(json.encode({ kind = "done", rows = rows, sessions = sessions, bursts = bursts }))
end

if arg and arg[0] and arg[0]:match("test_settlement_latest_day%.lua$") then child(); return end
local helpers = require("tests.helpers")
local quote = require("core.text.engine.utils_core").shell_quote
local source = assert(debug.getinfo(1, "S").source):gsub("^@", "")
helpers.describe("settlement of naturally separated words", function()
	helpers.it("credits a newly opened word to the new event day", function()
		local script = [[
import importlib.util,sys,tempfile
from pathlib import Path
root=Path(sys.argv[1]).resolve()
spec=importlib.util.spec_from_file_location('bridge',root/'static/ergopti_plus/macos/tests/support/keystats/rebuild_sqlite_bridge.py')
bridge=importlib.util.module_from_spec(spec);spec.loader.exec_module(bridge)
with tempfile.TemporaryDirectory(prefix='ergopti-settle-identity-') as tmp:
 result=bridge.run_fixture(sys.argv[2],Path(sys.argv[3]).resolve(),root,tmp)
 assert result['rows']==[{'date':'2026-10-18','token':'go','c':1},{'date':'2026-10-17','token':'hi','c':1}],result
 assert result['sessions']==[{'date':'2026-10-18','count_total':2}],result
 assert result['bursts']==[{'date':'2026-10-18','count_total':2}],result
print('PASS: latest event day')
]]
		local executable = os.getenv("LUA") or arg[-1]
		local command = "python3 -c " .. quote(script) .. " " .. quote(helpers.driver_root() .. "../../..")
			.. " " .. quote(executable) .. " " .. quote(source) .. " 2>&1"
		local pipe = assert(io.popen(command, "r"))
		local output = assert(pipe:read("*a"))
		local ok = pipe:close()
		helpers.assert_eq(ok, true, output)
		helpers.assert_eq(output, "PASS: latest event day\n")
	end)
end)
