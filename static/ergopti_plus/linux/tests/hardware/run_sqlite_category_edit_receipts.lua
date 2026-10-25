--- tests/hardware/run_sqlite_category_edit_receipts.lua
--- ==============================================================================
--- MODULE: Native App Category Store and SQLite Import (Linux)
--- DESCRIPTION:
--- Drives the real dashboard bridge, keystats and SQLite writer against owned
--- native databases and an owned configuration folder. The categories live in
--- the shared category file; the old store (a score in `meta`, the category on
--- the day rows) is imported by a native SQLite read and then deleted. Truthful
--- saved replies, untouched bytes after a refusal and the one-time import are the
--- oracles. No UI or physical input is simulated as hardware validation: the
--- bridge is called directly, with real storage.
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

local Writer = require("modules.keystats.sqlite_writer")
local Bridge = require("ui.metrics_apps.bridge")
local case_index = 0

local function check(name, fn)
	checks = checks + 1
	local ok, reason = xpcall(fn, debug.traceback)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(reason) .. "\n")
	end
end

local Store = require("keystats.app_category_store")
local Json = require("json")
local category_path = root .. "/config/ergopti/" .. Store.FILE_NAME

local function read_category_file()
	local file = io.open(category_path, "rb")
	if not file then return nil end
	local text = file:read("*a")
	file:close()
	return text
end

local function start(legacy_app)
	case_index = case_index + 1
	Writer.close_db()
	package.loaded["modules.keystats.keystats"] = nil
	package.loaded["modules.keystats.app_category_file"] = nil
	local keystats = require("modules.keystats.keystats")
	local path = root .. "/case-" .. case_index .. ".sqlite"
	if legacy_app then
		-- The previous store: a score in meta and the category on the day rows.
		local hostname = assert(io.open("/proc/sys/kernel/hostname")):read("*l"):gsub("%s+", "")
		local device = "linux-" .. hostname
		assert(Writer.open_db(path))
		Writer.register_device(device, hostname, "linux", "", hostname)
		assert(Writer.upsert_app_day(device, "2000-01-01", legacy_app, { chars = 3 }))
		assert(Writer.exec_sql("UPDATE agg_app_day SET category='Legacy category';"))
		assert(Writer.set_meta("app_score." .. legacy_app, "-1"))
		Writer.close_db()
	end
	keystats.init({ sqlite_path = path, log_dir = root .. "/logs" })
	assert(keystats.is_enabled() and Writer.is_available())
	return keystats, path
end

check("a bridge edit is stored in the shared category file and echoed to the page", function()
	local keystats = start()
	local reply = Bridge.on_message({ action = "edit", app = "owned ' été app", cat = "Updated 😀", score = 2 }, { keystats = keystats })
	assert(reply.saved == true)
	assert(reply.user_categories["owned ' été app"].type == "Updated 😀" and reply.user_categories["owned ' été app"].score == 2)
	local stored = assert(Store.decode(read_category_file(), Json.decode))
	assert(stored.legacy == false and stored.apps["owned ' été app"].score == 2)
end)

check("an out of range score is refused and the file bytes are unchanged", function()
	local keystats = start()
	local before = read_category_file()
	local reply = Bridge.on_message({ action = "edit", app = "owned-app", cat = "Updated", score = 9 }, { keystats = keystats })
	assert(reply.saved == false)
	assert(read_category_file() == before)
end)

check("a corrupt category file refuses the edit and the dashboard instead of reading an empty store", function()
	local keystats = start()
	local good = read_category_file()
	local file = assert(io.open(category_path, "wb"))
	assert(file:write("{PRIVATE-CORRUPT") and file:close())
	local reply = Bridge.on_message({ action = "edit", app = "owned-app", cat = "Updated", score = 1 }, { keystats = keystats })
	assert(reply == nil or reply.saved == false, "the page was told the edit was stored")
	assert(read_category_file() == "{PRIVATE-CORRUPT")
	assert(keystats.get_dashboard_payload({ include_prefetch = false }) == nil)
	file = assert(io.open(category_path, "wb"))
	assert(file:write(good) and file:close())
end)

check("the old SQLite store is imported once, the file's own edit wins and the database sheds it", function()
	local keystats, path = start("legacy-app")
	local imported = assert(Store.decode(read_category_file(), Json.decode))
	assert(imported.apps["legacy-app"].type == "Legacy category" and imported.apps["legacy-app"].score == -1)
	assert(imported.apps["owned ' été app"].score == 2, "the import replaced an entry already in the file")
	assert(#assert(Writer.query_rows("SELECT key FROM meta WHERE key LIKE 'app_score.%';")) == 0,
		"the imported scores stayed in the database")
	local payload = assert(keystats.get_dashboard_payload({ include_prefetch = false }))
	assert(payload.user_categories["legacy-app"].type == "Legacy category")
	assert(path == Writer.get_db_path())
end)

check("a new collector recovers the stored categories", function()
	local keystats = start()
	Bridge._reset()
	local ready = assert(Bridge.on_message("ready", { keystats = keystats }))
	assert(ready.user_categories["legacy-app"].score == -1)
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
assert(checks == 5, "native category store regression check floor changed")
print(string.format("Native app category store: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
