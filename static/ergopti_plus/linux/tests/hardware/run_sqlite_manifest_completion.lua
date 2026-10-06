--- tests/hardware/run_sqlite_manifest_completion.lua
--- Real SQLite refusal/recovery through public collector and projection APIs.
--- Owned software output and temporary schema obstructions only; no mocks or hardware claims.
local uv = require("luv")
require("compat.utf8").install()
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-manifest-receipt-XXXXXX"))
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
local path = root .. "/metrics.sqlite"
local checks, failures = 0, 0
local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end
local function chars(manifest)
	local count = 0
	for _, apps in pairs(manifest) do
		for _, entry in pairs(apps) do count = count + (entry.llm_chars or 0) end
	end
	return count
end
local function payload() return Keylogger.get_dashboard_payload({ include_prefetch = false }).metrics_manifest end
Keylogger.init({ sqlite_path = path, log_dir = root .. "/logs" })
assert(Keylogger.is_enabled() and Writer.is_available())
check("healthy empty native projection acknowledges completion", function()
	local manifest, complete = Reader.read_manifest(path)
	assert(next(manifest) == nil and complete == true)
end)
Keylogger.record_synthetic_output("owned-cache", "abc", "llm", 1000)
Keylogger.flush()
local date = assert(Writer.query_rows("SELECT date FROM agg_app_day LIMIT 1;"))[1]
local app = assert(Writer.query_rows("SELECT app FROM agg_app_day LIMIT 1;"))[1]
assert(Writer.upsert_errors("owned-extra", { date = date, app = app, bs_total = 7 }))
assert(Writer.upsert_session("owned-extra", { date = date, app = app, count_total = 2, durations = { 4, 5 } }))
local function cell(manifest) return manifest[date] and manifest[date][app] or {} end
local accepted = table.concat(assert(Writer.query_rows("SELECT date,app,llm_chars,llm_triggers FROM agg_app_day;")), "\n")
local revision = assert(Writer.get_revision())
check("actual accepted collector flush reaches the public dashboard", function() assert(chars(payload()) == 3) end)
for _, table_name in ipairs({ "agg_app_day", "agg_app_day_errors", "agg_app_day_session" }) do
	Keylogger.clear_cache()
	assert(Writer.exec_sql("ALTER TABLE " .. table_name .. " RENAME TO owned_hidden;"))
	local partial, complete = Reader.read_manifest(path)
	local refused_payload = payload()
	assert(Writer.exec_sql("ALTER TABLE owned_hidden RENAME TO " .. table_name .. ";"))
	check("native refusal in " .. table_name .. " preserves the partial first return without acknowledging completion", function()
		assert(complete == false)
		assert(chars(partial) == (table_name == "agg_app_day" and 0 or 3))
		assert(chars(refused_payload) == chars(partial))
	end)
	local fresh, recovered = Reader.read_manifest(path)
	local rebuilt = payload()
	check("same-revision recovery after " .. table_name .. " refusal rebuilds the public cache", function()
		assert(recovered == true and chars(fresh) == 3)
		assert(chars(rebuilt) == 3, "refused partial projection remained cached after native recovery")
		assert(cell(rebuilt).bs_total == 7 and cell(rebuilt).session_count_total == 2,
			"refused derived pass remained omitted from the recovered public cache")
		assert(Writer.get_revision() == revision)
		assert(table.concat(assert(Writer.query_rows("SELECT date,app,llm_chars,llm_triggers FROM agg_app_day;")), "\n") == accepted)
	end)
end
-- A completed projection still uses the revision cache. The obstruction occurs
-- after a successful read and is removed before any cache invalidation.
assert(Writer.exec_sql("ALTER TABLE agg_app_day RENAME TO owned_hidden;"))
local cached = payload()
assert(Writer.exec_sql("ALTER TABLE owned_hidden RENAME TO agg_app_day;"))
check("successful completed projection retains healthy cache reuse", function() assert(chars(cached) == 3) end)
Keylogger.clear_cache()
check("explicit cache clear still rebuilds the healthy native projection", function() assert(chars(payload()) == 3) end)
Writer.close_db()
local function remove_owned(file_path)
	local stat = assert(uv.fs_lstat(file_path))
	if stat.type == "directory" then
		for name in uv.fs_scandir_next, assert(uv.fs_scandir(file_path)) do remove_owned(file_path .. "/" .. name) end
		assert(uv.fs_rmdir(file_path))
	else assert(uv.fs_unlink(file_path)) end
end
remove_owned(root)
assert(checks == 10, "all native completion and public cache controls must execute")
print(string.format("Native SQLite manifest completion: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
