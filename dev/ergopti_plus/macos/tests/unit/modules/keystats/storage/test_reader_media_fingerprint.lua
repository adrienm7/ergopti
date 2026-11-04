--- tests/unit/modules/keystats/storage/test_reader_media_fingerprint.lua

--- ==============================================================================
--- MODULE: Media Metrics Fingerprint SQLite Regression
--- DESCRIPTION:
--- Exercise real schema, SQL aggregation and cached projections through the
--- existing owned Python SQLite bridge. Neither a local C-module path nor a
--- native Hammerspoon installation is a prerequisite of these portable controls.
--- ==============================================================================

local function child()
	local root, temporary = assert(arg[3]), assert(arg[2])
	local driver = root .. "/static/ergopti_plus/macos"
	local shared = root .. "/static/ergopti_plus/_shared"
	package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;"
		.. shared .. "/lua/?.lua;" .. shared .. "/lua/?/init.lua;" .. package.path
	local json = require("json")
	local function request(message)
		message.kind = "request"
		assert(io.stdout:write(json.encode(message) .. "\n")); assert(io.stdout:flush())
		local response = assert(json.decode_lossless(assert(io.stdin:read("*l"))))
		assert(response.ok, response.error)
		return response.value
	end
	local sqlite = { OK = 0 }
	function sqlite.open(path)
		local identity = request({ op = "open", path = path })
		local db = {}
		function db:exec(sql) return request({ op = "exec", connection = identity, sql = sql }) end
		function db:close() return request({ op = "close", connection = identity }) end
		function db:nrows(sql)
			local rows = request({ op = "rows", connection = identity, sql = sql })
			-- LSQLite omits SQL NULL fields; JSON transport must not fabricate values.
			for _, row in ipairs(rows) do
				for name, value in pairs(row) do if json.is_null(value) then row[name] = nil end end
			end
			local index = 0
			return function() index = index + 1; return rows[index] end
		end
		return db
	end
	local path = temporary .. "/db.sqlite"
	local db = sqlite.open(path)
	for _, name in ipairs({ "schema.sql", "media_schema.sql" }) do
		local file = assert(io.open(shared .. "/data/db/" .. name, "rb"))
		local schema = assert(file:read("*a")); assert(file:close())
		assert(db:exec(schema) == sqlite.OK)
	end
	for _, date in ipairs({ "2026-10-17", "2026-10-18" }) do
		assert(db:exec("INSERT INTO ngram_media_keys VALUES('device','" .. date .. "','Player','media.play_pause',1);") == sqlite.OK)
		assert(db:exec("INSERT INTO agg_app_day_media_hold VALUES('device','" .. date .. "','Player','media.play_pause',100,1,100,1,0);") == sqlite.OK)
	end
	assert(db:close() == sqlite.OK)
	local helpers = require("tests.helpers")
	local errors = {}
	local logger = helpers.make_logger_stub()
	logger.error = function(_, message, ...) errors[#errors + 1] = string.format(message, ...) end
	package.loaded["infra.logger"] = logger
	local reader = helpers.load_with_stubs("modules.keystats.sqlite_reader", { sqlite3 = sqlite })
	local projection = require("ui.metrics_typing.projection")
	local pacer = { pause = function() end }
	local through, today = "2026-10-17", "2026-10-18"
	local before = assert(reader.fingerprint(path, through, pacer))
	local first = projection.session(reader, path, today, pacer).manifest()
	assert(first[through].Player.media_keys["media.play_pause"] == 1)
	local case = assert(os.getenv("ERGOPTI_METRICS_FINGERPRINT_CASE"))
	local date = case == "today" and today or through
	db = sqlite.open(path)
	if case == "missing_press" or case == "missing_hold" then
		local table_name = case == "missing_press" and "ngram_media_keys" or "agg_app_day_media_hold"
		assert(db:exec("DROP TABLE " .. table_name .. ";") == sqlite.OK)
		assert(db:close() == sqlite.OK)
		local value, detail = reader.fingerprint(path, through, pacer)
		print(json.encode({ kind = "done", refused = value == nil, detail = detail, source = table_name }))
		return
	end
	if case == "press" or case == "today" then
		assert(db:exec("UPDATE ngram_media_keys SET c=2 WHERE date='" .. date .. "';") == sqlite.OK)
	elseif case == "hold_max" then
		assert(db:exec("UPDATE agg_app_day_media_hold SET max_ms=75 WHERE date='" .. date .. "';") == sqlite.OK)
	elseif case == "hold_kind" then
		assert(db:exec("UPDATE agg_app_day_media_hold SET tap_count=0,hold_count=1 WHERE date='" .. date .. "';") == sqlite.OK)
	else
		assert(case == "hold")
		assert(db:exec("UPDATE agg_app_day_media_hold SET sum_ms=250,count=2,max_ms=150,tap_count=2 WHERE date='" .. date .. "';") == sqlite.OK)
	end
	assert(db:close() == sqlite.OK)
	local after = assert(reader.fingerprint(path, through, pacer))
	local direct, complete = reader.read_manifest(path, nil, nil, pacer)
	local cached = projection.session(reader, path, today, pacer).manifest()
	local function counters(manifest, day)
		local app = manifest[day].Player
		return { press = app.media_keys["media.play_pause"], hold = app.media_hold["media.play_pause"], chars = app.chars }
	end
	print(json.encode({ kind = "done", complete = complete, errors = errors,
		changed = before ~= after, direct = counters(direct, through), cached = counters(cached, through),
		today_direct = counters(direct, today), today_cached = counters(cached, today) }))
end

if arg and arg[0] and arg[0]:match("test_reader_media_fingerprint%.lua$") then child(); return end

local helpers = require("tests.helpers")
local quote = require("text_utils").shell_quote
local source = assert(debug.getinfo(1, "S").source):gsub("^@", "")

local function verify(case)
	local script = [[
import importlib.util,os,sys,tempfile
from pathlib import Path
root=Path(sys.argv[1]).resolve()
spec=importlib.util.spec_from_file_location("metrics_sqlite_bridge",root/"tools/diagnostics/hs274_persistence_test.py")
bridge=importlib.util.module_from_spec(spec);spec.loader.exec_module(bridge);bridge.ROOT=root
os.environ["ERGOPTI_PHYSICAL_SOURCE_ROOT"]=str(root)
case=sys.argv[4]
os.environ["ERGOPTI_METRICS_FINGERPRINT_CASE"]=case
with tempfile.TemporaryDirectory(prefix="ergopti-media-fingerprint-") as temporary:
    receipt=bridge.run_fixture(sys.argv[2],temporary,Path(sys.argv[3]).resolve())
    if case.startswith("missing_"):
        assert receipt["refused"] is True,receipt
        assert receipt["source"] in receipt["detail"] and "no such table" in receipt["detail"],receipt
    else:
        assert receipt["complete"] is True and not receipt["errors"],receipt
        assert receipt["changed"] is (case!="today"),receipt
        hold={"s":250,"n":2,"m":150,"tap":2,"hold":0} if case=="hold" else {"s":100,"n":1,"m":100,"tap":1,"hold":0}
        if case=="hold_max": hold["m"]=75
        if case=="hold_kind": hold.update(tap=0,hold=1)
        expected={"press":2 if case=="press" else 1,"hold":hold,"chars":0}
        assert receipt["direct"]==expected,receipt
        assert receipt["cached"]==expected,receipt
        assert receipt["today_cached"]==receipt["today_direct"],receipt
print("PASS: real SQLite media fingerprint "+case)
]]
	local executable = os.getenv("LUA") or arg[-1]
	assert(type(executable) == "string" and executable ~= "", "The actual suite Lua executable is required")
	local command = "python3 -c " .. quote(script) .. " " .. quote(helpers.driver_root() .. "../../..")
		.. " " .. quote(executable) .. " " .. quote(source) .. " " .. quote(case) .. " 2>&1"
	local pipe = assert(io.popen(command, "r"))
	local output = pipe:read("*a")
	local ok, kind, status = pipe:close()
	helpers.assert_eq(ok, true, output)
	helpers.assert_eq(kind, "exit", output)
	helpers.assert_eq(status, 0, output)
	helpers.assert_eq(output, "PASS: real SQLite media fingerprint " .. case .. "\n")
end

helpers.describe("reader media fingerprint", function()
	helpers.it("invalidates cached history for changed past media press counts", function() verify("press") end)
	helpers.it("invalidates cached history for changed past media holds", function() verify("hold") end)
	helpers.it("invalidates cached history when only a past media hold maximum changes", function() verify("hold_max") end)
	helpers.it("invalidates cached history when a past media tap is corrected to a hold", function() verify("hold_kind") end)
	helpers.it("keeps past fingerprints stable for changes after the watermark", function() verify("today") end)
	helpers.it("reports a missing media press table without certifying a fingerprint", function() verify("missing_press") end)
	helpers.it("reports a missing media hold table without certifying a fingerprint", function() verify("missing_hold") end)
end)
