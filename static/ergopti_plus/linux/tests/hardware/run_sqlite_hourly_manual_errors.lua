--- tests/hardware/run_sqlite_hourly_manual_errors.lua
--- Native SQLite/public software event-protocol proof; no physical collection claim.
--- Current Hook manual Backspace dispatch is outside this aggregate contract.
local uv = require("luv")
require("compat.utf8").install()
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-hour-errors-XXXXXX"))
for _, name in ipairs({ "CONFIG", "DATA", "CACHE", "STATE" }) do
	assert(uv.os_setenv("XDG_" .. name .. "_HOME", root .. "/" .. name:lower()))
end
assert(uv.fs_mkdir(root .. "/config", 448))
assert(uv.fs_mkdir(root .. "/config/ergopti", 448))
local config = assert(io.open(root .. "/config/ergopti/config.toml", "w"))
assert(config:write("[metrics]\nenabled = true\n") and config:close())
local K = require("modules.keylogger.keylogger")
local W = require("modules.keylogger.sqlite_writer")
local R = require("modules.keylogger.sqlite_reader")
local Clock = require("infra.monotonic")
local J = require("json")
local path, today, app = root .. "/metrics.sqlite", os.date("%Y-%m-%d"), "owned-hour-error"
K.init({ sqlite_path = path, log_dir = root .. "/logs" })
assert(K.is_enabled() and W.is_available())
local checks, failures = 0, 0
local function check(name, body)
	checks = checks + 1
	local ok, err = xpcall(body, debug.traceback)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end
local function rows(sql) return assert(W.query_rows(sql)) end
local function cell(manifest, date, source) return manifest[date] and manifest[date][source] or {} end
local function sums(entry, field)
	local c, e, em, es, short, long = 0, 0, 0, 0, 0, 0
	for _, row in pairs(entry[field] or {}) do
		c, e, em, es = c + row.c, e + row.e, em + (row.em or 0), es + row.es
		short = short + ((row.e_buckets or {})["1000"] or 0)
		long = long + ((row.e_buckets or {})["2000"] or 0)
	end
	return c, e, em, es, short, long
end
local function payload() return K.get_dashboard_payload({ include_prefetch = false }).metrics_manifest end
check("native healthy empty projection completes", function()
	local manifest, complete = R.read_manifest(path)
	assert(next(manifest) == nil and complete == true)
end)
local function record(delay)
	local at = math.floor(Clock.now_ms())
	K.on_keydown("a", at, app)
	K.on_keydown("[BS]", at + delay, app)
	K.on_keydown("b", at + delay + 100, app)
	K.flush()
end
record(100)
check("public manual correction preserves raw protocol and scalar daily count", function()
	assert(rows("SELECT id,hex(text) FROM events_typing;")[1] == "1|615B42535D62")
	assert(rows("SELECT bs_total FROM agg_app_day_errors;")[1] == "1")
	assert(rows("SELECT SUM(c),SUM(e),SUM(em),SUM(es) FROM agg_app_day_hourly;")[1] == "2|1|1|0")
	assert(rows("SELECT SUM(c),SUM(e),SUM(es) FROM agg_app_day_hourly_min5;")[1] == "2|1|0")
end)
check("actual Reader and public dashboard expose cumulative error bins", function()
	for _, manifest in ipairs({ R.read_manifest(path), payload() }) do
		local c, e, em, es, short, long = sums(cell(manifest, today, app), "hourly")
		assert(c == 2 and e == 1 and em == 1 and es == 0 and short == 1 and long == 1)
		local fc, fe, _, fs, fshort = sums(cell(manifest, today, app), "hourly_min5")
		assert(fc == 2 and fe == 1 and fs == 0 and fshort == 1)
	end
end)
record(1500)
local raw = table.concat(rows("SELECT id,hex(text),hex(events_json) FROM events_typing ORDER BY id;"), "\n")
check("second genuine flush merges deltas and threshold exclusion without replacing prior bins", function()
	assert(rows("SELECT COUNT(*),COUNT(DISTINCT id) FROM events_typing;")[1] == "2|2")
	assert(rows("SELECT bs_total FROM agg_app_day_errors;")[1] == "2")
	local c, e, em, es, short, long = sums(cell(payload(), today, app), "hourly")
	assert(c == 4 and e == 2 and em == 2 and es == 0 and short == 1 and long == 2)
end)
K.flush()
check("empty repeated flush preserves accepted native raw bytes and counts", function()
	assert(table.concat(rows("SELECT id,hex(text),hex(events_json) FROM events_typing ORDER BY id;"), "\n") == raw)
	assert(rows("SELECT SUM(e) FROM agg_app_day_hourly;")[1] == "2")
end)
local fixture = { date = "2000-01-01", app = "owned-history", hour = "09", slot = "09:00",
	c = 4, e = 2, em = 2, es = 0, e_buckets = { ["1000"] = 1, ["2000"] = 2 } }
local original = J.encode(fixture)
for _, device in ipairs({ "owned-one", "owned-two" }) do
	assert(W.register_device(device, device, "linux", "", ""))
	assert(W.upsert_hourly(device, fixture) and W.upsert_hourly_min5(device, fixture))
end
check("merged devices retain identical histogram contributions and caller bytes", function()
	local manifest = R.read_manifest(path, fixture.date, fixture.date)
	local c, e, em, es, short, long = sums(cell(manifest, fixture.date, fixture.app), "hourly")
	assert(c == 8 and e == 4 and em == 4 and es == 0 and short == 2 and long == 4)
	assert(J.encode(fixture) == original and manifest[today] == nil)
end)
check("direct repeated writer deltas add numeric maps instead of overwriting", function()
	assert(W.upsert_hourly("owned-one", fixture) and W.upsert_hourly_min5("owned-one", fixture))
	assert(rows("SELECT c,e,em,json_extract(e_buckets_json,'$.1000'),json_extract(e_buckets_json,'$.2000') FROM agg_app_day_hourly WHERE device_id='owned-one';")[1] == "8|4|4|2|4")
end)
check("source app filters and inverted empty dates preserve existing read completion", function()
	local apps = { fixture.app }
	local manifest, complete = R.read_manifest(path, fixture.date, fixture.date, apps)
	assert(complete == true and sums(cell(manifest, fixture.date, fixture.app), "hourly") == 12)
	assert(apps[1] == fixture.app and manifest[today] == nil)
	local empty, healthy = R.read_manifest(path, "2000-01-02", fixture.date, {})
	assert(next(empty) == nil and healthy == true)
end)
local before = table.concat(rows("SELECT * FROM agg_app_day_hourly WHERE device_id='owned-one';"), "\n")
assert(W.exec_sql("CREATE TRIGGER owned_hour_refusal BEFORE UPDATE ON agg_app_day_hourly BEGIN SELECT RAISE(ABORT,'owned refusal'); END;"))
local refused = W.upsert_hourly("owned-one", fixture)
assert(W.exec_sql("DROP TRIGGER owned_hour_refusal;"))
check("genuine write refusal returns false and the existing statement rollback preserves rows", function()
	assert(refused == false)
	assert(table.concat(rows("SELECT * FROM agg_app_day_hourly WHERE device_id='owned-one';"), "\n") == before)
end)
check("direct writer recovery adds exactly one accepted histogram delta", function()
	assert(W.upsert_hourly("owned-one", fixture))
	assert(rows("SELECT c,e,em,json_extract(e_buckets_json,'$.1000') FROM agg_app_day_hourly WHERE device_id='owned-one';")[1] == "12|6|6|3")
end)
local fine_before = table.concat(rows("SELECT * FROM agg_app_day_hourly_min5 WHERE device_id='owned-one';"), "\n")
assert(W.exec_sql("CREATE TRIGGER owned_min5_refusal BEFORE UPDATE ON agg_app_day_hourly_min5 BEGIN SELECT RAISE(ABORT,'owned fine refusal'); END;"))
local fine_refused = W.upsert_hourly_min5("owned-one", fixture)
assert(W.exec_sql("DROP TRIGGER owned_min5_refusal;"))
check("genuine min5 write refusal retains truthful failure and byte-identical existing rows", function()
	assert(fine_refused == false)
	assert(table.concat(rows("SELECT * FROM agg_app_day_hourly_min5 WHERE device_id='owned-one';"), "\n") == fine_before)
end)
check("min5 direct recovery admits one delta without touching raw rows", function()
	assert(W.upsert_hourly_min5("owned-one", fixture))
	assert(rows("SELECT c,e,json_extract(e_buckets_json,'$.1000') FROM agg_app_day_hourly_min5 WHERE device_id='owned-one';")[1] == "12|6|3")
	assert(table.concat(rows("SELECT id,hex(text),hex(events_json) FROM events_typing ORDER BY id;"), "\n") == raw)
end)
W.close_db()
local function remove_owned(file_path)
	local stat = assert(uv.fs_lstat(file_path))
	if stat.type == "directory" then
		for name in uv.fs_scandir_next, assert(uv.fs_scandir(file_path)) do remove_owned(file_path .. "/" .. name) end
		assert(uv.fs_rmdir(file_path))
	else assert(uv.fs_unlink(file_path)) end
end
remove_owned(root)
assert(checks == 12, "all native hourly manual-error controls must execute")
print(string.format("Native SQLite hourly manual errors: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
