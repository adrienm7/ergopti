--- tests/hardware/run_sqlite_null_boundary.lua
--- ==============================================================================
--- MODULE: Native SQLite NULL Projection Boundary
--- DESCRIPTION:
--- Exercises actual public writer/reader APIs against an owned SQLite database.
--- Optional manifest fields reach the runtime projection; read_system_days is
--- a public reader API currently without a Linux runtime caller. No CLI wrappers,
--- forged rows, providers, or hardware are used.
--- ==============================================================================

local uv = require("luv")
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-sqlite-null-XXXXXX"))
for _, name in ipairs({ "CONFIG", "DATA", "CACHE", "STATE" }) do
	assert(uv.os_setenv("XDG_" .. name .. "_HOME", root .. "/" .. name:lower()))
end

local Writer = require("modules.keylogger.sqlite_writer")
local Reader = require("modules.keylogger.sqlite_reader")
local Json = require("json")
local Command = require("modules.keylogger.sqlite_command")
local database, date, app = root .. "/metrics.sqlite", "2026-10-03", "owned café ' app"
local checks, failures = 0, 0

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

assert(Writer.open_db(database))
assert(Writer.upsert_chars_class("owned", { date = date, app = app, letter = 3 }))
check("actual nullable manifest minutes remain absent", function()
	local sql = assert(Writer.query_rows("SELECT typeof(first_typed_min),typeof(last_typed_min),letter FROM agg_app_day_chars_class;"))
	assert(sql[1] == "null|null|3")
	local entry = assert(Reader.read_manifest(database, date, date, { app })[date][app])
	assert(entry.char_letter == 3 and entry.first_typed_min == nil and entry.last_typed_min == nil)
	local encoded = Json.encode(entry)
	assert(not encoded:find('"first_typed_min"', 1, true) and not encoded:find('"last_typed_min"', 1, true))
end)

check("actual string extrema ignore another device's NULL", function()
	assert(Writer.upsert_chars_class("second", { date = date, app = app, letter = 2,
		first_typed_min = "12:30", last_typed_min = "13:45" }))
	local entry = assert(Reader.read_manifest(database, date, date, { app })[date][app])
	assert(entry.char_letter == 5 and entry.first_typed_min == "12:30" and entry.last_typed_min == "13:45")
end)

assert(Writer.upsert_system_day("desktop", { date = date, wifi_changes = 3, battery_sum = 0, battery_count = 0 }))
check("actual no-battery system sample retains zero counts and absent extrema", function()
	local sql = assert(Writer.query_rows("SELECT typeof(battery_min),typeof(battery_max),battery_count FROM agg_system_day;"))
	assert(sql[1] == "null|null|0")
	local day = assert(Reader.read_system_days(database, date, date)[date])
	assert(day.wifi_changes == 3 and day.battery_sum == 0 and day.battery_count == 0)
	assert(day.battery_min == nil and day.battery_max == nil)
end)

check("actual nullable battery totals use the reader's zero defaults", function()
	assert(Writer.upsert_system_day("desktop", { date = date, wifi_changes = 4 }))
	local day = assert(Reader.read_system_days(database, date, date)[date])
	assert(day.wifi_changes == 4 and day.battery_sum == 0 and day.battery_count == 0)
	assert(day.battery_min == nil and day.battery_max == nil)
end)

check("actual numeric extrema and sums survive mixed nullable devices", function()
	assert(Writer.upsert_system_day("sample-low", { date = date, battery_sum = 50, battery_count = 1,
		battery_min = 50, battery_max = 50 }))
	assert(Writer.upsert_system_day("sample-high", { date = date, battery_sum = 90, battery_count = 1,
		battery_min = 90, battery_max = 90 }))
	local day = assert(Reader.read_system_days(database, date, date)[date])
	assert(day.wifi_changes == 4 and day.battery_sum == 140 and day.battery_count == 2)
	assert(day.battery_min == 50 and day.battery_max == 90)
end)

check("native nested JSON text keeps escaped NUL and UTF-8 identities", function()
	local buckets = Json.encode({ ["nul\0é"] = 2 })
	assert(Writer.upsert_burst("owned", { date = date, app = app, length_buckets = {} }))
	assert(Writer.exec_sql("UPDATE agg_app_day_burst SET length_buckets_json='" .. Command.escape_literal(buckets) .. "';"))
	local entry = assert(Reader.read_manifest(database, date, date, { app })[date][app])
	assert(entry.burst_length_buckets["nul\0é"] == 2)
	assert(type(Json.decode('{"legacy":null}').legacy) == "table", "legacy decoder semantics changed")
	assert(Json.is_null(Json.decode_lossless('{"tagged":null}').tagged))
end)

check("native empty row lists and selected app filters keep their meaning", function()
	assert(next(Reader.read_manifest(database, date, date, { "absent app" })) == nil)
	assert(next(Reader.read_system_days(database, "2026-10-04", "2026-10-04")) == nil)
	assert(Reader.read_manifest(database, date, date, {})[date][app].char_letter == 5)
end)

check("actual failed SQLite read is refused and retry remains healthy", function()
	local missing = root .. "/absent.sqlite"
	assert(next(Reader.read_system_days(missing, date, date)) == nil and not uv.fs_lstat(missing))
	assert(Writer.exec_sql("ALTER TABLE agg_system_day RENAME TO owned_hidden_system_day;"))
	assert(next(Reader.read_system_days(database, date, date)) == nil)
	assert(Writer.exec_sql("ALTER TABLE owned_hidden_system_day RENAME TO agg_system_day;"))
	assert(Reader.read_system_days(database, date, date)[date].battery_count == 2)
end)

Writer.close_db()
local function remove_owned(path)
	local stat = assert(uv.fs_lstat(path))
	if stat.type == "directory" then
		for name in uv.fs_scandir_next, assert(uv.fs_scandir(path)) do remove_owned(path .. "/" .. name) end
		assert(uv.fs_rmdir(path))
	else assert(uv.fs_unlink(path)) end
end
remove_owned(root)
assert(checks == 8, "all eight native NULL boundary controls must execute")
print(string.format("Native SQLite NULL boundary: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
