--- tests/hardware/run_sqlite_device_registration_receipts.lua
--- ==============================================================================
--- MODULE: Native Linux SQLite Device Registration Receipts
--- DESCRIPTION:
--- Genuine collector startups refresh device metadata without replacing the
--- existing registry row. Creation/import fields, schema extras and triggers
--- survive native updates and refused-write retry. All databases/profiles are
--- owned; no database, process, filesystem or parser adapter is mocked.
--- ==============================================================================

local uv = require("luv")
require("compat.utf8").install()
if arg[1] == "--owned-startup" then
	local Keylogger = require("modules.keylogger.keylogger")
	Keylogger.init({ sqlite_path = assert(arg[2]), log_dir = assert(arg[3]) })
	assert(Keylogger.is_enabled())
	require("modules.keylogger.sqlite_writer").close_db()
	os.exit(0)
end
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-registration-receipts-XXXXXX"))
for _, name in ipairs({ "CONFIG", "DATA", "CACHE", "STATE" }) do
	assert(uv.os_setenv("XDG_" .. name .. "_HOME", root .. "/" .. name:lower()))
end
assert(uv.fs_mkdir(root .. "/config", 448))
assert(uv.fs_mkdir(root .. "/config/ergopti", 448))
local config = assert(io.open(root .. "/config/ergopti/config.toml", "w"))
assert(config:write("[metrics]\nenabled = true\n") and config:close())
local Keylogger = require("modules.keylogger.keylogger")
local Writer = require("modules.keylogger.sqlite_writer")
local database = root .. "/metrics.sqlite"
local checks, failures = 0, 0
Keylogger.init({ sqlite_path = database, log_dir = root .. "/logs" })
assert(Keylogger.is_enabled())
local device = assert(assert(Writer.query_rows("SELECT device_id FROM devices;"))[1])
local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end
local function rows(sql)
	return table.concat(assert(Writer.query_rows(sql)), "\n")
end
local function immutable()
	return rows("SELECT created_at,imported_data_sql_size,imported_data_sql_sha256,owned_extra FROM devices WHERE device_id='" .. device .. "';")
end
local function snapshot()
	return rows("SELECT hex(device_id),hex(name),hex(os),hex(os_version),hex(host_signature),hex(created_at),hex(updated_at),"
		.. "imported_data_sql_size,hex(imported_data_sql_sha256),hex(owned_extra) FROM devices WHERE device_id='" .. device .. "';")
end
local function child_startup()
	local status, child
	child = assert(uv.spawn(arg[-1], { args = { arg[0], "--owned-startup", database, root .. "/child-logs" },
		stdio = { nil, 1, 2 } }, function(code) status = code; child:close() end))
	uv.run()
	assert(status == 0, "owned real collector startup failed")
end
assert(Writer.exec_sql("ALTER TABLE devices ADD COLUMN owned_extra TEXT DEFAULT 'owned-default';"))
assert(Writer.exec_sql("UPDATE devices SET name='Old name',os_version='old-version',host_signature='old-signature',"
	.. "created_at='2000-01-01T00:00:00Z',updated_at='2000-01-02T00:00:00Z',"
	.. "imported_data_sql_size=37,imported_data_sql_sha256='owned-digest',owned_extra='owned-extra';"))
assert(Writer.exec_sql("CREATE INDEX owned_registration_name ON devices(name);"))
assert(Writer.exec_sql("CREATE TABLE owned_registration_audit (device TEXT, name TEXT);"))
assert(Writer.exec_sql("CREATE TRIGGER owned_registration_update AFTER UPDATE ON devices "
	.. "BEGIN INSERT INTO owned_registration_audit VALUES (NEW.device_id,NEW.name); END;"))
local expected_immutable = "2000-01-01T00:00:00Z|37|owned-digest|owned-extra"
local schema_version = rows("PRAGMA schema_version;")
child_startup()
check("genuine collector startup preserves creation/import metadata and schema extras", function()
	assert(immutable() == expected_immutable, "startup replaced durable fields it does not own")
end)
check("genuine collector startup refreshes mutable native host metadata", function()
	local hostname = device:sub(#"linux-" + 1)
	assert(rows("SELECT name,os,os_version,host_signature FROM devices;") == hostname .. "|linux||" .. hostname)
	assert(rows("SELECT updated_at FROM devices;") ~= "2000-01-02T00:00:00Z")
end)
check("registration preserves schema/index/trigger and actually fires its update trigger", function()
	assert(rows("PRAGMA schema_version;") == schema_version)
	assert(rows("SELECT count(*) FROM sqlite_master WHERE name IN ('owned_registration_name','owned_registration_update');") == "2")
	assert(rows("SELECT count(*) FROM owned_registration_audit;") == "1", "replacement bypassed the existing update trigger")
end)
Writer.close_db()
assert(Writer.open_db(database))
child_startup()
check("a later reopen/startup retains immutable fields and exactly one device row", function()
	assert(immutable() == expected_immutable)
	assert(rows("SELECT count(*) FROM devices;") == "1")
	assert(rows("SELECT count(*) FROM owned_registration_audit;") == "2")
end)
local before = snapshot()
assert(Writer.exec_sql("CREATE TRIGGER owned_registration_refusal BEFORE UPDATE ON devices "
	.. "BEGIN SELECT RAISE(FAIL,'owned registration refusal'); END;"))
check("native registration refusal is acknowledged and leaves the existing row byte-identical", function()
	assert(Writer.register_device(device, "Refused name", "linux", "new-version", "new-signature") == false)
	assert(snapshot() == before, "refused registration changed an existing field")
	assert(rows("SELECT count(*) FROM owned_registration_audit;") == "2")
end)
assert(Writer.exec_sql("DROP TRIGGER owned_registration_refusal;"))
check("healthy retry refreshes only mutable fields through the real CLI", function()
	assert(Writer.register_device(device, "Fresh' name", "linux", "new-version", "new-signature") == true)
	assert(immutable() == expected_immutable)
	assert(rows("SELECT name,os_version,host_signature FROM devices;") == "Fresh' name|new-version|new-signature")
	assert(rows("SELECT count(*) FROM owned_registration_audit;") == "3")
end)
check("first registration still inserts a new native row with normal defaults", function()
	assert(Writer.register_device("owned-new-device", "New", "linux", "1", "new-host") == true)
	assert(rows("SELECT name,os,os_version,host_signature,imported_data_sql_size,owned_extra FROM devices "
		.. "WHERE device_id='owned-new-device';") == "New|linux|1|new-host|0|owned-default")
	assert(rows("SELECT created_at=updated_at,imported_data_sql_sha256 IS NULL FROM devices WHERE device_id='owned-new-device';") == "1|1")
end)
assert(Writer.exec_sql("CREATE TABLE owned_registration_refusal_audit (name TEXT);"))
assert(Writer.exec_sql("CREATE TRIGGER owned_registration_after_refusal AFTER UPDATE ON devices "
	.. "BEGIN INSERT INTO owned_registration_refusal_audit VALUES (NEW.name); "
	.. "SELECT RAISE(FAIL,'owned after-update refusal'); END;"))
local before_after_failure = snapshot()
local before_audit_count = rows("SELECT count(*) FROM owned_registration_audit;")
check("AFTER UPDATE refusal rolls back the mutable row and trigger side effects", function()
	assert(Writer.register_device(device, "After-refused name", "linux", "refused-version", "refused-signature") == false)
	assert(snapshot() == before_after_failure, "false registration receipt retained a partially updated row")
	assert(rows("SELECT count(*) FROM owned_registration_refusal_audit;") == "0", "refused trigger side effect persisted")
	assert(rows("SELECT count(*) FROM owned_registration_audit;") == before_audit_count)
end)
assert(Writer.exec_sql("DROP TRIGGER owned_registration_after_refusal;"))
check("healthy retry after AFTER UPDATE refusal commits only mutable fields", function()
	assert(Writer.register_device(device, "After-healthy name", "linux", "healthy-version", "healthy-signature") == true)
	assert(immutable() == expected_immutable)
	assert(rows("SELECT name,os_version,host_signature FROM devices WHERE device_id='" .. device .. "';")
		== "After-healthy name|healthy-version|healthy-signature")
end)
check("a real shared reader refuses registration COMMIT without row or trigger mutation", function()
	local input, output = uv.new_pipe(false), uv.new_pipe(false)
	local ready, finished, status = false, false, nil
	local process
	process = assert(uv.spawn(arg[-1], {
		args = { "tests/hardware/run_sqlite_device_schema_receipts.lua", "--hold-read", database },
		stdio = { input, output, 2 },
	}, function(code) finished, status = true, code; process:close() end))
	output:read_start(function(err, bytes)
		assert(not err, err)
		if bytes then ready = ready or bytes:find("READY\n", 1, true) ~= nil end
	end)
	local deadline, expired = uv.new_timer(), false
	deadline:start(5000, 0, function() expired = true end)
	while not ready and not finished and not expired do uv.run("once") end
	deadline:stop(); deadline:close()
	local ok, err = xpcall(function()
		assert(ready and not finished, "native child reader did not hold its shared lock")
		local before_commit, audit_count = snapshot(), rows("SELECT count(*) FROM owned_registration_audit;")
		assert(Writer.register_device(device, "Commit-refused name", "linux", "busy-version", "busy-signature") == false)
		assert(snapshot() == before_commit, "refused COMMIT changed a device row")
		assert(rows("SELECT count(*) FROM owned_registration_audit;") == audit_count)
	end, debug.traceback)
	input:shutdown(function() input:close() end)
	if expired then process:kill("sigterm") end
	while not finished do uv.run("once") end
	output:read_stop(); output:close(); uv.run("nowait")
	assert(status == 0, "native child reader failed")
	assert(ok, err)
end)
check("healthy retry after native COMMIT refusal is acknowledged", function()
	assert(Writer.register_device(device, "Commit-healthy name", "linux", "ready-version", "ready-signature") == true)
	assert(immutable() == expected_immutable)
	assert(rows("SELECT name,os_version,host_signature FROM devices WHERE device_id='" .. device .. "';")
		== "Commit-healthy name|ready-version|ready-signature")
end)
Writer.close_db()
local function remove_owned_tree(path)
	local attributes = assert(uv.fs_lstat(path))
	if attributes.type == "directory" then
		for name in uv.fs_scandir_next, assert(uv.fs_scandir(path)) do remove_owned_tree(path .. "/" .. name) end
		assert(uv.fs_rmdir(path))
	else
		assert(uv.fs_unlink(path))
	end
end
remove_owned_tree(root)
print(string.format("Native SQLite device registration receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
