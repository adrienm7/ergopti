--- tests/unit/modules/keystats/storage/test_reader_focus_latency_fingerprint.lua

--- ==============================================================================
--- MODULE: Historical Focus Latency Cache Invalidation
--- DESCRIPTION:
--- Replays genuine aggregator events into real SQLite through the owned Python
--- bridge, then compares direct and cached typing-dashboard projections after
--- the database revision advances. No projection or aggregation is fabricated.
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
	local helpers = require("tests.helpers")
	local errors = {}
	local logger = helpers.make_logger_stub()
	logger.error = function(_, message, ...) errors[#errors + 1] = string.format(message, ...) end
	package.loaded["infra.logger"] = logger
	local reader = helpers.load_with_stubs("modules.keystats.sqlite_reader", { sqlite3 = sqlite })
	package.loaded["modules.keystats.sqlite_writer"] = { get_db = function() return db end }
	package.loaded["modules.keystats.export"] = { get_native_app_category = function() return nil end }
	local aggregator = require("modules.keystats.aggregator")
	aggregator.init({ device_id = "device" })
	local through, today = "2026-10-17", "2026-10-18"
	local app = "Éditeur d’Adrien"
	local function append_focus(date, latency)
		aggregator.walk_system_event({ timestamp = date .. "T12:00:00", action = "focus_first_key",
			app = app, latency_ms = latency })
		aggregator.flush()
		assert(db:exec("UPDATE meta SET value = CAST(value AS INTEGER) + 1 WHERE key = 'rev';") == sqlite.OK)
	end
	local function revision()
		for row in db:nrows("SELECT value FROM meta WHERE key = 'rev'") do return tonumber(row.value) end
		error("The canonical schema must contain its revision counter")
	end
	append_focus(through, 100)
	local initial_revision = revision()
	assert(db:close() == sqlite.OK)
	local projection = require("ui.metrics_typing.projection")
	local pacer = { pause = function() end }
	local before = assert(reader.fingerprint(path, through, pacer))
	local initial, _, initial_complete = projection.session(reader, path, today, pacer).manifest()
	assert(initial_complete == true)
	assert(initial[through][app].focus_to_first_key_sum_ms == 100)
	assert(initial[through][app].focus_to_first_key_count == 1)
	local case = assert(os.getenv("ERGOPTI_FOCUS_FINGERPRINT_CASE"))
	local changed_day = case == "today" and today or through
	db = sqlite.open(path)
	append_focus(changed_day, case == "zero" and 0 or 300)
	local final_revision = revision()
	assert(db:close() == sqlite.OK)
	local after = assert(reader.fingerprint(path, through, pacer))
	local direct, complete = reader.read_manifest(path, nil, nil, pacer)
	local cached, _, cached_complete = projection.session(reader, path, today, pacer).manifest()
	local function counters(manifest, date)
		local row = manifest[date][app]
		return { sum = row.focus_to_first_key_sum_ms, count = row.focus_to_first_key_count,
			chars = row.chars, repeat_count = row.auto_repeat_count }
	end
	print(json.encode({ kind = "done", changed = before ~= after, complete = complete,
		cached_complete = cached_complete, initial_revision = initial_revision,
		final_revision = final_revision, errors = errors,
		direct = counters(direct, through), cached = counters(cached, through),
		changed_direct = counters(direct, changed_day), changed_cached = counters(cached, changed_day) }))
end

if arg and arg[0] and arg[0]:match("test_reader_focus_latency_fingerprint%.lua$") then child(); return end

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
os.environ["ERGOPTI_FOCUS_FINGERPRINT_CASE"]=case
with tempfile.TemporaryDirectory(prefix="ergopti-focus-fingerprint-") as temporary:
    receipt=bridge.run_fixture(sys.argv[2],temporary,Path(sys.argv[3]).resolve())
    assert receipt["complete"] is True and receipt["cached_complete"] is True and not receipt["errors"],receipt
    assert receipt["final_revision"]>receipt["initial_revision"],receipt
    expected={"sum":100,"count":1,"chars":0,"repeat_count":0} if case=="today" else {"sum":100 if case=="zero" else 400,"count":2,"chars":0,"repeat_count":0}
    assert receipt["direct"]==expected,receipt
    assert receipt["cached"]==expected,receipt
    assert receipt["changed_cached"]==receipt["changed_direct"],receipt
    assert receipt["changed"] is (case!="today"),receipt
print("PASS: real aggregator and SQLite focus fingerprint "+case)
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
	helpers.assert_eq(output, "PASS: real aggregator and SQLite focus fingerprint " .. case .. "\n")
end

helpers.describe("focus latency cache fingerprint", function()
	helpers.it("refreshes cached past latency after a genuine event and revision advance (focus-latency-fingerprint)", function()
		verify("past")
	end)
	helpers.it("refreshes cached past counts after a genuine zero-latency event (focus-latency-fingerprint)", function()
		verify("zero")
	end)
	helpers.it("keeps past cache stable for a genuine current-day focus event (focus-latency-fingerprint)", function()
		verify("today")
	end)
end)
