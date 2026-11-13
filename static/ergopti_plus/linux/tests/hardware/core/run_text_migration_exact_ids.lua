--- tests/hardware/core/run_text_migration_exact_ids.lua
--- ==============================================================================
--- MODULE: Native Typed-Text Migration Exact Identities
--- DESCRIPTION:
--- Exercises real SQLite, the production cipher and migration backend with
--- exact and unsafe row identities and durable cursor receipts. The machine-id
--- path points to a disposable synthetic identity; no physical input is used.
--- ==============================================================================
local uv = require("luv")
local Writer = require("metrics.engine.journal.sqlite_writer")
local Cipher = require("metrics.engine.privacy.text_cipher")
local Migration = require("metrics.engine.privacy.text_migration")
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-exact-ids-XXXXXX"))
local machine = assert(io.open(root .. "/machine-id", "wb"))
assert(machine:write("0123456789abcdef0123456789abcdef\n")); assert(machine:close())
Cipher._set_machine_id_path(root .. "/machine-id")
assert(Writer.open_db(root .. "/migration.sqlite"))
-- The live writer and migration must derive the same distinct decimal IV ids.
assert(Writer.set_meta("linux_next_event_id", "100000000000000"))
local encrypt = Cipher.encrypt
local ids = {}
Cipher.encrypt = function(device, id, text)
	ids[#ids + 1] = id
	return encrypt(device, id, text)
end
assert(Writer.insert_typing_events("owned", {
	{ text = "first", date = "2026-01-01", events_json = "[]" },
	{ text = "second", date = "2026-01-01", events_json = "[]" },
}))
Cipher.encrypt = encrypt
assert(table.concat(ids, ",") == "100000000000000,100000000000000j,100000000000001,100000000000001j")
assert(Writer.exec_sql("DELETE FROM events_typing;"))
local function insert(id, text)
	assert(Writer.exec_sql("INSERT INTO events_typing (device_id,id,ts,date,app,is_fullscreen,in_meeting,mouse_clicks,mouse_scrolls,mouse_distance_px,text,events_json) VALUES ('owned'," .. id .. ",'2026-01-01','2026-01-01','test',0,0,0,0,0,'" .. text .. "','');"))
end
insert("9007199254740992", "first-original")
insert("9007199254740993", "second-original")
local sql = "SELECT id||'|'||hex(text)||'|'||hex(events_json) FROM events_typing WHERE device_id='owned' ORDER BY id;"
local before = assert(Writer.query_rows(sql))
local messages = {}
local Logger = require("core.logger.engine.shim")
Logger.set_level("debug")
Logger.set_sink(function(line) messages[#messages + 1] = line end)
Cipher.set_enabled(true)
assert(Migration.start("encrypt", "owned"))
assert(Migration.pump() == false and not Migration.is_running())
local progress = Migration.get_progress()
assert(progress.converted == 0 and progress.scanned == 0 and progress.cursor == 0)
local output = table.concat(messages, "\n")
assert(output:find("migration stopped", 1, true) and not output:find("migration finished", 1, true), "a refused batch cannot report completion")
local after = assert(Writer.query_rows(sql))
assert(#before == 2 and #after == 2 and before[1] == after[1] and before[2] == after[2], "unsafe batch must remain byte-identical")
assert(Writer.get_meta("text_migration_cursor") == "encrypt:0", "the cursor cannot advance past refused rows")
for _, cursor in ipairs({ "encrypt:9007199254740992", "encrypt:9.007199254741e+15" }) do
	assert(Writer.set_meta("text_migration_cursor", cursor))
	local first_message = #messages + 1
	assert(not Migration.resume("encrypt", "owned"), "an invalid cursor cannot resume")
	assert(table.concat(messages, "\n", first_message):find("could not resume", 1, true), "startup must report the refused resume")
	assert(Writer.get_meta("text_migration_cursor") == cursor)
	assert(not Migration.start("encrypt", "owned"), "invalid stored cursor cannot be replaced")
	assert(Writer.get_meta("text_migration_cursor") == cursor)
end
assert(Writer.exec_sql("DELETE FROM events_typing;"))
assert(Writer.set_meta("text_migration_cursor", "encrypt:0"))
insert("9007199254740991", "safe-original")
assert(Migration.start("encrypt", "owned")); Migration.pump()
assert(not Migration.is_running() and Migration.get_progress().converted == 1)
assert(Writer.get_meta("text_migration_cursor") == "encrypt:9007199254740991")
local wrapped = assert(Writer.query_rows("SELECT text FROM events_typing WHERE device_id='owned';"))
assert(#wrapped == 1 and Cipher.decrypt(wrapped[1]) == "safe-original")
Cipher.set_enabled(false); Cipher._set_machine_id_path(nil); Writer.close_db(); Logger.set_sink(nil)
for name in uv.fs_scandir_next, assert(uv.fs_scandir(root)) do assert(uv.fs_unlink(root .. "/" .. name)) end
assert(uv.fs_rmdir(root))
print("PASS native exact migration IDs and durable cursors")
