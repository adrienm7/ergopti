--- tests/hardware/run_sqlite_switch_projection.lua
--- Real public focus/flush/reader APIs, owned SQLite files and native refusal.
--- Actual clocks and explicit synthetic focus intervals; no hardware/input,
--- clock, SQL, process or provider mocks. Historical fixture days are explicit.
local uv = require("luv")
require("compat.utf8").install()
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-switch-projection-XXXXXX"))
for _, name in ipairs({ "CONFIG", "DATA", "CACHE", "STATE" }) do
	assert(uv.os_setenv("XDG_" .. name .. "_HOME", root .. "/" .. name:lower()))
end
assert(uv.fs_mkdir(root .. "/config", 448))
assert(uv.fs_mkdir(root .. "/config/ergopti", 448))
local config = assert(io.open(root .. "/config/ergopti/config.toml", "w"))
assert(config:write("[metrics]\nenabled = true\n") and config:close())
local Keylogger = require("modules.keylogger.keylogger")
local Writer = require("modules.keylogger.sqlite_writer")
local Reader = require("modules.keylogger.sqlite_reader")
local Json = require("json")
local Monotonic = require("infra.monotonic")
local path, day = root .. "/metrics.sqlite", os.date("%Y-%m-%d")
local checks, failures = 0, 0
local function check(name, body)
	checks = checks + 1
	local ok, err = xpcall(body, debug.traceback)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end
local function cell(manifest, date, app)
	return manifest[date] and manifest[date][app] or {}
end
local function count(manifest, date, app, destination)
	return (cell(manifest, date, app).switches_to or {})[destination]
end
local function payload()
	return Keylogger.get_dashboard_payload({ include_prefetch = false }).metrics_manifest
end
local function raw_bytes()
	return table.concat(assert(Writer.query_rows("SELECT id,date,prev_app,next_app,duration_ms FROM events_app_switch ORDER BY id;")), "\n")
end
local function aggregate_bytes()
	return table.concat(assert(Writer.query_rows("SELECT hex(device_id),date,hex(app_from),hex(app_to),count FROM agg_app_day_switches_to ORDER BY device_id,date,app_from,app_to;")), "\n")
end
Keylogger.init({ sqlite_path = path, log_dir = root .. "/logs" })
assert(Keylogger.is_enabled() and Writer.is_available())
print("native current local day=" .. day .. "; UTC instant=" .. os.date("!%Y-%m-%d %H:%M:%S"))
check("healthy empty native projection acknowledges every pass", function()
	local manifest, complete = Reader.read_manifest(path)
	assert(next(manifest) == nil and complete == true)
end)
local now = math.floor(Monotonic.now_ms())
Keylogger.on_app_focus("owned-app-a", now - 3)
Keylogger.on_app_focus("owned-app-b", now - 2)
Keylogger.on_app_focus("owned-app-a", now - 1)
Keylogger.on_app_focus("owned-app-b", now)
Keylogger.flush()
local raw, aggregate = raw_bytes(), aggregate_bytes()
print("native public raw rows:\n" .. raw)
print("native public aggregate rows:\n" .. aggregate)
local manifest, complete = Reader.read_manifest(path)
local public = payload()
check("accepted public focus and flush exposes both directional destination maps", function()
	assert(complete == true)
	assert(count(manifest, day, "owned-app-a", "owned-app-b") == 2)
	assert(count(manifest, day, "owned-app-b", "owned-app-a") == 1)
	assert(count(public, day, "owned-app-a", "owned-app-b") == 2)
	assert(count(public, day, "owned-app-b", "owned-app-a") == 1)
end)
Keylogger.flush()
check("second public flush conserves exact raw IDs and aggregate counts", function()
	assert(raw_bytes() == raw and aggregate_bytes() == aggregate)
	assert(assert(Writer.query_rows("SELECT COUNT(*),COUNT(DISTINCT id),MIN(id),MAX(id) FROM events_app_switch;"))[1] == "3|3|1|3")
end)
local destination = "owned café' destination"
local fixtures = {
	{ device = "owned-second-device", date = day, app_from = "owned-app-a", app_to = "owned-app-b", count = 4 },
	{ device = "owned-second-device", date = day, app_from = "owned-app-a", app_to = destination, count = 3 },
	{ device = "owned-history-one", date = "1999-12-31", app_from = "owned-history-source", app_to = "owned-outside-selection", count = 5 },
	{ device = "owned-history-two", date = "1999-12-31", app_from = "owned-history-source", app_to = "owned-outside-selection", count = 2 },
	{ device = "owned-history-two", date = "2000-01-01", app_from = "owned-history-source", app_to = "owned-next-day", count = 4 },
	{ device = "owned-history-two", date = "2000-01-01", app_from = "owned-other-source", app_to = "owned-history-source", count = 1 },
}
for _, row in ipairs(fixtures) do
	assert(Writer.register_device(row.device, row.device, "linux", "", ""))
	local original = Json.encode(row)
	assert(Writer.upsert_switch_to(row.device, row))
	assert(Json.encode(row) == original)
end
assert(Writer.upsert_app_day("owned-history-one", "1999-12-31", "owned-control", { chars = 9 }))
aggregate = aggregate_bytes()
Keylogger.clear_cache()
check("native synchronized device counts sum while destinations retain original UTF8 and quote bytes", function()
	local result, accepted = Reader.read_manifest(path)
	assert(accepted == true)
	assert(count(result, day, "owned-app-a", "owned-app-b") == 6)
	assert(count(result, day, "owned-app-a", destination) == 3)
	assert(count(payload(), day, "owned-app-a", destination) == 3)
end)
check("transition-only source entries retain ordinary defaults without inventing destination entries", function()
	local result = Reader.read_manifest(path, "1999-12-31", "1999-12-31")
	assert(count(result, "1999-12-31", "owned-history-source", "owned-outside-selection") == 7)
	assert(cell(result, "1999-12-31", "owned-history-source").chars == 0)
	assert(result["1999-12-31"]["owned-outside-selection"] == nil)
	assert(cell(result, "1999-12-31", "owned-control").chars == 9)
	assert(cell(result, "1999-12-31", "owned-control").switches_to == nil)
end)
check("inclusive native date bounds retain both historical boundary days", function()
	local result = Reader.read_manifest(path, "1999-12-31", "2000-01-01")
	assert(count(result, "1999-12-31", "owned-history-source", "owned-outside-selection") == 7)
	assert(count(result, "2000-01-01", "owned-history-source", "owned-next-day") == 4)
	assert(result[day] == nil)
end)
check("selected source apps preserve destinations outside the selection and caller table bytes", function()
	local apps = { "owned-history-source" }
	local before = Json.encode(apps)
	local result = Reader.read_manifest(path, "1999-12-31", "2000-01-01", apps)
	assert(count(result, "1999-12-31", "owned-history-source", "owned-outside-selection") == 7)
	assert(count(result, "2000-01-01", "owned-history-source", "owned-next-day") == 4)
	assert(result["2000-01-01"]["owned-other-source"] == nil)
	assert(result["1999-12-31"]["owned-control"] == nil and Json.encode(apps) == before)
end)
check("empty app selection retains existing all-source semantics", function()
	local result = Reader.read_manifest(path, "2000-01-01", "2000-01-01", {})
	assert(count(result, "2000-01-01", "owned-other-source", "owned-history-source") == 1)
	assert(count(result, "2000-01-01", "owned-history-source", "owned-next-day") == 4)
end)
check("selected destination is not treated as a source and inverted ranges remain empty", function()
	local selected, accepted = Reader.read_manifest(path, "1999-12-31", "2000-01-01", { "owned-outside-selection" })
	assert(next(selected) == nil and accepted == true)
	local inverted, complete_inverted = Reader.read_manifest(path, "2000-01-01", "1999-12-31")
	assert(next(inverted) == nil and complete_inverted == true)
end)
local revision = assert(Writer.get_revision())
Keylogger.clear_cache()
assert(Writer.exec_sql("ALTER TABLE agg_app_day_switches_to RENAME TO owned_hidden_switches;"))
local partial, refused = Reader.read_manifest(path)
local refused_public = payload()
assert(Writer.exec_sql("ALTER TABLE owned_hidden_switches RENAME TO agg_app_day_switches_to;"))
check("native destination query refusal preserves partial controls and denies complete cache admission", function()
	assert(refused == false)
	assert(cell(partial, "1999-12-31", "owned-control").chars == 9)
	assert(count(partial, day, "owned-app-a", "owned-app-b") == nil)
	assert(cell(refused_public, "1999-12-31", "owned-control").chars == 9)
end)
local recovered, accepted = Reader.read_manifest(path)
local recovered_public = payload()
check("same revision native recovery rebuilds the formerly partial public cache", function()
	assert(accepted == true and count(recovered, day, "owned-app-a", "owned-app-b") == 6)
	assert(count(recovered_public, day, "owned-app-a", "owned-app-b") == 6)
	assert(count(recovered_public, "1999-12-31", "owned-history-source", "owned-outside-selection") == 7)
	assert(Writer.get_revision() == revision)
end)
assert(Writer.exec_sql("ALTER TABLE agg_app_day_switches_to RENAME TO owned_hidden_switches;"))
local cached = payload()
assert(Writer.exec_sql("ALTER TABLE owned_hidden_switches RENAME TO agg_app_day_switches_to;"))
check("healthy complete public projection retains existing revision cache reuse", function()
	assert(count(cached, day, "owned-app-a", "owned-app-b") == 6)
end)
check("all native projection passes preserve owned raw and aggregate row bytes", function()
	assert(raw_bytes() == raw and aggregate_bytes() == aggregate)
end)
Writer.close_db()
local function remove_owned(file_path)
	local stat = assert(uv.fs_lstat(file_path))
	if stat.type == "directory" then
		for name in uv.fs_scandir_next, assert(uv.fs_scandir(file_path)) do remove_owned(file_path .. "/" .. name) end
		assert(uv.fs_rmdir(file_path))
	else assert(uv.fs_unlink(file_path)) end
end
remove_owned(root)
assert(checks == 13, "all native switch projection controls must execute")
print(string.format("Native SQLite switch projection: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
