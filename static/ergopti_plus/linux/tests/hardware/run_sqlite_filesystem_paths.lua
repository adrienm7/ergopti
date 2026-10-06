--- tests/hardware/run_sqlite_filesystem_paths.lua
--- ==============================================================================
--- MODULE: Native SQLite Filesystem Path Regression (Linux)
--- DESCRIPTION:
--- Exercises public keylogger initialization, dashboard reads and native writes
--- against distinct owned literal and URI-decoy databases. Files, sqlite3 and
--- process exit receipts are real; explicit keylogger events are software calls,
--- not physical keyboard input. No CLI wrapper or filesystem adapter is mocked.
--- ==============================================================================

local uv = require("luv")
require("compat.utf8").install()
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-sqlite-filesystem-paths-XXXXXX"))
local initial_cwd = assert(uv.cwd())
package.path = initial_cwd .. "/?.lua;" .. initial_cwd .. "/?/init.lua;"
	.. initial_cwd .. "/../_shared/lua/?.lua;" .. initial_cwd .. "/../_shared/lua/?/init.lua;" .. package.path
local original_xdg = {}
local checks, failures = 0, 0

local function write(path, content)
	local file = assert(io.open(path, "wb"))
	assert(file:write(content) and file:close())
end

local function read(path)
	local file = assert(io.open(path, "rb"))
	local content = assert(file:read("*a"))
	assert(file:close())
	return content
end

for _, name in ipairs({ "CONFIG", "DATA", "CACHE", "STATE" }) do
	local variable = "XDG_" .. name .. "_HOME"
	original_xdg[variable] = os.getenv(variable) or false
	assert(uv.os_setenv(variable, root .. "/" .. name:lower()))
end
assert(uv.fs_mkdir(root .. "/config", 448))
assert(uv.fs_mkdir(root .. "/config/ergopti", 448))
write(root .. "/config/ergopti/config.toml", "[metrics]\nenabled = true\n")

local Writer = require("modules.keylogger.sqlite_writer")
local Reader = require("modules.keylogger.sqlite_reader")
-- Resolve and load production owners before entering the owned database cwd.
require("infra.paths")
require("modules.keylogger.keylogger")

local function check(name, fn)
	checks = checks + 1
	local ok, reason = xpcall(fn, debug.traceback)
	Writer.close_db()
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(reason) .. "\n")
	end
end

local function seed(path, chars)
	assert(Writer.open_db(path), "absolute native fixture bootstrap failed")
	Writer.upsert_app_day("owned-device", "2000-01-01", "owned-app", { chars = chars })
	Writer.close_db()
end

local function chars(path)
	local manifest = Reader.read_manifest(path)
	return manifest["2000-01-01"] and manifest["2000-01-01"]["owned-app"]
		and manifest["2000-01-01"]["owned-app"].chars
end

local cases = {
	{ "URI filename", "file:owned.sqlite", "owned.sqlite" },
	{ "URI percent encoding", "file:encoded%20name.sqlite", "encoded name.sqlite" },
	{ "URI read-only query", "file:query.sqlite?mode=ro", "query.sqlite" },
	{ "URI fragment", "file:fragment.sqlite#tail", "fragment.sqlite" },
	{ "memory token", ":memory:" },
	{ "dash filename", "-owned.sqlite" },
	{ "ordinary", "ordinary.sqlite" },
	{ "UTF-8 and quote", "été ' literal.sqlite" },
	{ "explicit relative", "./file:explicit.sqlite" },
	{ "nested relative", "nested/file:owned.sqlite" },
}

for index, case in ipairs(cases) do
	local directory = root .. "/case-" .. index
	assert(uv.fs_mkdir(directory, 448))
	assert(uv.fs_mkdir(directory .. "/nested", 448))
	local literal = directory .. "/" .. case[2]
	local decoy = case[3] and directory .. "/" .. case[3]
	seed(literal, 3)
	if decoy then seed(decoy, 7) end
	local decoy_before = decoy and read(decoy)
	assert(uv.chdir(directory))

	check(case[1] .. " public Reader selects the intended literal database", function()
		assert(chars(literal) == 3, "independent absolute baseline changed")
		assert(chars(case[2]) == 3, "relative Reader selected a decoy or a special database")
	end)

	check(case[1] .. " public keylogger dashboard keeps the admitted file identity", function()
		package.loaded["modules.keylogger.keylogger"] = nil
		local Keylogger = require("modules.keylogger.keylogger")
		Keylogger.init({ sqlite_path = case[2], log_dir = directory .. "/logs" })
		assert(Keylogger.is_enabled() and Writer.is_available(), "native public initialization refused the literal file")
		assert(Writer.get_db_path() == case[2], "public diagnostic spelling changed")
		local manifest = Keylogger.get_dashboard_payload({ include_prefetch = false }).metrics_manifest
		assert(manifest["2000-01-01"] and manifest["2000-01-01"]["owned-app"].chars == 3,
			"dashboard read a different database from its selected filesystem path")
	end)

	check(case[1] .. " native write updates only the literal file", function()
		assert(Writer.open_db(case[2]), "native literal write target could not open")
		Writer.upsert_app_day("owned-device", "2000-01-01", "owned-app", { chars = 5 })
		Writer.close_db()
		assert(chars(literal) == 8, "native update did not reach the intended literal database")
		if decoy then
			assert(chars(decoy) == 7 and read(decoy) == decoy_before,
				"read/write initialization mutated the unrelated URI-decoy database")
		end
	end)
end

assert(uv.chdir(root))
seed(root .. "/refused.sqlite", 7)
local decoy_before = read(root .. "/refused.sqlite")
write(root .. "/file:refused.sqlite", "owned non-database bytes\n")
check("native corrupt literal read refuses without borrowing decoy rows", function()
	assert(next((Reader.read_manifest("file:refused.sqlite"))) == nil, "corrupt literal returned decoy rows")
	assert(read(root .. "/file:refused.sqlite") == "owned non-database bytes\n")
	assert(read(root .. "/refused.sqlite") == decoy_before)
end)
check("native corrupt literal write refuses without borrowing decoy storage", function()
	assert(not Writer.open_db("file:refused.sqlite"), "corrupt literal opened an unrelated valid URI target")
	assert(not Writer.is_available(), "failed open retained a usable database")
	assert(read(root .. "/file:refused.sqlite") == "owned non-database bytes\n")
	assert(read(root .. "/refused.sqlite") == decoy_before)
end)

seed(root .. "/missing.sqlite", 7)
local missing_decoy_before = read(root .. "/missing.sqlite")
check("read-only missing literal never returns its existing URI decoy", function()
	assert(next((Reader.read_manifest("file:missing.sqlite"))) == nil, "absent literal returned unrelated rows")
	assert(not uv.fs_lstat(root .. "/file:missing.sqlite"), "read-only access created a literal database")
	assert(read(root .. "/missing.sqlite") == missing_decoy_before)
end)
check("native first open creates the selected literal file only", function()
	assert(Writer.open_db("file:new.sqlite"))
	Writer.upsert_app_day("owned-device", "2000-01-01", "owned-app", { chars = 11 })
	Writer.close_db()
	assert(uv.fs_lstat(root .. "/file:new.sqlite"), "first open created the URI target instead")
	assert(not uv.fs_lstat(root .. "/new.sqlite"), "first open created an unrelated URI target")
	assert(chars(root .. "/file:new.sqlite") == 11)
end)

seed(root .. "/file:public.sqlite", 3)
seed(root .. "/public.sqlite", 7)
local public_decoy_before = read(root .. "/public.sqlite")
check("public software keylogger events flush into the selected literal database", function()
	package.loaded["modules.keylogger.keylogger"] = nil
	local Keylogger = require("modules.keylogger.keylogger")
	Keylogger.init({ sqlite_path = "file:public.sqlite", log_dir = root .. "/logs" })
	assert(Writer.is_available())
	local now = require("infra.monotonic").now_ms()
	Keylogger.on_keydown("a", now, "public-owned-app")
	Keylogger.on_keydown("b", now + 100, "public-owned-app")
	Keylogger.flush()
	Writer.close_db()
	assert(Writer.open_db(root .. "/file:public.sqlite"))
	local rows = assert(Writer.query_rows("SELECT text FROM events_typing WHERE app='public-owned-app';"))
	assert(#rows == 1 and rows[1] == "ab", "public flush wrote raw event bytes to the URI-decoy database")
	assert(read(root .. "/public.sqlite") == public_decoy_before, "public flush changed the decoy database")
end)

assert(uv.chdir(initial_cwd))
for variable, value in pairs(original_xdg) do
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
assert(checks == 35, "native regression check floor changed")
print(string.format("Native SQLite filesystem paths: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
