--- tests/hardware/run_sqlite_event_id_receipts.lua
--- ==============================================================================
--- MODULE: Native Linux SQLite Event ID Receipts
--- DESCRIPTION:
--- Genuine collectors in independent LuaJIT processes interleave raw batches in
--- one owned database. Every acknowledged character must survive raw and derived
--- storage. Real metadata triggers also prove refusal rolls back reservations.
--- Graphical session startup has its own flock; these are collector/CLI receipts,
--- not keyboard hardware or an assertion that the packaged launcher runs twice.
--- ==============================================================================

local uv = require("luv")
require("compat.utf8").install()
local Keylogger = require("modules.keylogger.keylogger")
local Writer = require("modules.keylogger.sqlite_writer")
if arg[1] == "--owned-child" then
	Keylogger.init({ sqlite_path = assert(arg[2]), log_dir = assert(arg[3]) })
	assert(Keylogger.is_enabled())
	Keylogger.on_keydown(assert(arg[4]), 1000, "owned-interleaved-app")
	Keylogger.flush()
	Writer.close_db()
	os.exit(0)
end

local root = assert(uv.fs_mkdtemp("/tmp/ergopti-event-id-receipts-XXXXXX"))
for _, name in ipairs({ "CONFIG", "DATA", "CACHE", "STATE" }) do
	assert(uv.os_setenv("XDG_" .. name .. "_HOME", root .. "/" .. name:lower()))
end
assert(uv.fs_mkdir(root .. "/config", 448))
assert(uv.fs_mkdir(root .. "/config/ergopti", 448))
local config = assert(io.open(root .. "/config/ergopti/config.toml", "w"))
assert(config:write("[metrics]\nenabled = true\n") and config:close())
local database = root .. "/metrics.sqlite"
local checks, failures = 0, 0
Keylogger.init({ sqlite_path = database, log_dir = root .. "/logs" })
assert(Keylogger.is_enabled())
local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end
local function number(sql)
	return tonumber(assert(Writer.query_rows(sql))[1])
end
local function raw_count()
	return number("SELECT count(*) FROM events_typing WHERE app='owned-interleaved-app';")
end
local function next_id()
	return assert(Writer.get_meta("linux_next_event_id"))
end
local function run_child(char)
	local status
	local child
	child = assert(uv.spawn(arg[-1], { args = { arg[0], "--owned-child", database, root .. "/child-logs", char },
		stdio = { nil, 1, 2 } }, function(code) status = code; child:close() end))
	uv.run()
	assert(status == 0, "owned collector child refused its real flush")
end
local function with_held_reader(test)
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
	deadline:stop()
	deadline:close()
	local ok, err = pcall(function()
		assert(ready and not finished, "independent libsqlite3 reader did not acquire its real shared lock")
		test()
	end)
	input:shutdown(function() input:close() end)
	if expired then process:kill("sigterm") end
	while not finished do uv.run("once") end
	output:read_stop()
	output:close()
	uv.run("nowait")
	assert(status == 0, "owned libsqlite3 reader failed")
	assert(ok, err)
end
local acknowledged = 0
for index = 1, 4 do
	Keylogger.on_keydown("a", 1000 + index * 100, "owned-interleaved-app")
	Keylogger.flush()
	acknowledged = acknowledged + 1
	run_child("b")
	acknowledged = acknowledged + 1
	Keylogger.on_keydown("c", 2000 + index * 100, "owned-interleaved-app")
	Keylogger.flush()
	acknowledged = acknowledged + 1
	check("independent collector interleaving " .. index .. " retains every acknowledged raw batch", function()
		assert(raw_count() == acknowledged, "a stale reservation reused an ID and INSERT OR IGNORE discarded raw typing")
		assert(number("SELECT count(DISTINCT id) FROM events_typing WHERE app='owned-interleaved-app';") == acknowledged)
	end)
end
check("raw and derived counts conserve the genuine interleaved stream", function()
	local raw_chars = number("SELECT SUM(length(text)) FROM events_typing WHERE app='owned-interleaved-app';")
	local derived = number("SELECT SUM(c) FROM ngram_chars WHERE app='owned-interleaved-app';")
	assert(raw_chars == acknowledged and derived == acknowledged, "raw and derived native metrics diverged")
	assert(number("SELECT SUM(chars) FROM agg_app_day WHERE app='owned-interleaved-app';") == acknowledged)
end)
local accepted_raw = raw_count()
local empty_cursor = next_id()
Keylogger.flush()
check("an empty flush does not replay raw batches or reserve another range", function()
	assert(raw_count() == accepted_raw and next_id() == empty_cursor)
	assert(number("SELECT SUM(c) FROM ngram_chars WHERE app='owned-interleaved-app';") == acknowledged)
end)

check("a held native read lock refuses COMMIT despite an emitted reservation result", function()
	local cursor = next_id()
	with_held_reader(function()
		assert(Writer.insert_typing_events("owned-commit-device", { { app = "owned-commit-app", text = "u" } }) == false)
		assert(next_id() == cursor, "uncommitted reservation advanced metadata")
		assert(number("SELECT count(*) FROM events_typing WHERE app='owned-commit-app';") == 0)
	end)
end)
check("released native lock allows a fresh acknowledged reservation", function()
	local cursor = next_id()
	assert(Writer.insert_typing_events("owned-commit-device", { { app = "owned-commit-app", text = "u" } }))
	local rows = assert(Writer.query_rows("SELECT id,text FROM events_typing WHERE app='owned-commit-app';"))
	assert(#rows == 1 and rows[1] == cursor .. "|u")
end)

-- RAISE(FAIL) after the UPDATE intentionally preserves that statement's partial
-- work in autocommit mode. A transaction must roll it back when no commit receipt
-- is accepted, rather than acknowledging or consuming the refused reservation.
local before = next_id()
assert(Writer.exec_sql("CREATE TRIGGER owned_allocator_refusal AFTER UPDATE ON meta "
	.. "WHEN NEW.key='linux_next_event_id' BEGIN SELECT RAISE(FAIL,'owned allocator refusal'); END;"))
Keylogger.on_keydown("r", 4000, "owned-interleaved-app")
Keylogger.flush()
check("native allocator refusal rolls back metadata and publishes no raw or derived rows", function()
	assert(next_id() == before, "refused reservation consumed a durable ID range")
	assert(raw_count() == accepted_raw)
	assert(number("SELECT count(*) FROM ngram_chars WHERE app='owned-interleaved-app' AND token='r';") == 0)
end)
Keylogger.flush()
check("repeated allocator refusal preserves pending typing and the metadata cursor", function()
	assert(next_id() == before and raw_count() == accepted_raw)
end)
assert(Writer.exec_sql("DROP TRIGGER owned_allocator_refusal;"))
Keylogger.flush()
Keylogger.flush()
check("allocator recovery persists the retained stream once with the unconsumed ID", function()
	assert(raw_count() == accepted_raw + 1)
	local rows = assert(Writer.query_rows("SELECT id,text FROM events_typing WHERE app='owned-interleaved-app' AND text='r';"))
	assert(#rows == 1 and rows[1] == before .. "|r")
	assert(number("SELECT c FROM ngram_chars WHERE app='owned-interleaved-app' AND token='r';") == 1)
end)

local batch = {
	{ app = "owned-batch-app", text = "x" }, { app = "owned-batch-app", text = "y" }, { app = "owned-batch-app", text = "z" },
}
local batch_first = tonumber(next_id())
assert(Writer.insert_typing_events("owned-batch-device", batch))
check("one reservation assigns consecutive IDs to every row in a multi-event batch", function()
	local rows = assert(Writer.query_rows("SELECT id,text FROM events_typing WHERE app='owned-batch-app' ORDER BY id;"))
	assert(table.concat(rows, ",") == batch_first .. "|x," .. (batch_first + 1) .. "|y," .. (batch_first + 2) .. "|z")
	assert(tonumber(next_id()) == batch_first + #batch)
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
print(string.format("Native SQLite event ID receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
