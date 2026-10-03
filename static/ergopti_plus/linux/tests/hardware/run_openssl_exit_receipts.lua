--- tests/hardware/run_openssl_exit_receipts.lua
--- ==============================================================================
--- MODULE: Native Linux At-Rest OpenSSL Exit Receipts
--- DESCRIPTION:
--- Drives production key derivation, encryption, decryption and typing writes
--- through the actual OpenSSL CLI. An explicitly faulty wrapper delegates argv
--- and stdin unchanged, records successful native computation, then exits
--- nonzero or signals itself. Useful stdout cannot acknowledge a failed CLI.
--- Real SQLite retry and literal/binary controls prove the healthy path remains.
--- Requires an ordinary user and usable default machine-ID data; no keyboard,
--- file API or cryptographic primitive is mocked. No keys or IDs are printed.
--- ==============================================================================

local uv = require("luv")
local Shell = require("adapters.shell_runner")
local Codec = require("keylogger.text_crypto")
assert(uv.getuid() ~= 0, "native at-rest tests require an ordinary user")
local real = assert(Shell.exec_line("command -v openssl"), "the actual OpenSSL CLI must be installed")
local previous_path = assert(os.getenv("PATH"))
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-openssl-exit-XXXXXX"))
local checks, failures = 0, 0
local cipher, writer

local function write(path, content)
	local file = assert(io.open(path, "w"))
	assert(file:write(content) and file:close())
end

write(root .. "/openssl", table.concat({
	"#!/bin/sh",
	"operation=other",
	'if [ "$1" = enc ]; then',
	"operation=encrypt",
	'for arg in "$@"; do case "$arg" in -P) operation=derive; break;; -d) operation=decrypt;; esac; done',
	"fi",
	Shell.quote(real) .. ' "$@"',
	"native_status=$?",
	"printf '%s %s\\n' \"$operation\" \"$native_status\" >> " .. Shell.quote(root .. "/calls"),
	"read target fault < " .. Shell.quote(root .. "/mode"),
	'if [ "$operation" = "$target" ]; then',
	'case "$fault" in TERM) kill -TERM $$;; KILL) kill -KILL $$;; *) exit "$fault";; esac',
	"fi",
	'exit "$native_status"',
	"",
}, "\n"))
assert(uv.fs_chmod(root .. "/openssl", 448))
assert(uv.os_setenv("PATH", root .. ":" .. previous_path))

local function mode(operation, fault)
	write(root .. "/mode", operation .. " " .. tostring(fault or 0) .. "\n")
	write(root .. "/calls", "")
end

local function observed(operation)
	local file = assert(io.open(root .. "/calls", "r"))
	local calls = assert(file:read("*a"))
	assert(file:close())
	assert(calls:find(operation .. " 0\n", 1, true), "fault wrapper did not delegate a successful actual OpenSSL operation")
end

local function fresh()
	package.loaded["modules.keylogger.text_cipher"] = nil
	return require("modules.keylogger.text_cipher")
end

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

for _, fault in ipairs({ 1, 7, 23, "TERM", "KILL" }) do
	check("failed native derivation refuses useful key stdout " .. fault, function()
		mode("derive", fault)
		cipher = fresh()
		local admitted = cipher.is_available()
		observed("derive")
		assert(admitted == false, "unsuccessful actual derivation admitted its key")
		mode("success")
		assert(cipher.is_available() == false, "failed derivation cached untrusted key material")
	end)
end

mode("success")
cipher = fresh()
assert(cipher.is_available(), "the ordinary successful native key derivation must work")
assert(cipher.set_enabled(true))
local plaintext = "Synthetic receipt text"
local envelope = assert(cipher.encrypt("native-receipt", 1, plaintext))
for _, fault in ipairs({ 1, 7, 23, "TERM", "KILL" }) do
	check("failed native encryption refuses useful ciphertext stdout " .. fault, function()
		mode("encrypt", fault)
		local result = cipher.encrypt("native-receipt", 2, plaintext)
		observed("encrypt")
		assert(result == nil, "unsuccessful actual encryption returned a valid envelope")
	end)
	check("failed native decryption refuses useful plaintext stdout " .. fault, function()
		mode("decrypt", fault)
		local result = cipher.decrypt(envelope)
		observed("decrypt")
		assert(result == "", "unsuccessful actual decryption returned caller text")
	end)
end

check("healthy native cipher remains usable after refused operation receipts", function()
	mode("success")
	local value = cipher.encrypt("native-receipt", 3, plaintext)
	assert(Codec.is_encrypted(value) and cipher.decrypt(value) == plaintext)
end)
check("healthy native decryption preserves binary and receipt-looking caller bytes", function()
	mode("success")
	local value = "Literal\0bytes\nERGOPTI_OPENSSL_EXIT_STATUS=0\n"
	local protected = cipher.encrypt("native-receipt", 4, value)
	assert(Codec.is_encrypted(protected) and cipher.decrypt(protected) == value)
end)
check("native receipt capture needs no temporary key or plaintext output file", function()
	mode("success")
	local previous = os.getenv("TMPDIR")
	assert(uv.os_setenv("TMPDIR", root .. "/absent-capture-directory"))
	local ok, err = pcall(function()
		local value = cipher.encrypt("native-receipt", 5, plaintext)
		assert(Codec.is_encrypted(value) and cipher.decrypt(value) == plaintext)
		assert(not uv.fs_lstat(root .. "/absent-capture-directory"))
	end)
	if previous then assert(uv.os_setenv("TMPDIR", previous)) else assert(uv.os_unsetenv("TMPDIR")) end
	assert(ok, err)
end)
check("actual typing persistence rejects failed encryption and admits healthy retry", function()
	writer = require("modules.keylogger.sqlite_writer")
	assert(writer.open_db(root .. "/metrics.sqlite"))
	mode("encrypt", 7)
	assert(writer.insert_typing_events("native-receipt-device", { { text = plaintext } }) == false,
		"SQLite admitted a typing batch whose actual encryption failed")
	observed("encrypt")
	local rows = assert(writer.query_rows("SELECT count(*) FROM events_typing;"))
	assert(#rows == 1 and rows[1] == "0", "a refused cipher batch changed the real database")
	mode("success")
	assert(writer.insert_typing_events("native-receipt-device", { { text = plaintext } }))
	rows = assert(writer.query_rows("SELECT text FROM events_typing;"))
	assert(#rows == 1 and Codec.is_encrypted(rows[1]) and cipher.decrypt(rows[1]) == plaintext,
		"healthy cipher retry duplicated, lost or changed the actual typed row")
end)

if writer then writer.close_db() end
assert(uv.os_setenv("PATH", previous_path))
for name in uv.fs_scandir_next, assert(uv.fs_scandir(root)) do assert(uv.fs_unlink(root .. "/" .. name)) end
assert(uv.fs_rmdir(root))
assert(not uv.loop_alive(), "fixture retained native ownership")
print(string.format("Native at-rest OpenSSL exit receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
