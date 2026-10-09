--- tests/hardware/run_machine_id_fallback_receipts.lua
--- ==============================================================================
--- MODULE: Native Linux Machine-ID Fallback Receipts
--- DESCRIPTION:
--- Exercises default production machine-ID lookup and actual OpenSSL encryption
--- with an empty /etc/machine-id and a synthetic valid /var/lib/dbus/machine-id.
--- Supply those files through the owned mount-namespace runner or read-only
--- Docker bind mounts. No machine-ID override, file API or cipher is mocked.
--- The fixture must run as an ordinary user; it never prints key or ID bytes.
--- Binary plaintext and a real encrypted typing batch also survive native
--- OpenSSL and SQLite reopen without losing NUL, Unicode or trailing newlines.
--- ==============================================================================

local uv = require("luv")
local Cipher = require("modules.keylogger.text_cipher")
local Codec = require("keylogger.text_crypto")
local Writer = require("modules.keylogger.sqlite_writer")
local Json = require("json")
assert(uv.getuid() ~= 0, "cipher validation must run as an ordinary user")
local function first_line(path)
	local file = assert(io.open(path, "r"))
	local line = file:read("*l")
	assert(file:close())
	return line
end
assert(not (first_line("/etc/machine-id") or ""):match("%S"), "fixture requires an empty primary machine-ID file")
assert((first_line("/var/lib/dbus/machine-id") or ""):match("%S"), "fixture requires the actual D-Bus fallback file")
local checks, failures = 0, 0
local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

check("default lookup admits the real D-Bus fallback", function()
	assert(Cipher.is_available(), "valid native fallback was reported unavailable")
end)
check("disabled cipher keeps synthetic caller text", function()
	assert(Cipher.set_enabled(false))
	assert(Cipher.encrypt("native-fallback", 1, "Disabled synthetic text") == "Disabled synthetic text")
end)
assert(Cipher.set_enabled(true))
local bytes = {}
for value = 0, 255 do bytes[#bytes + 1] = string.char(value) end
local plaintexts = {
	"Synthetic ASCII text", "Quoted ' text é漢\n\n",
	"a\0b", "\0", "\0\0a\n\n", "a\0é漢\0\n", table.concat(bytes),
}
for index, plaintext in ipairs(plaintexts) do
	check("fallback key encrypts and decrypts exact native bytes " .. index, function()
		local envelope = Cipher.encrypt("native-fallback", index, plaintext)
		assert(Codec.is_encrypted(envelope), "fallback did not produce an encrypted envelope")
		assert(envelope ~= plaintext and Cipher.decrypt(envelope) == plaintext, "native encryption roundtrip changed caller bytes")
	end)
end
check("cached fallback key retains deterministic row identity", function()
	local first = Cipher.encrypt("native-fallback", 3, "Stable row text")
	local second = Cipher.encrypt("native-fallback", 3, "Stable row text")
	assert(Codec.is_encrypted(first) and first == second, "the same native row did not retain its key and IV")
end)
check("distinct fallback rows retain distinct IVs", function()
	local first = Cipher.encrypt("native-fallback", 4, "Same row payload")
	local second = Cipher.encrypt("native-fallback", 5, "Same row payload")
	assert(Codec.is_encrypted(first) and Codec.is_encrypted(second) and first ~= second, "distinct rows collapsed into one encrypted envelope")
end)
check("fallback does not reinterpret unencrypted historical data", function()
	assert(Cipher.decrypt("Historical synthetic text") == "Historical synthetic text")
end)
check("enabled fallback preserves empty values", function()
	assert(Cipher.encrypt("native-fallback", 6, "") == "")
end)
local database_root = assert(uv.fs_mkdtemp("/tmp/ergopti-binary-cipher-XXXXXX"))
check("native encrypted typing survives SQLite persistence and reopen byte for byte", function()
	local database = database_root .. "/metrics.sqlite"
	local plaintext = "Persisted native\0typed bytes é漢\n\n"
	local events_json = Json.encode({ text = plaintext })
	assert(Writer.open_db(database))
	assert(Writer.insert_typing_events("native-binary-device", {
		{ text = plaintext, events_json = events_json, app = "Native binary fixture" },
	}), "the real encrypted typing batch did not commit")
	Writer.close_db()
	assert(Writer.open_db(database))
	local rows = assert(Writer.query_rows("SELECT text,events_json FROM events_typing WHERE device_id='native-binary-device';"))
	assert(#rows == 1, "the encrypted row was lost or duplicated on reopen")
	local text, data = rows[1]:match("^([^|]+)|(.+)$")
	assert(Codec.is_encrypted(text) and Codec.is_encrypted(data), "SQLite persisted unencrypted typed columns")
	assert(Cipher.decrypt(text) == plaintext, "accepted SQLite ciphertext lost typed NUL bytes")
	assert(Json.decode(Cipher.decrypt(data)).text == plaintext, "persisted encrypted JSON lost typed bytes")
end)
Writer.close_db()
for name in uv.fs_scandir_next, assert(uv.fs_scandir(database_root)) do assert(uv.fs_unlink(database_root .. "/" .. name)) end
assert(uv.fs_rmdir(database_root))
assert(not uv.loop_alive(), "fixture retained native ownership")
print(string.format("Native machine-ID fallback receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
