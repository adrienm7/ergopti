--- tests/hardware/run_sqlite_event_id_cursor_receipts.lua
--- ==============================================================================
--- MODULE: Native Linux SQLite Event ID Cursor Receipts
--- DESCRIPTION:
--- Actual collector flushes refuse invalid or exhausted SQLite cursor text and
--- retain pending typing for recovery. Leading-zero legacy values and exact
--- Lua integer boundaries retain their native IDs without rounded arithmetic.
--- All profiles/databases are owned; no database or process adapter is mocked.
--- ==============================================================================

local uv = require("luv")
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-event-cursor-receipts-XXXXXX"))
for _, name in ipairs({ "CONFIG", "DATA", "CACHE", "STATE" }) do
	assert(uv.os_setenv("XDG_" .. name .. "_HOME", root .. "/" .. name:lower()))
end
require("compat.utf8").install()
assert(uv.fs_mkdir(root .. "/config", 448))
assert(uv.fs_mkdir(root .. "/config/ergopti", 448))
local config = assert(io.open(root .. "/config/ergopti/config.toml", "w"))
assert(config:write("[metrics]\nenabled = true\n") and config:close())
local Keylogger = require("modules.keylogger.keylogger")
local Writer = require("modules.keylogger.sqlite_writer")
local checks, failures = 0, 0
local serial = 0
local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end
local function fresh(cursor)
	Writer.close_db()
	serial = serial + 1
	Keylogger.init({ sqlite_path = root .. "/metrics-" .. serial .. ".sqlite", log_dir = root .. "/logs" })
	assert(Keylogger.is_enabled())
	Keylogger.reset_session()
	assert(Writer.set_meta("linux_next_event_id", cursor))
end
local function number(sql)
	return tonumber(assert(Writer.query_rows(sql))[1])
end
local function hex(text)
	return (text:gsub(".", function(byte) return string.format("%02X", byte:byte()) end))
end
local invalid = {
	{ "nonnumeric", "oops" }, { "empty", "" }, { "zero", "0" }, { "negative", "-7" },
	{ "numeric prefix", "12oops" }, { "embedded NUL", "41\0oops" }, { "fraction", "1.5" }, { "exponent", "1e3" },
	{ "hexadecimal", "0x29" }, { "whitespace", " " },
	{ "exhausted exact Lua cursor", "9007199254740991" },
	{ "inexact Lua cursor", "9007199254740993" },
	{ "native integer ceiling", "9223372036854775807" },
	{ "native integer overflow", "9223372036854775808" },
}
for _, item in ipairs(invalid) do
	fresh(item[2])
	Keylogger.on_keydown("a", 1000, "owned-cursor-app")
	Keylogger.flush()
	Keylogger.flush()
	check("native " .. item[1] .. " cursor refuses without mutation", function()
		assert(assert(Writer.query_rows("SELECT hex(value) FROM meta WHERE key='linux_next_event_id';"))[1] == hex(item[2]),
			"invalid or exhausted cursor was rewritten")
		assert(number("SELECT count(*) FROM events_typing;") == 0, "invalid cursor acknowledged raw typing")
		assert(number("SELECT count(*) FROM ngram_chars;") == 0, "refused raw stream acquired derived metrics")
	end)
	assert(Writer.set_meta("linux_next_event_id", "41"))
	Keylogger.flush()
	Keylogger.flush()
	check("native " .. item[1] .. " cursor recovery retains pending typing once", function()
		local rows = assert(Writer.query_rows("SELECT id,text FROM events_typing ORDER BY id;"))
		assert(#rows == 1 and rows[1] == "41|a", "refusal consumed pending typing or acknowledged an unusable ID")
		assert(Writer.get_meta("linux_next_event_id") == "42")
		assert(number("SELECT c FROM ngram_chars WHERE token='a';") == 1)
	end)
end
for _, cursor in ipairs({ "41", "00041", " 00041 " }) do
	fresh(cursor)
	check("native positive serialized cursor " .. cursor .. " retains its exact ID", function()
		assert(Writer.insert_typing_events("owned-device", { { app = "owned-app", text = "a" } }))
		local rows = assert(Writer.query_rows("SELECT id,text FROM events_typing;"))
		assert(#rows == 1 and rows[1] == "41|a")
		assert(Writer.get_meta("linux_next_event_id") == "42")
	end)
end
fresh("9007199254740989")
check("native exact-boundary batch allocates every ID without rounded arithmetic", function()
	assert(Writer.insert_typing_events("owned-device", { { app = "owned-app", text = "a" }, { app = "owned-app", text = "b" } }))
	local rows = assert(Writer.query_rows("SELECT id,text FROM events_typing ORDER BY id;"))
	assert(table.concat(rows, ",") == "9007199254740989|a,9007199254740990|b")
	assert(Writer.get_meta("linux_next_event_id") == "9007199254740991")
end)
check("native exact-boundary exhaustion refuses the next ID without changing accepted rows", function()
	assert(Writer.insert_typing_events("owned-device", { { app = "owned-app", text = "c" } }) == false)
	assert(Writer.get_meta("linux_next_event_id") == "9007199254740991")
	assert(number("SELECT count(*) FROM events_typing;") == 2)
end)
fresh("9007199254740990")
check("native addition beyond the exact bound refuses the entire requested range", function()
	assert(Writer.insert_typing_events("owned-device", { { app = "owned-app", text = "a" }, { app = "owned-app", text = "b" } }) == false)
	assert(Writer.get_meta("linux_next_event_id") == "9007199254740990")
	assert(number("SELECT count(*) FROM events_typing;") == 0)
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
print(string.format("Native SQLite event ID cursor receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
