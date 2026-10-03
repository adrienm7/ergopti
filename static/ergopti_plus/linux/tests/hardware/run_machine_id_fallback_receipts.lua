--- tests/hardware/run_machine_id_fallback_receipts.lua
--- ==============================================================================
--- MODULE: Native Linux Machine-ID Fallback Receipts
--- DESCRIPTION:
--- Exercises default production machine-ID lookup and actual OpenSSL encryption
--- with an empty /etc/machine-id and a synthetic valid /var/lib/dbus/machine-id.
--- Supply those files through the owned mount-namespace runner or read-only
--- Docker bind mounts. No machine-ID override, file API or cipher is mocked.
--- The fixture must run as an ordinary user; it never prints key or ID bytes.
--- ==============================================================================

local uv = require("luv")
local Cipher = require("modules.keylogger.text_cipher")
local Codec = require("keylogger.text_crypto")
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
for index, plaintext in ipairs({ "Synthetic ASCII text", "Quoted ' text é漢\n\n" }) do
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
assert(not uv.loop_alive(), "fixture retained native ownership")
print(string.format("Native machine-ID fallback receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
