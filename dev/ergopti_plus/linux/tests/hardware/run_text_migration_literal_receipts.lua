--- tests/hardware/run_text_migration_literal_receipts.lua
--- ==============================================================================
--- MODULE: Native Linux Decryption Migration Literal Receipts
--- DESCRIPTION:
--- Encrypts and migrates genuine SQLite typing rows with the production cipher,
--- migration owner, runner and backend. Only the machine-id path provider points
--- to an owned synthetic identity; PBKDF/AES/OpenSSL, parser, files and SQL are
--- real. No TOML write, actual machine identity or physical input is exercised.
--- ==============================================================================

local uv = require("luv")
local Writer = require("modules.keylogger.sqlite_writer")
local Cipher = require("modules.keylogger.text_cipher")
local Migration = require("modules.keylogger.text_migration")
local TextCrypto = require("keylogger.text_crypto")
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-migration-literals-XXXXXX"))
local machine = assert(io.open(root .. "/machine-id", "wb"))
assert(machine:write("0123456789abcdef0123456789abcdef\n")); assert(machine:close())
Cipher._set_machine_id_path(root .. "/machine-id")
local checks, failures = 0, 0

local function hex(text)
	return (text:gsub(".", function(byte) return string.format("%02X", string.byte(byte)) end))
end

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	Writer.close_db()
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

for index, value in ipairs({ "ordinary été quote'\tLF\n", "a\r\nb", "\r\ntrailing\r\n", "a\0b", "\0", "'\0\r\n'", "double\r\r\nline" }) do
	check("native decryption migration " .. index .. " preserves both columns and foreign ownership", function()
		assert(Writer.open_db(root .. "/owned-" .. index .. ".sqlite"))
		Cipher.set_enabled(true)
		local events = value:find("\r", 1, true) and "[\r\n]" or "[]"
		assert(Writer.insert_typing_events("owned", {{ text = value, date = "2026-10-04", events_json = events }}))
		assert(Writer.insert_typing_events("foreign", {{ text = "foreign control", date = "2026-10-04", events_json = "[]" }}))
		local before = assert(Writer.query_rows("SELECT text FROM events_typing WHERE device_id='owned';"))
		assert(#before == 1 and TextCrypto.is_encrypted(before[1]) and Cipher.decrypt(before[1]) == value,
			"independent actual native encryption did not preserve the fixture bytes")
		local foreign = assert(Writer.query_rows("SELECT hex(text)||'|'||hex(events_json) FROM events_typing WHERE device_id='foreign';"))
		assert(#foreign == 1)
		Cipher.set_enabled(false)
		assert(Migration.start("decrypt", "owned"))
		local pumps = 0
		while Migration.is_running() do
			pumps = pumps + 1; assert(pumps <= 3, "bounded native migration did not settle")
			Migration.pump()
		end
		assert(Migration.get_progress().converted == 1, "representable decrypted data was refused instead of encoded")
		local after = assert(Writer.query_rows("SELECT hex(text)||'|'||hex(events_json) FROM events_typing WHERE device_id='owned';"))
		assert(#after == 1 and after[1] == hex(value) .. "|" .. hex(events), "acknowledged native migration changed decrypted bytes")
		local retained = assert(Writer.query_rows("SELECT hex(text)||'|'||hex(events_json) FROM events_typing WHERE device_id='foreign';"))
		assert(#retained == 1 and retained[1] == foreign[1], "local conversion modified another device's ciphertext")
		assert(not Migration.start("unknown-mode", "owned"), "native migration admitted an unknown direction")
	end)
end

Cipher.set_enabled(false)
Cipher._set_machine_id_path(nil)
for name in uv.fs_scandir_next, assert(uv.fs_scandir(root)) do assert(uv.fs_unlink(root .. "/" .. name)) end
assert(uv.fs_rmdir(root))
print(string.format("Native decryption migration literals: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
