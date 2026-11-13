--- tests/hardware/run_sqlite_device_schema_receipts.lua
--- ==============================================================================
--- MODULE: Native Linux SQLite Device Schema Receipts
--- DESCRIPTION:
--- Opens private canonical and legacy databases through the production writer.
--- A real libsqlite3 read transaction proves current device registries need no
--- write lock or destructive migration when the daemon opens its metrics store.
--- No database, process, filesystem or parser adapter is mocked.
--- ==============================================================================

local uv = require("luv")
local ffi = require("ffi")
local Writer = require("metrics.engine.journal.sqlite_writer")
ffi.cdef[[
typedef struct sqlite3 sqlite3;
int sqlite3_open_v2(const char *, sqlite3 **, int, const char *);
int sqlite3_exec(sqlite3 *, const char *, void *, void *, char **);
int sqlite3_close(sqlite3 *);
]]
local sqlite = ffi.load("libsqlite3.so.0")
if arg[1] == "--hold-read" then
	local handle = ffi.new("sqlite3 *[1]")
	assert(sqlite.sqlite3_open_v2(assert(arg[2]), handle, 1, nil) == 0)
	assert(sqlite.sqlite3_exec(handle[0], "BEGIN; SELECT name FROM devices;", nil, nil, nil) == 0)
	io.stdout:write("READY\n")
	io.stdout:flush()
	io.stdin:read("*a")
	assert(sqlite.sqlite3_exec(handle[0], "ROLLBACK;", nil, nil, nil) == 0)
	assert(sqlite.sqlite3_close(handle[0]) == 0)
	os.exit(0)
end
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-device-schema-XXXXXX"))
local database = root .. "/metrics.sqlite"
local checks, failures = 0, 0
assert(Writer.open_db(database), "actual canonical schema must bootstrap")
assert(Writer.exec_sql("INSERT INTO devices VALUES ('native','Original','linux','','signature','created','updated',37,'digest');"))
assert(Writer.exec_sql("CREATE INDEX owned_device_name ON devices(name);"))
assert(Writer.exec_sql("CREATE TRIGGER owned_device_update AFTER UPDATE ON devices BEGIN SELECT 1; END;"))

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

check("current multiline Linux registry reopens without any schema mutation", function()
	local before = assert(Writer.query_rows("PRAGMA schema_version;"))[1]
	Writer.close_db()
	assert(Writer.open_db(database))
	local after = assert(Writer.query_rows("PRAGMA schema_version;"))[1]
	assert(after == before, "already-current schema was rebuilt: " .. before .. " -> " .. after)
end)

check("reopening preserves device indexes, triggers and imported metadata", function()
	local indexes = assert(Writer.query_rows("SELECT name FROM sqlite_master WHERE name='owned_device_name';"))
	assert(#indexes == 1 and indexes[1] == "owned_device_name", "device index lost during opening")
	local triggers = assert(Writer.query_rows("SELECT name FROM sqlite_master WHERE name='owned_device_update';"))
	assert(#triggers == 1 and triggers[1] == "owned_device_update", "device trigger lost during opening")
	local rows = assert(Writer.query_rows("SELECT name,created_at,imported_data_sql_size,imported_data_sql_sha256 FROM devices WHERE device_id='native';"))
	assert(#rows == 1 and rows[1] == "Original|created|37|digest", "device data changed during opening")
end)

check("current registry opens while a genuine native reader holds a shared lock", function()
	-- POSIX locks belong to the process: the writer's existence probe closes
	-- another descriptor on this inode and releases same-process FFI locks.
	-- A separate real reader keeps its lock across that production probe.
	local input, output = uv.new_pipe(false), uv.new_pipe(false)
	local ready, finished, status = false, false, nil
	local process
	process = assert(uv.spawn("luajit", {
		args = { arg[0], "--hold-read", database }, stdio = { input, output, 2 },
	}, function(code)
		finished, status = true, code
		process:close()
	end))
	output:read_start(function(err, bytes)
		assert(not err, err)
		if bytes then ready = ready or bytes:find("READY\n", 1, true) ~= nil end
	end)
	local deadline, expired = uv.new_timer(), false
	deadline:start(5000, 0, function() expired = true end)
	while not ready and not finished and not expired do uv.run("once") end
	deadline:stop()
	deadline:close()
	Writer.close_db()
	local ok, err = pcall(function()
		assert(ready and not finished, "independent native reader did not acquire its shared lock")
		assert(Writer.open_db(database), "opening current registry unnecessarily requires a write lock")
		local rows = assert(Writer.query_rows("SELECT name FROM devices WHERE device_id='native';"))
		assert(#rows == 1 and rows[1] == "Original", "concurrent native reader changed the projection")
	end)
	input:shutdown(function() input:close() end)
	if expired then process:kill("sigterm") end
	while not finished do uv.run("once") end
	output:read_stop()
	output:close()
	uv.run("nowait")
	assert(status == 0, "native reader process failed")
	assert(ok, err)
end)

check("legacy registry still upgrades and preserves existing device metadata", function()
	assert(Writer.open_db(database))
	assert(Writer.exec_sql([[
BEGIN;
ALTER TABLE devices RENAME TO devices_current;
CREATE TABLE devices (
 device_id TEXT PRIMARY KEY, name TEXT NOT NULL,
 os TEXT NOT NULL CHECK(os IN ('darwin','windows')), os_version TEXT,
 host_signature TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
 imported_data_sql_size INTEGER NOT NULL DEFAULT 0, imported_data_sql_sha256 TEXT
);
INSERT INTO devices VALUES ('legacy','Legacy','darwin','1','legacy-signature','first','last',53,'legacy-digest');
DROP TABLE devices_current;
COMMIT;
]]))
	Writer.close_db()
	assert(Writer.open_db(database), "real legacy schema failed to migrate")
	-- The store already held the shipped purge triggers, which read devices:
	-- the upgrade drops them and the same open recreates them on the new table.
	local purge_file = assert(io.open("../_shared/metrics/data/db/purge_schema.sql", "rb"))
	local purge = assert(purge_file:read("*a")); assert(purge_file:close())
	local _, shipped = purge:gsub("CREATE TRIGGER IF NOT EXISTS [%w_]+", "")
	local triggers = assert(Writer.query_rows("SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name LIKE 'metrics_purge_%' AND sql NOT LIKE '%devices_pre_linux%';"))
	assert(shipped > 0 and tonumber(triggers[1]) == shipped, "the purge triggers must survive the registry upgrade on devices")
	local rows = assert(Writer.query_rows("SELECT name,created_at,imported_data_sql_size,imported_data_sql_sha256 FROM devices WHERE device_id='legacy';"))
	assert(#rows == 1 and rows[1] == "Legacy|first|53|legacy-digest")
	Writer.register_device("new-linux", "Native", "linux", "", "native-signature")
	local registered = assert(Writer.query_rows("SELECT os FROM devices WHERE device_id='new-linux';"))
	assert(#registered == 1 and registered[1] == "linux", "upgraded registry still rejects Linux")
	local before = assert(Writer.query_rows("PRAGMA schema_version;"))[1]
	Writer.close_db()
	assert(Writer.open_db(database))
	assert(assert(Writer.query_rows("PRAGMA schema_version;"))[1] == before, "legacy migration repeated after succeeding")
end)

check("shipped legacy DDL migrates with a real SQLite database", function()
	Writer.close_db()
	local schema_file = assert(io.open("../_shared/metrics/data/db/schema.sql", "rb"))
	local schema = assert(schema_file:read("*a")); assert(schema_file:close())
	local ddl = assert(schema:match("(CREATE TABLE IF NOT EXISTS devices%s*%b())%s*;"))
	local legacy, replacements = ddl:gsub(",%s*'linux'", "", 1)
	assert(replacements == 1, "canonical legacy transform must remove one Linux value")
	-- The whole shipped store with only the registry's old CHECK, as a store from
	-- before Linux holds the event tables the purge triggers of the open read.
	local start, finish = assert(schema:find(ddl, 1, true))
	local historical = schema:sub(1, start - 1) .. legacy .. schema:sub(finish + 1)
	local path = root .. "/historical.sqlite"
	local handle = ffi.new("sqlite3 *[1]")
	assert(sqlite.sqlite3_open_v2(path, handle, 6, nil) == 0)
	assert(sqlite.sqlite3_exec(handle[0], historical, nil, nil, nil) == 0)
	assert(sqlite.sqlite3_close(handle[0]) == 0)
	assert(Writer.open_db(path), "the actual shipped legacy DDL must migrate")
	Writer.close_db()
end)

check("unknown legacy CHECK is refused and retained", function()
	local path = root .. "/extra-check.sqlite"
	local handle = ffi.new("sqlite3 *[1]")
	assert(sqlite.sqlite3_open_v2(path, handle, 6, nil) == 0)
	local ddl = [[CREATE TABLE devices (
 device_id TEXT PRIMARY KEY, name TEXT NOT NULL CHECK(length(name)>0),
 os TEXT NOT NULL CHECK(os IN ('darwin','windows')), os_version TEXT,
 host_signature TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
 imported_data_sql_size INTEGER NOT NULL DEFAULT 0, imported_data_sql_sha256 TEXT
);]]
	assert(sqlite.sqlite3_exec(handle[0], ddl, nil, nil, nil) == 0)
	assert(sqlite.sqlite3_close(handle[0]) == 0)
	assert(Writer.open_db(path) == false, "unrecognized CHECK cannot be dropped")
	assert(sqlite.sqlite3_open_v2(path, handle, 2, nil) == 0)
	local inserted = sqlite.sqlite3_exec(handle[0], [[INSERT INTO devices VALUES
 ('id','','darwin','','host','created','updated',0,'');]], nil, nil, nil)
	assert(inserted ~= 0, "the original CHECK remains enforced")
	assert(sqlite.sqlite3_close(handle[0]) == 0)
end)

check("refused Linux registration leaves legacy n-gram keys untouched", function()
	Writer.close_db()
	local path = root .. "/registration-refused.sqlite"
	assert(Writer.open_db(path))
	assert(Writer.register_device("legacy", "Legacy", "darwin", "", "fixture"))
	assert(Writer.exec_sql([[INSERT INTO ngram_chars (device_id,date,app,token,c,td,e,esrc_json)
 VALUES ('legacy','2026-10-01','owned','[',1,0,0,'{}');]]))
	assert(Writer.exec_sql([[BEGIN;
ALTER TABLE devices RENAME TO devices_current;
CREATE TABLE devices (
 device_id TEXT PRIMARY KEY, name TEXT NOT NULL CHECK(name <> 'linux'),
 os TEXT NOT NULL CHECK(os IN ('darwin','windows')), os_version TEXT,
 host_signature TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
 imported_data_sql_size INTEGER NOT NULL DEFAULT 0, imported_data_sql_sha256 TEXT
);
INSERT INTO devices SELECT * FROM devices_current;
DROP TABLE devices_current;
DELETE FROM meta WHERE key='ngram_token_encoding';
COMMIT;]]))
	Writer.close_db()
	local k = require("metrics.engine.keystats")
	require("tests.support.metrics_preferences_fixture").with(function()
		assert(k.init({ sqlite_path = path, log_dir = root }) == false)
		assert(k.get_privacy_state().storage_blocked == true)
	end)
	assert(Writer.open_db(path), "direct open still admits this unrecognized registry")
	local keys = assert(Writer.query_rows("SELECT hex(token) FROM ngram_chars;"))
	assert(#keys == 1 and keys[1] == "5B", "registration refusal cannot rewrite legacy key bytes")
	local marker = assert(Writer.query_rows("SELECT value FROM meta WHERE key='ngram_token_encoding';"))
	assert(#marker == 0, "registration refusal cannot record a migration")
	Writer.close_db()
end)

check("Linux in a comment cannot cause legacy n-gram migration", function()
	Writer.close_db()
	local path = root .. "/comment-refused.sqlite"
	assert(Writer.open_db(path))
	assert(Writer.register_device("legacy", "Legacy", "darwin", "", "fixture"))
	assert(Writer.exec_sql([[INSERT INTO ngram_chars (device_id,date,app,token,c,td,e,esrc_json)
 VALUES ('legacy','2026-10-01','owned','[',1,0,0,'{}');]]))
	assert(Writer.exec_sql([[BEGIN;
ALTER TABLE devices RENAME TO devices_current;
CREATE TABLE devices (
 device_id TEXT PRIMARY KEY, name TEXT NOT NULL /* linux */,
 os TEXT NOT NULL CHECK(os IN ('darwin','windows')), os_version TEXT,
 host_signature TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
 imported_data_sql_size INTEGER NOT NULL DEFAULT 0, imported_data_sql_sha256 TEXT
);
INSERT INTO devices SELECT * FROM devices_current;
DROP TABLE devices_current;
DELETE FROM meta WHERE key='ngram_token_encoding';
COMMIT;]]))
	Writer.close_db()
	local k = require("metrics.engine.keystats")
	require("tests.support.metrics_preferences_fixture").with(function()
		assert(k.init({ sqlite_path = path, log_dir = root }) == false)
		assert(k.get_privacy_state().storage_blocked == true)
	end)
	assert(Writer.open_db(path), "direct open still admits this unrecognized registry")
	local keys = assert(Writer.query_rows("SELECT hex(token) FROM ngram_chars;"))
	assert(#keys == 1 and keys[1] == "5B", "registration refusal cannot rewrite legacy key bytes")
	local marker = assert(Writer.query_rows("SELECT value FROM meta WHERE key='ngram_token_encoding';"))
	assert(#marker == 0, "registration refusal cannot record a migration")
	Writer.close_db()
end)

Writer.close_db()
for name in uv.fs_scandir_next, assert(uv.fs_scandir(root)) do assert(uv.fs_unlink(root .. "/" .. name)) end
assert(uv.fs_rmdir(root))
print(string.format("Native SQLite device schema receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
