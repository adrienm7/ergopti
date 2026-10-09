--- tests/hardware/run_sqlite_raw_batch_transactions.lua
--- ==============================================================================
--- MODULE: Native SQLite Raw Batch Transactions
--- DESCRIPTION:
--- Real SQLite BEFORE/AFTER triggers refuse public raw writers and demonstrate
--- rollback of rows and trigger side effects. A public synthetic collector path
--- proves refusal retains its batch and healthy retry conserves raw/derived data.
--- No CLI/process/database/provider mocks or hardware claims.
--- ==============================================================================

local uv = require("luv")
require("compat.utf8").install()
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-raw-batches-XXXXXX"))
for _, name in ipairs({ "CONFIG", "DATA", "CACHE", "STATE" }) do
	assert(uv.os_setenv("XDG_" .. name .. "_HOME", root .. "/" .. name:lower()))
end
assert(uv.fs_mkdir(root .. "/config", 448))
assert(uv.fs_mkdir(root .. "/config/ergopti", 448))
local config = assert(io.open(root .. "/config/ergopti/config.toml", "w"))
assert(config:write("[metrics]\nenabled = true\n") and config:close())

local Keylogger = require("modules.keylogger.keylogger")
local Writer = require("modules.keylogger.sqlite_writer")
local Json = require("json")
local checks, failures = 0, 0

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

local function scalar(sql)
	return tonumber(assert(Writer.query_rows(sql))[1])
end

Keylogger.init({ sqlite_path = root .. "/collector.sqlite", log_dir = root .. "/logs" })
assert(Keylogger.is_enabled() and Writer.is_available())
assert(Writer.exec_sql("CREATE TRIGGER owned_partial AFTER INSERT ON events_typing "
	.. "WHEN (SELECT COUNT(*) FROM events_typing)=2 BEGIN SELECT RAISE(FAIL,'owned late refusal'); END;"))
Keylogger.record_synthetic_output("owned-a", "a", "other", 1000)
Keylogger.record_synthetic_output("owned-b", "b", "other", 1000)
Keylogger.flush()
check("refused actual collector batch preserves pending entries without durable raw fragments", function()
	assert(Keylogger._pending_buffer_count_for_test() == 2)
	assert(scalar("SELECT COUNT(*) FROM events_typing;") == 0, "refused INSERT leaked durable raw rows")
	assert(scalar("SELECT COUNT(*) FROM ngram_chars;") == 0)
	assert(Writer.get_meta("linux_next_event_id") == "3", "ID reservation must remain a separate acknowledged transaction")
end)
assert(Writer.exec_sql("DROP TRIGGER owned_partial;"))
Keylogger.flush()
check("healthy actual collector retry preserves raw payloads and derived conservation", function()
	assert(Keylogger._pending_buffer_count_for_test() == 0)
	assert(scalar("SELECT COUNT(*) FROM events_typing;") == 2, "raw retry duplicated committed fragments")
	assert(scalar("SELECT SUM(json_array_length(events_json)) FROM events_typing;") == 2)
	assert(scalar("SELECT SUM(c) FROM ngram_chars;") == 2)
	for _, char in ipairs({ "a", "b" }) do
		local packed = assert(Writer.query_rows("SELECT events_json FROM events_typing WHERE app='owned-" .. char .. "';"))
		assert(#packed == 1)
		local events = assert(Json.decode(packed[1]))
		assert(#events == 1 and events[1][1] == char and events[1][2] == 0 and events[1][3].st == "other")
	end
	assert(Writer.get_meta("linux_next_event_id") == "5")
end)
local accepted = assert(Writer.query_rows("SELECT id,app,hex(events_json) FROM events_typing ORDER BY id;"))
Keylogger.flush()
check("second healthy collector flush cannot repeat accepted raw or derived entries", function()
	assert(table.concat(Writer.query_rows("SELECT id,app,hex(events_json) FROM events_typing ORDER BY id;"), "\n") == table.concat(accepted, "\n"))
	assert(scalar("SELECT SUM(c) FROM ngram_chars;") == 2)
end)

local fixtures = {
	{ table_name = "events_typing", method = "insert_typing_events", column = "text",
		events = { { app = "owned-first", text = "left\0é", events_json = "[]" },
			{ app = "owned-second", text = "right\r\n", events_json = "[]" } },
		values = { "left\0é", "right\r\n" } },
	{ table_name = "events_hotstring", method = "insert_hotstring_events", column = "replacement",
		events = { { app = "owned-first", replacement = "left\0é" },
			{ app = "owned-second", replacement = "right\r\n" } }, values = { "left\0é", "right\r\n" } },
	{ table_name = "events_shortcut", method = "insert_shortcut_events", column = "key",
		events = { { app = "owned-first", key = "left\0é" },
			{ app = "owned-second", key = "right\r\n" } }, values = { "left\0é", "right\r\n" } },
	{ table_name = "events_app_switch", method = "insert_app_switch_events", column = "next_app",
		events = { { prev_app = "owned-first", next_app = "left\0é", duration_ms = 7 },
			{ prev_app = "owned-second", next_app = "right\r\n", duration_ms = 9 } }, values = { "left\0é", "right\r\n" } },
}

local function hex(value)
	return (value:gsub(".", function(byte) return string.format("%02X", byte:byte()) end))
end

for _, fixture in ipairs(fixtures) do
	Writer.close_db()
	assert(Writer.open_db(root .. "/" .. fixture.table_name .. ".sqlite"))
	assert(Writer.exec_sql("CREATE TABLE owned_side_effect (payload TEXT);"))
	for _, timing in ipairs({ "AFTER", "BEFORE" }) do
		check("actual " .. timing .. " FAIL in " .. fixture.table_name .. " rolls back rows/side effects and retries once", function()
			assert(Writer.exec_sql("DELETE FROM " .. fixture.table_name .. "; DELETE FROM owned_side_effect;"))
			local cursor = tonumber(Writer.get_meta("linux_next_event_id")) or 1
			local condition = timing == "AFTER" and (" WHEN (SELECT COUNT(*) FROM " .. fixture.table_name .. ")=2") or ""
			assert(Writer.exec_sql("CREATE TRIGGER owned_refusal " .. timing .. " INSERT ON " .. fixture.table_name .. condition
				.. " BEGIN INSERT INTO owned_side_effect VALUES ('owned side effect'); SELECT RAISE(FAIL,'owned refusal'); END;"))
			local refused = Writer[fixture.method]("owned", fixture.events)
			local fragments = scalar("SELECT COUNT(*) FROM " .. fixture.table_name .. ";")
			local side_effects = scalar("SELECT COUNT(*) FROM owned_side_effect;")
			local reserved = tonumber(Writer.get_meta("linux_next_event_id"))
			assert(Writer.exec_sql("DROP TRIGGER owned_refusal;"))
			assert(Writer[fixture.method]("owned", fixture.events))
			local rows = assert(Writer.query_rows("SELECT hex(" .. fixture.column .. ") FROM " .. fixture.table_name .. " ORDER BY id;"))
			assert(refused == false and fragments == 0 and side_effects == 0, "failed batch left durable rows or trigger effects")
			assert(reserved == cursor + 2, "failed row transaction must not change ID reservation policy")
			assert(#rows == 2 and rows[1] == hex(fixture.values[1]) and rows[2] == hex(fixture.values[2]), "healthy retry lost or duplicated native payload bytes")
		end)
	end
end

check("empty public raw batches preserve existing admission and reservation state", function()
	local cursor = Writer.get_meta("linux_next_event_id")
	for _, fixture in ipairs(fixtures) do
		assert(Writer[fixture.method]("owned", {}) == nil)
		assert(Writer[fixture.method]("owned", nil) == nil)
	end
	assert(Writer.get_meta("linux_next_event_id") == cursor)
end)

Writer.close_db()
local function remove_owned(path)
	local stat = assert(uv.fs_lstat(path))
	if stat.type == "directory" then
		for name in uv.fs_scandir_next, assert(uv.fs_scandir(path)) do remove_owned(path .. "/" .. name) end
		assert(uv.fs_rmdir(path))
	else assert(uv.fs_unlink(path)) end
end
remove_owned(root)
assert(checks == 12, "all four raw batch adapters and public controls must execute")
print(string.format("Native SQLite raw batch transactions: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
