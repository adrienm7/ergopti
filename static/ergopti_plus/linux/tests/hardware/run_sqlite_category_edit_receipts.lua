--- tests/hardware/run_sqlite_category_edit_receipts.lua
--- ==============================================================================
--- MODULE: Native SQLite Category and Score Transactions (Linux)
--- DESCRIPTION:
--- Drives the real dashboard bridge, keylogger and SQLite writer against owned
--- native databases. Actual AFTER triggers raise ABORT/FAIL at each statement;
--- unchanged rows, truthful saved replies and healthy retries are independent
--- oracles. This covers statement-error rollback, not rollback after a successful
--- COMMIT with a subsequently lost receipt. No UI or physical input is simulated
--- as hardware validation: the bridge is called directly, with real storage.
--- ==============================================================================

local uv = require("luv")
require("compat.utf8").install()
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-category-transactions-XXXXXX"))
local previous_xdg = {}
local checks, failures = 0, 0

local function write(path, content)
	local file = assert(io.open(path, "wb"))
	assert(file:write(content) and file:close())
end

for _, name in ipairs({ "CONFIG", "DATA", "CACHE", "STATE" }) do
	local variable = "XDG_" .. name .. "_HOME"
	previous_xdg[variable] = os.getenv(variable) or false
	assert(uv.os_setenv(variable, root .. "/" .. name:lower()))
end
assert(uv.fs_mkdir(root .. "/config", 448))
assert(uv.fs_mkdir(root .. "/config/ergopti", 448))
write(root .. "/config/ergopti/config.toml", "[metrics]\nenabled = true\n")

local Writer = require("modules.keylogger.sqlite_writer")
local Reader = require("modules.keylogger.sqlite_reader")
local Command = require("modules.keylogger.sqlite_command")
local Bridge = require("ui.metrics_apps.bridge")
local case_index = 0

local function quote(value) return "'" .. Command.escape_literal(value) .. "'" end
local function hex(value)
	return (value:gsub(".", function(byte) return string.format("%02X", byte:byte()) end))
end

local function check(name, fn)
	checks = checks + 1
	local ok, reason = xpcall(fn, debug.traceback)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(reason) .. "\n")
	end
end

local function setup(app)
	case_index = case_index + 1
	Writer.close_db()
	package.loaded["modules.keylogger.keylogger"] = nil
	local keylogger = require("modules.keylogger.keylogger")
	keylogger.init({ sqlite_path = root .. "/case-" .. case_index .. ".sqlite", log_dir = root .. "/logs" })
	assert(keylogger.is_enabled() and Writer.is_available())
	local device = assert(Writer.query_rows("SELECT device_id FROM devices;"))[1]
	assert(device and device ~= "foreign-device")
	Writer.upsert_app_day(device, "2000-01-01", app, { chars = 3 })
	Writer.upsert_app_day(device, "2000-01-02", app, { chars = 4 })
	Writer.upsert_app_day("foreign-device", "2000-01-01", app, { chars = 7 })
	assert(Writer.exec_sql("UPDATE agg_app_day SET category='Original';"))
	assert(Writer.set_meta("app_score." .. app, "1"))
	local payload = keylogger.get_dashboard_payload({ include_prefetch = false })
	assert(payload.metrics_manifest["2000-01-01"][app].category == "Original")
	return keylogger, device
end

local function snapshot()
	local categories = assert(Writer.query_rows("SELECT device_id,date,hex(app),chars,hex(category) FROM agg_app_day ORDER BY device_id,date,app;"))
	local scores = assert(Writer.query_rows("SELECT hex(key),hex(value) FROM meta WHERE key LIKE 'app_score.%' ORDER BY key;"))
	return table.concat(categories, "\n") .. "\nSCORES\n" .. table.concat(scores, "\n")
end

local function assert_updated(device, app, category, score)
	local rows = assert(Writer.query_rows("SELECT hex(category) FROM agg_app_day WHERE device_id=" .. quote(device)
		.. " AND app=" .. quote(app) .. " ORDER BY date;"))
	assert(#rows == 2 and rows[1] == hex(category) and rows[2] == hex(category), "edit failed to update both owned dates exactly")
	local foreign = assert(Writer.query_rows("SELECT category FROM agg_app_day WHERE device_id='foreign-device';"))
	assert(#foreign == 1 and foreign[1] == "Original", "edit changed another device's category")
	local scores = assert(Writer.query_rows("SELECT value FROM meta WHERE key=" .. quote("app_score." .. app) .. ";"))
	assert(#scores == 1 and scores[1] == score, "score/default/floor changed")
end

for _, owner in ipairs({ "score", "category" }) do
	for _, action in ipairs({ "ABORT", "FAIL" }) do
		local keylogger, device = setup("owned-app")
		local before = snapshot()
		local trigger = owner == "score"
			and ("CREATE TRIGGER owned_refusal AFTER INSERT ON meta WHEN NEW.key='app_score.owned-app' BEGIN SELECT RAISE(" .. action .. ",'owned score refusal'); END;")
			or ("CREATE TRIGGER owned_refusal AFTER UPDATE ON agg_app_day WHEN NEW.device_id=" .. quote(device)
				.. " BEGIN SELECT RAISE(" .. action .. ",'owned category refusal'); END;")
		assert(Writer.exec_sql(trigger))
		check("public " .. owner .. " AFTER " .. action .. " refuses without changing category, score or cached payload", function()
			local reply = Bridge.on_message({ action = "edit", app = "owned-app", cat = "Updated", score = 2 }, { keylogger = keylogger })
			assert(reply.saved == false, "dashboard acknowledged an actual SQLite error as saved")
			assert(snapshot() == before, "a refused logical edit left partially changed native rows")
			assert(reply.metrics_manifest["2000-01-01"]["owned-app"].category == "Original", "refusal published a partial category")
		end)
		assert(Writer.exec_sql("DROP TRIGGER owned_refusal;"))
		check("public " .. owner .. " AFTER " .. action .. " allows a same-owner healthy retry", function()
			local reply = Bridge.on_message({ action = "edit", app = "owned-app", cat = "Updated", score = 1 }, { keylogger = keylogger })
			assert(reply.saved == true)
			assert_updated(device, "owned-app", "Updated", "1")
			assert(reply.metrics_manifest["2000-01-01"]["owned-app"].category == "Updated", "acknowledged retry retained its stale category cache")
		end)
	end
end

for _, case in ipairs({
	{ "absent score", nil, "0", "Updated" },
	{ "negative fractional score", -0.25, "-1", "Updated" },
	{ "numeric-string fractional score", "1.9", "1", "Updated" },
	{ "UTF-8 and quote", 1, "1", "Updated ' été 😀" },
	{ "literal CRLF", 1, "1", "Updated\r\nrow" },
}) do
	local keylogger, device = setup("owned ' été app")
	check(case[1] .. " preserves public healthy edit values and device filtering", function()
		local reply = Bridge.on_message({ action = "edit", app = "owned ' été app", cat = case[4], score = case[2] }, { keylogger = keylogger })
		assert(reply.saved == true)
		assert_updated(device, "owned ' été app", case[4], case[3])
		assert(reply.metrics_manifest["2000-01-01"]["owned ' été app"].category == case[4])
		assert(reply.user_categories["owned ' été app"].type == case[4])
		assert(reply.user_categories["owned ' été app"].score == tonumber(case[3]))
	end)
end

local _, literal_device = setup("owned-app")
check("native Writer keeps a complete NUL category and score without claiming dashboard projection", function()
	local category = "Updated\r\nrow\0tail"
	assert(Writer.set_app_category(literal_device, "owned-app", category, 1) == true)
	assert_updated(literal_device, "owned-app", category, "1")
	assert(Reader.read_user_categories(Writer.get_db_path(), literal_device)["owned-app"].type == category,
		"category projection shortened the native NUL text")
end)

local keylogger, device = setup("owned-app")
check("existing absent-application edit behavior still stores its default score without inventing rows", function()
	local before = assert(Writer.query_rows("SELECT count(*) FROM agg_app_day;"))[1]
	assert(Writer.set_app_category(device, "absent-app", "Updated", nil) == true)
	assert(assert(Writer.query_rows("SELECT count(*) FROM agg_app_day;"))[1] == before)
	local scores = assert(Writer.query_rows("SELECT value FROM meta WHERE key='app_score.absent-app';"))
	assert(#scores == 1 and scores[1] == "0")
	assert(Reader.read_user_categories(Writer.get_db_path(), device)["absent-app"].score == 0)
end)

check("category metadata keys preserve native NUL and UTF-8 application bytes", function()
	local app = "owned ' été\0app"
	assert(Writer.upsert_app_day(device, "2000-01-01", app, { chars = 1 }))
	assert(Writer.set_app_category(device, app, "Productivity", 1))
	local categories = assert(Reader.read_user_categories(Writer.get_db_path(), device))
	assert(categories[app] and categories[app].score == 1 and categories[app].type == "Productivity",
		"native category metadata key was shortened before JSON quoting")
end)

check("saved override projection uses local categories rather than foreign synced assignments", function()
	assert(Writer.exec_sql("UPDATE agg_app_day SET category='zzForeign' WHERE device_id='foreign-device';"))
	assert(Writer.set_app_category(device, "owned-app", "Productivity", -2))
	local categories = assert(keylogger.get_dashboard_payload({ include_prefetch = false })).user_categories
	assert(categories["owned-app"].type == "Productivity" and categories["owned-app"].score == -2)
	assert(categories["absent-app"].type == "Unknown" and categories["absent-app"].score == 0,
		"an existing score with no local statistics needs the reader's ordinary missing-category contract")
end)

check("score-only native edit reaches a dashboard with otherwise identical manifest data", function()
	-- The preceding direct Writer controls bypassed the collector's cache owner.
	assert(keylogger.clear_cache())
	local before = assert(Bridge.on_message("ready", { keylogger = keylogger }))
	local reply = assert(Bridge.on_message({ action = "edit", app = "owned-app", cat = "Productivity", score = 2 }, { keylogger = keylogger }))
	assert(reply.saved and reply.user_categories["owned-app"].score == 2)
	assert(require("test.format").deep_equal(reply.metrics_manifest, before.metrics_manifest),
		"the score-only fixture must not accidentally exercise manifest replacement")
end)

check("refused native category read does not manufacture an empty successful dashboard", function()
	local path = Writer.get_db_path()
	assert(os.rename(path, path .. ".held"))
	local categories = Reader.read_user_categories(path, device)
	local reply, reason = keylogger.get_dashboard_payload({ include_prefetch = false })
	local absent = uv.fs_stat(path) == nil
	assert(os.rename(path .. ".held", path))
	assert(categories == nil and reply == nil and reason == "SQLite projection unavailable" and absent)
	assert(keylogger.get_dashboard_payload({ include_prefetch = false }).user_categories["owned-app"].score == 2)
end)

check("malformed score metadata refuses the projection until the exact value is repaired", function()
	for _, malformed in ipairs({ "not-a-score", "2\0tail", "1e999" }) do
		assert(Writer.set_meta("app_score.owned-app", malformed))
		assert(keylogger.get_dashboard_payload({ include_prefetch = false }) == nil)
	end
	assert(Writer.set_meta("app_score.owned-app", "2"))
	assert(keylogger.get_dashboard_payload({ include_prefetch = false }).user_categories["owned-app"].score == 2)
end)

check("a new collector and page owner recover the durable category and score", function()
	local path = Writer.get_db_path()
	Writer.close_db()
	package.loaded["modules.keylogger.keylogger"] = nil
	keylogger = require("modules.keylogger.keylogger")
	assert(keylogger.init({ sqlite_path = path, log_dir = root .. "/logs" }) ~= false)
	Bridge._reset()
	local ready = assert(Bridge.on_message("ready", { keylogger = keylogger }))
	assert(ready.user_categories["owned-app"].score == 2 and ready.user_categories["owned-app"].type == "Productivity")
end)

Writer.close_db()
for variable, value in pairs(previous_xdg) do
	if value == false then assert(uv.os_unsetenv(variable)) else assert(uv.os_setenv(variable, value)) end
end
local function remove_owned(path)
	local stat = assert(uv.fs_lstat(path))
	if stat.type == "directory" then
		for name in uv.fs_scandir_next, assert(uv.fs_scandir(path)) do remove_owned(path .. "/" .. name) end
		assert(uv.fs_rmdir(path))
	else assert(uv.fs_unlink(path)) end
end
remove_owned(root)
assert(checks == 21, "native category transaction regression check floor changed")
print(string.format("Native SQLite category transactions: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
