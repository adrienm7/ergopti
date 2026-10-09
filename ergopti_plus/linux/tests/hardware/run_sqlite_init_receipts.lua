--- tests/hardware/run_sqlite_init_receipts.lua
--- ==============================================================================
--- MODULE: Native Linux SQLite Initialization Receipts
--- DESCRIPTION:
--- Uses an actual ordinary user's deliberately provisioned .sqliterc profile.
--- Run only in an owned disposable account/container with sqlite_profile.conf
--- installed as its .sqliterc. No HOME override, simulated init path, transport
--- or database adapter is used. Host personal profiles must never be replaced.
--- ==============================================================================

local uv = require("luv")
local Shell = require("adapters.shell_runner")
local Paths = require("infra.paths")
local Command = require("modules.keylogger.sqlite_command")
local Writer = require("modules.keylogger.sqlite_writer")
local Reader = require("modules.keylogger.sqlite_reader")
local Json = require("json")
assert(uv.getuid() ~= 0, "profile receipts require an ordinary account")
local home = assert(os.getenv("HOME"), "actual login home is required")
local profile = assert(io.open(home .. "/.sqliterc", "rb"))
local contents = assert(profile:read("*a")); assert(profile:close())
local corpus = assert(io.open("tests/hardware/fixtures/sqlite_profile.conf", "rb"))
local expected = assert(corpus:read("*a")); assert(corpus:close())
assert(contents == expected, "profile must be the deliberately provisioned owned fixture")
local marker = home .. "/.ergopti_sqliterc_invoked"
assert(not uv.fs_lstat(marker), "owned profile marker already exists before any native call")
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-sqlite-init-XXXXXX"))
local database = root .. "/seeded.sqlite"
local checks, failures = 0, 0
local schema = assert(io.open(assert(Paths.shared_root()) .. "/data/db/schema.sql", "rb"))
local sql = assert(schema:read("*a")); assert(schema:close())
-- Seed independently of the builder under test. Explicit native init isolation
-- is the control proving the fixture itself has usable schema and exact data.
sql = sql .. "\nINSERT INTO agg_system_day(device_id,date,wifi_changes) VALUES ('native','2026-10-04',42);"
local seeded = Shell.run(Shell.with_stdin("sqlite3 -init /dev/null " .. Shell.quote(database) .. " >/dev/null", sql))
assert(seeded and not uv.fs_lstat(marker), "independent native seed failed or loaded personal init")

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

check("native personal init cannot prevent metrics bootstrap", function()
	local accepted = Writer.open_db(root .. "/new.sqlite")
	Writer.close_db()
	assert(accepted, "personal init output prevented genuine schema acknowledgement")
end)

check("native personal init cannot change JSON mode or prefix the wire body", function()
	local command = assert(Command.build(database, "SELECT wifi_changes FROM agg_system_day;", { flags = { "-json" }, capture_exit = true }))
	local ran, output = Shell.exec_checked(command)
	assert(ran, "native command did not complete")
	local accepted, body = Command.read_exit_receipt(output)
	assert(accepted, "native SQL receipt was lost")
	local decoded, rows = pcall(Json.decode, body)
	assert(decoded and type(rows) == "table" and #rows == 1 and rows[1].wifi_changes == 42,
		"inherited personal mode/output changed the native JSON ABI")
end)

check("native personal init cannot hide existing dashboard data", function()
	local result = Reader.read_system_days(database, "2026-10-04", "2026-10-04")
	assert(result["2026-10-04"] and result["2026-10-04"].wifi_changes == 42,
		"valid native database projected empty after personal init")
end)

check("native application commands never execute owned personal init", function()
	assert(not uv.fs_lstat(marker), "application CLI executed the personal .shell directive")
end)

Writer.close_db()
if uv.fs_lstat(marker) then assert(uv.fs_unlink(marker)) end
for name in uv.fs_scandir_next, assert(uv.fs_scandir(root)) do assert(uv.fs_unlink(root .. "/" .. name)) end
assert(uv.fs_rmdir(root))
print(string.format("Native SQLite init receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
