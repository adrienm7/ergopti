--- tests/hardware/run_openssl_exit_receipts.lua
--- ==============================================================================
--- MODULE: Native Linux At-Rest Cryptography Receipts
--- DESCRIPTION:
--- Retains actual CLI KDF exit faults, then exercises the replacement EVP byte
--- transport against legacy CLI ciphertext using PUBLIC SYNTHETIC keys only.
--- Old per-row shell/decoder/head faults are replaced by actual EVP init/update/
--- final acknowledgement faults: partial output must never authorize storage.
--- Real SQLite and the collector prove unavailable saved ON remains closed and
--- retries without plaintext or duplicate rows. No physical input is claimed.
--- ==============================================================================

local uv = require("luv")
local Shell = require("adapters.shell_runner")
local Codec = require("keylogger.text_crypto")
local Base64 = require("compat.base64")
local OpenSSL = require("infra.openssl_command")
assert(uv.getuid() ~= 0, "native at-rest tests require an ordinary user")
local real = assert(Shell.exec_line("command -v openssl"))
local previous_path = assert(os.getenv("PATH"))
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-openssl-exit-XXXXXX"))
local checks, failures = 0, 0
local cipher, writer

local function write(path, content)
	local file = assert(io.open(path, "w"))
	assert(file:write(content) and file:close())
end
write(root .. "/machine-id", "0123456789abcdef0123456789abcdef\n")
write(root .. "/openssl", table.concat({
	"#!/bin/sh", "operation=other",
	'for arg in "$@"; do case "$arg" in -P) operation=derive;; -K) exit 97;; esac; done',
	"read fault < " .. Shell.quote(root .. "/mode"),
	Shell.quote(real) .. ' "$@"', "native_status=$?",
	"printf '%s %s\\n' \"$operation\" \"$native_status\" >> " .. Shell.quote(root .. "/calls"),
	'if [ "$operation" = derive ]; then',
	'case "$fault" in TERM) kill -TERM $$;; KILL) kill -KILL $$;; *) exit "$fault";; esac',
	"fi", 'exit "$native_status"', "",
}, "\n"))
assert(uv.fs_chmod(root .. "/openssl", 448))
assert(uv.os_setenv("PATH", root .. ":" .. previous_path))
local function mode(fault) write(root .. "/mode", tostring(fault or 0)); write(root .. "/calls", "") end
local function fresh()
	package.loaded["modules.keylogger.text_cipher"] = nil
	local subject = require("modules.keylogger.text_cipher")
	subject._set_machine_id_path(root .. "/machine-id")
	return subject
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
		mode(fault); cipher = fresh()
		assert(cipher.is_available() == false, "failed actual derivation admitted a key")
		local file = assert(io.open(root .. "/calls", "r"))
		local calls = assert(file:read("*a")); assert(file:close())
		assert(calls:find("derive 0\n", 1, true), "fault must follow successful actual native work")
		mode(0)
		assert(cipher.is_available() == false, "failed derivation cached untrusted key material")
	end)
end

-- Direct native CLI oracle: exact stdin/output pipes, no argv-sized data or
-- temporary plaintext. Its key is explicitly public fixture data, never the
-- production cache. This helper is owned by this standalone test's event loop.
local function oracle(key, iv, input, decrypt)
	local stdin, stdout, stderr = assert(uv.new_pipe()), assert(uv.new_pipe()), assert(uv.new_pipe())
	local chunks, size, failed, exited = {}, 0, false, false
	local args = { "enc", "-aes-256-cbc", "-K", key, "-iv", iv }
	if decrypt then args[#args + 1] = "-d" end
	local process
	process = assert(uv.spawn(real, { args = args, stdio = { stdin, stdout, stderr } }, function(code, signal)
		failed, exited = failed or code ~= 0 or signal ~= 0, true
		process:close()
	end))
	stdout:read_start(function(err, data)
		failed = failed or err ~= nil
		if data then size = size + #data; assert(size <= #input + 32); chunks[#chunks + 1] = data
		else stdout:read_stop(); stdout:close() end
	end)
	stderr:read_start(function(err, data)
		failed = failed or err ~= nil or data ~= nil
		if not data then stderr:read_stop(); stderr:close() end
	end)
	assert(stdin:write(input, function(err)
		failed = failed or err ~= nil
		assert(stdin:shutdown(function(shutdown_error)
			failed = failed or shutdown_error ~= nil; stdin:close()
		end))
	end))
	local deadline = uv.hrtime() + 5000000000
	repeat uv.run("nowait"); uv.sleep(1) until exited or uv.hrtime() >= deadline
	if not exited then process:kill("sigkill") end
	while uv.loop_alive() do uv.run("once") end
	assert(exited and not failed, "independent native CLI oracle failed")
	return table.concat(chunks)
end

-- The proxy runs the REAL primitive before refusing its acknowledgement. Unlike
-- a fake cipher, this proves useful actual output cannot survive a failed ACK.
local Native = require("infra.openssl_library")
local fault, observed, freed = nil, false, 0
local proxy = setmetatable({}, { __index = Native.library })
for _, stage in ipairs({ "Init", "Update", "Final" }) do
	local name = "EVP_Cipher" .. stage .. "_ex"
	if stage == "Update" then name = "EVP_CipherUpdate" end
	proxy[name] = function(...)
		local result = Native.library[name](...)
		if fault == stage then observed = result == 1; return 0 end
		return result
	end
end
proxy.EVP_CIPHER_CTX_free = function(context) freed = freed + 1; Native.library.EVP_CIPHER_CTX_free(context) end
package.loaded["infra.openssl_library"] = { ffi = Native.ffi, library = proxy }
package.loaded["infra.openssl_cipher"] = nil
local AES = require("infra.openssl_cipher")
package.loaded["infra.openssl_library"] = Native
assert(AES.available, "real native AES capability required")
mode(0); cipher = fresh(); assert(cipher.is_available()); assert(cipher.set_enabled(true))

local KEY = "603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4"
local IV = "000102030405060708090a0b0c0d0e0f"
local function unhex(value) return (value:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end)) end
check("native AES matches the independent NIST CBC first-block known answer", function()
	local bytes = assert(AES.encrypt(KEY, IV, unhex("6bc1bee22e409f96e93d7e117393172a")))
	assert(bytes:sub(1, 16) == unhex("f58c4c04d6e5f1ba779eabfb5f7bfbd6") and #bytes == 32)
end)
local values = { "", "a", string.rep("x", 15), string.rep("x", 16), string.rep("x", 17),
	string.rep("x", 31), string.rep("x", 32), "a\0b", "\0", "\0\0a\n\n", "a\0é漢\0\n",
	"line\r\n\n", "Literal $(false) `false` 'quotes' é漢\n\n",
	string.rep("'a", 45000) .. "\0", string.rep("a\0bc", 262144) }
local all_bytes = {}; for byte = 0, 255 do all_bytes[#all_bytes + 1] = string.char(byte) end
values[#values + 1] = table.concat(all_bytes)
for index, value in ipairs(values) do
	check("exact legacy CLI and EVP ciphertext equivalence " .. index, function()
		collectgarbage("collect")
		local framed = assert(AES.encode_base64(value))
		assert(framed == Base64.encode(value) and AES.decode_base64(framed) == value,
			"native Base64 must match the independent shared codec, including every NUL")
		local expected = oracle(KEY, IV, value, false)
		assert(AES.encrypt(KEY, IV, value) == expected, "padding, key or exact plaintext bytes drifted")
		assert(AES.decrypt(KEY, IV, expected) == value)
		assert(oracle(KEY, IV, assert(AES.encrypt(KEY, IV, value)), true) == value)
	end)
end
check("production envelopes use the unchanged cached CLI KDF and shared IV/Base64", function()
	local key = assert(Codec.parse_derived_key(OpenSSL.exec(assert(Codec.derive_key_command("file:" .. root .. "/machine-id")))))
	local value = "Synthetic envelope\0payload\n\n"
	local envelope = assert(cipher.encrypt("synthetic-device", 7, value))
	local iv, payload = Codec.unwrap(envelope)
	assert(iv == Codec.iv_for("synthetic-device", 7, require("adapters.crypto").sha256))
	assert(payload == Base64.encode(oracle(key, iv, value, false)))
	assert(cipher.decrypt(Codec.wrap(iv, Base64.encode(oracle(key, iv, value, false)))) == value)
end)
for _, stage in ipairs({ "Init", "Update", "Final" }) do
	for _, operation in ipairs({ "encrypt", "decrypt" }) do
		check("failed actual EVP " .. stage .. " ACK refuses useful " .. operation .. " bytes", function()
			local envelope = assert(cipher.encrypt("synthetic-device", 1, "Synthetic receipt text"))
			fault, observed = stage, false
			local before = freed
			local result
			if operation == "encrypt" then result = cipher.encrypt("synthetic-device", 2, "Synthetic receipt text")
			else result = cipher.decrypt(envelope) end
			fault = nil
			assert(observed and freed == before + 1, "actual primitive and exact context cleanup required")
			if operation == "encrypt" then assert(result == nil) else assert(result == "") end
		end)
	end
end
check("native RFC 4648 vectors and strict padding/unused-bit refusals match the historical envelope", function()
	for _, pair in ipairs({ { "", "" }, { "f", "Zg==" }, { "fo", "Zm8=" }, { "foo", "Zm9v" },
		{ "foob", "Zm9vYg==" }, { "fooba", "Zm9vYmE=" }, { "foobar", "Zm9vYmFy" } }) do
		assert(AES.encode_base64(pair[1]) == pair[2] and AES.decode_base64(pair[2]) == pair[1])
	end
	for _, value in ipairs({ "Zg=", "Zg===", "Zg==\n", " Zg==", "!!!!", "=AAA", "A=AA", "AA=A", "====", "Zh==", "Zm9=" }) do
		assert(AES.decode_base64(value) == nil, "noncanonical Base64 was admitted")
	end
end)
check("malformed ciphertext and deterministic bad padding return no partial plaintext", function()
	local encrypted = assert(AES.encrypt(KEY, IV, string.rep("x", 32)))
	local broken = encrypted:sub(1, -18) .. string.char((encrypted:byte(-17) + 1) % 256) .. encrypted:sub(-16)
	assert(AES.decrypt(KEY, IV, broken) == nil)
	for _, bytes in ipairs({ "", "a", encrypted:sub(1, -2) }) do assert(AES.decrypt(KEY, IV, bytes) == nil) end
	for _, payload in ipairs({ "%%%", "QUJ=", "YQ==", "" }) do assert(cipher.decrypt(Codec.wrap(IV, payload)) == "") end
end)
check("warm row operations need no shell command, temporary output or key-bearing argv", function()
	local previous, previous_tmp = io.popen, os.getenv("TMPDIR")
	assert(uv.os_setenv("TMPDIR", root .. "/absent-output"))
	io.popen = function() error("warm encryption must not start a shell") end
	local ok, err = pcall(function()
		for index = 1, 24 do
			local value = "Synthetic\0native row " .. index .. "\n\n"
			assert(cipher.decrypt(assert(cipher.encrypt("synthetic-device", index, value))) == value)
		end
	end)
	io.popen = previous
	if previous_tmp then assert(uv.os_setenv("TMPDIR", previous_tmp)) else assert(uv.os_unsetenv("TMPDIR")) end
	assert(ok, err); assert(not uv.fs_lstat(root .. "/absent-output"))
end)
check("actual SQLite refuses failed EVP and admits exactly one healthy encrypted retry", function()
	writer = require("modules.keylogger.sqlite_writer")
	assert(writer.open_db(root .. "/metrics.sqlite"))
	for _, stage in ipairs({ "Init", "Update", "Final" }) do
		fault = stage
		assert(writer.insert_typing_events("native-receipt-device", { { text = "Synthetic\0receipt text" } }) == false)
		fault = nil
		assert(assert(writer.query_rows("SELECT count(*) FROM events_typing;"))[1] == "0")
	end
	assert(writer.insert_typing_events("native-receipt-device", { { text = "Synthetic\0receipt text" } }))
	local rows = assert(writer.query_rows("SELECT text FROM events_typing;"))
	assert(#rows == 1 and Codec.is_encrypted(rows[1]) and cipher.decrypt(rows[1]) == "Synthetic\0receipt text")
end)
check("saved ON without EVP keeps real collector SQL closed and recovers retained input once", function()
	require("compat.utf8").install()
	writer.close_db() -- The next owner opens a distinct database and schema.
	local preferences = require("tests.support.metrics_preferences_fixture").new({ initial = {
		["metrics.encrypt"] = true, ["metrics.enabled"] = true,
	} })
	package.loaded["infra.metrics_preferences"] = preferences
	package.loaded["modules.keylogger.keylogger"] = nil
	AES.available = false
	local K = require("modules.keylogger.keylogger")
	assert(K.init({ sqlite_path = root .. "/collector.sqlite", log_dir = root .. "/logs" }) ~= false)
	assert(K.is_encrypt_enabled() and cipher.is_enabled() and K.get_privacy_state().encrypt)
	K.on_keydown("a", 1000, "synthetic-app")
	local Drain = require("tests.support.sqlite_flush_native")
	assert(K.flush() == false and not Drain.wait(K))
	assert(K._pending_buffer_count_for_test() == 1 and K.has_flush_debt())
	assert(assert(writer.query_rows("SELECT count(*) FROM events_typing;"))[1] == "0")
	assert(assert(writer.query_rows("SELECT count(*) FROM ngram_chars;"))[1] == "0")
	AES.available = true
	assert(Drain.flush(K))
	local rows = assert(writer.query_rows("SELECT text FROM events_typing;"))
	assert(#rows == 1 and Codec.is_encrypted(rows[1]) and cipher.decrypt(rows[1]) == "a")
	assert(assert(writer.query_rows("SELECT sum(c) FROM ngram_chars;"))[1] == "1")
	-- The walk context still holds the open word and session, which stop()
	-- credits in a final native flush: stop answers false until that flush
	-- physically settles, as the shutdown coordinator polls it.
	local stop_deadline = uv.hrtime() + 4000000000
	while not K.stop() do
		assert(uv.hrtime() < stop_deadline, "the final keylogger flush never settled")
		uv.run("nowait"); uv.sleep(1)
	end
end)

if writer then writer.close_db() end
assert(uv.os_setenv("PATH", previous_path))
local function remove(path)
	if assert(uv.fs_lstat(path)).type == "directory" then
		for name in uv.fs_scandir_next, assert(uv.fs_scandir(path)) do remove(path .. "/" .. name) end
		assert(uv.fs_rmdir(path))
	else assert(uv.fs_unlink(path)) end
end
remove(root)
assert(not uv.loop_alive(), "fixture retained native ownership")
print(string.format("Native at-rest cryptography receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
