--- tests/hardware/run_sqlite_layouts_seen.lua
--- Real public collector/Writer/Reader APIs and native owned SQLite metadata.
--- Software input calls use the actual module's default layout label; they do
--- not claim physical input or active desktop layout selection. No provider,
--- clock, SQL or process doubles. Historical metadata fixtures are explicit.
local uv = require("luv")
require("compat.utf8").install()
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-layouts-seen-XXXXXX"))
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
local Hook = require("adapters.keyboard_hook")
local Json = require("json")
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
local function cell(manifest, date, app) return manifest[date] and manifest[date][app] or {} end
local function count(manifest, date, app, layout) return (cell(manifest, date, app).layouts_seen or {})[layout] end
local function payload() return K.get_dashboard_payload({ include_prefetch = false }).metrics_manifest end
local function layout_bytes()
	return table.concat(assert(W.query_rows("SELECT hex(device_id),date,hex(app),hex(layout),count FROM agg_app_day_layouts ORDER BY device_id,date,app,layout;")), "\n")
end
local function raw_bytes()
	return table.concat(assert(W.query_rows("SELECT id,ts,date,hex(text),hex(events_json) FROM events_typing ORDER BY id;")), "\n")
end
K.init({ sqlite_path = path, log_dir = root .. "/logs" })
assert(K.is_enabled() and W.is_available())
check("healthy empty native manifest retains its existing shape and completion", function()
	local manifest, complete = R.read_manifest(path)
	assert(next(manifest) == nil and complete == true)
end)
local active_metadata = assert(Hook.get_layout())
K.on_keydown("a", 1000, "owned-layout-app")
K.on_keydown("b", 2000, "owned-layout-app")
K.flush()
local before, raw = layout_bytes(), raw_bytes()
print("native module metadata=" .. active_metadata .. "; layout rows:\n" .. before)
check("actual public collector flush projects persisted metadata into the canonical dashboard field", function()
	local manifest, complete = R.read_manifest(path)
	assert(complete == true and count(manifest, day, "owned-layout-app", active_metadata) == 2)
	assert(count(payload(), day, "owned-layout-app", active_metadata) == 2)
	assert(cell(manifest, day, "owned-layout-app").layouts == nil)
	assert(cell(manifest, day, "owned-layout-app").chars == 2)
end)
K.flush()
check("second public flush preserves native layout counters and raw IDs/payloads", function()
	assert(layout_bytes() == before and raw_bytes() == raw)
	assert(W.query_rows("SELECT COUNT(*),COUNT(DISTINCT id) FROM events_typing;")[1] == "1|1")
end)
local secondary = "owned café' layout"
local fixtures = {
	{ device = "owned-extra", date = day, app = "owned-layout-app", layout = active_metadata, count = 3 },
	{ device = "owned-extra", date = day, app = "owned-layout-app", layout = secondary, count = 4 },
	{ device = "owned-history-one", date = "1999-12-31", app = "owned-history", layout = secondary, count = 5 },
	{ device = "owned-history-two", date = "1999-12-31", app = "owned-history", layout = secondary, count = 2 },
	{ device = "owned-history-two", date = "2000-01-01", app = "owned-history", layout = "owned-next-layout", count = 4 },
	{ device = "owned-history-two", date = "2000-01-01", app = "owned-other", layout = "owned-control-layout", count = 0 },
}
for _, row in ipairs(fixtures) do
	assert(W.register_device(row.device, row.device, "linux", "", ""))
	local original = Json.encode(row)
	assert(W.upsert_layout(row.device, row) and Json.encode(row) == original)
end
assert(W.upsert_app_day("owned-history-one", "1999-12-31", "owned-control", { chars = 9 }))
local accepted_bytes = layout_bytes()
K.clear_cache()
check("native device contributions and distinct quoted UTF8 layout labels retain their totals", function()
	local manifest = R.read_manifest(path)
	assert(count(manifest, day, "owned-layout-app", active_metadata) == 5)
	assert(count(manifest, day, "owned-layout-app", secondary) == 4)
	assert(count(payload(), day, "owned-layout-app", secondary) == 4)
end)
check("inclusive historical date bounds and layout-only source defaults retain existing policy", function()
	local manifest = R.read_manifest(path, "1999-12-31", "2000-01-01")
	assert(count(manifest, "1999-12-31", "owned-history", secondary) == 7)
	assert(count(manifest, "2000-01-01", "owned-history", "owned-next-layout") == 4)
	assert(cell(manifest, "1999-12-31", "owned-history").chars == 0 and manifest[day] == nil)
	assert(cell(manifest, "1999-12-31", "owned-control").chars == 9)
	assert(cell(manifest, "1999-12-31", "owned-control").layouts_seen == nil)
end)
check("selected app filters preserve caller arrays and exclude other historical metadata", function()
	local apps = { "owned-history" }
	local original = Json.encode(apps)
	local manifest = R.read_manifest(path, "1999-12-31", "2000-01-01", apps)
	assert(count(manifest, "1999-12-31", "owned-history", secondary) == 7)
	assert(count(manifest, "2000-01-01", "owned-history", "owned-next-layout") == 4)
	assert(manifest["2000-01-01"]["owned-other"] == nil and manifest["1999-12-31"]["owned-control"] == nil)
	assert(Json.encode(apps) == original)
end)
check("empty app selection keeps all metadata including admitted zero counts", function()
	local manifest = R.read_manifest(path, "2000-01-01", "2000-01-01", {})
	assert(count(manifest, "2000-01-01", "owned-other", "owned-control-layout") == 0)
	local empty, complete = R.read_manifest(path, "2000-01-01", "1999-12-31")
	assert(next(empty) == nil and complete == true)
end)
local revision = assert(W.get_revision())
K.clear_cache()
assert(W.exec_sql("ALTER TABLE agg_app_day_layouts RENAME TO owned_hidden_layouts;"))
local partial, refused = R.read_manifest(path)
local refused_public = payload()
assert(W.exec_sql("ALTER TABLE owned_hidden_layouts RENAME TO agg_app_day_layouts;"))
check("genuine native metadata read refusal preserves partial controls without admitting a complete cache", function()
	assert(refused == false and cell(partial, "1999-12-31", "owned-control").chars == 9)
	assert(cell(partial, day, "owned-layout-app").layouts_seen == nil)
	assert(cell(refused_public, "1999-12-31", "owned-control").chars == 9)
end)
local recovered = payload()
check("same revision recovery rebuilds the canonical metadata map in the public dashboard", function()
	assert(count(recovered, day, "owned-layout-app", active_metadata) == 5)
	assert(count(recovered, "1999-12-31", "owned-history", secondary) == 7)
	assert(W.get_revision() == revision)
end)
assert(W.exec_sql("ALTER TABLE agg_app_day_layouts RENAME TO owned_hidden_layouts;"))
local cached = payload()
assert(W.exec_sql("ALTER TABLE owned_hidden_layouts RENAME TO agg_app_day_layouts;"))
check("healthy completed revision cache retains existing reuse and all read passes preserve native bytes", function()
	assert(count(cached, day, "owned-layout-app", active_metadata) == 5)
	assert(layout_bytes() == accepted_bytes and raw_bytes() == raw)
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
assert(checks == 10, "all native layout metadata and public cache controls must execute")
print(string.format("Native SQLite canonical layouts_seen: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
