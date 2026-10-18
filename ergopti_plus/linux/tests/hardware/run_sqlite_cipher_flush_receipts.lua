--- tests/hardware/run_sqlite_cipher_flush_receipts.lua
--- ==============================================================================
--- MODULE: Native Cipher-Owned SQLite Flush Receipts
--- DESCRIPTION:
--- Extracts the cipher case from the two-ABI SQLite ownership fixture. LuaJIT
--- retains genuine key-refusal/encrypted-retry/aggregate/ID assertions; PUC Lua
--- 5.4 proves its explicit native-capability refusal, retained RAM and honest
--- shutdown ACK. Neither branch substitutes plaintext or a fake crypto owner.
--- ==============================================================================

local uv = require("luv")
require("compat.utf8").install()
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-cipher-flush-XXXXXX"))
for _, key in ipairs({ "CONFIG", "DATA", "CACHE", "STATE" }) do
	assert(uv.os_setenv("XDG_" .. key .. "_HOME", root .. "/" .. key:lower()))
end
assert(uv.fs_mkdir(root .. "/config", 448)); assert(uv.fs_mkdir(root .. "/config/ergopti", 448))
local file = assert(io.open(root .. "/config/ergopti/config.toml", "w"))
assert(file:write("[metrics]\nenabled=true\nencrypt=true\n") and file:close())
local Cipher = require("modules.keylogger.text_cipher")
local AES = require("infra.openssl_cipher")
local K = require("modules.keylogger.keylogger")
local W = require("modules.keylogger.sqlite_writer")
local Drain = require("tests.support.sqlite_flush_native")
local checks = 0
local function pass(name) checks = checks + 1; print("PASS " .. name) end
local function scalar(sql) return tonumber(assert(W.query_rows(sql))[1]) end
Cipher._set_machine_id_path(root .. "/missing-machine-id")
assert(K.init({ sqlite_path = root .. "/metrics.sqlite", log_dir = root .. "/logs" }) ~= false)
assert(K.is_encrypt_enabled() and Cipher.is_enabled() and K.get_privacy_state().encrypt)
local revision = W.get_revision()
for index = 1, #"owned-secret" do K.on_keydown(("owned-secret"):sub(index, index), 2500 + index, "cipher-refusal") end
assert(K.flush() == false and not Drain.wait(K))
assert(K.get_flush_status().phase == "compose_retry" and K.get_flush_status().read_safe)
assert(K._pending_buffer_count_for_test() == 12 and K.get_range_payload().today["cipher-refusal"].c.o.c == 1)
assert(scalar("SELECT COUNT(*) FROM events_typing WHERE app='cipher-refusal';") == 0)
assert(scalar("SELECT COUNT(*) FROM ngram_chars WHERE app='cipher-refusal';") == 0)
assert(W.get_revision() == revision, "refused cipher must not advance the acknowledged watermark")
local cursor = assert(W.get_meta("linux_next_event_id"))
pass("saved ON and unavailable encryption retain raw/derived RAM without plaintext, watermark or saved ACK")

file = assert(io.open(root .. "/owned-machine-id", "w"))
assert(file:write("owned-machine-id-fixture\n") and file:close())
Cipher._set_machine_id_path(root .. "/owned-machine-id")
if rawget(_G, "jit") then
	assert(AES.available and Cipher.is_available(), "the native LuaJIT fixture requires real EVP AES")
	assert(Drain.flush(K))
	local rows = assert(W.query_rows("SELECT text FROM events_typing WHERE app='cipher-refusal';"))
	assert(#rows == 1 and require("keylogger.text_crypto").is_encrypted(rows[1]))
	assert(Cipher.decrypt(rows[1]) == "owned-secret")
	assert(scalar("SELECT SUM(c) FROM ngram_chars WHERE app='cipher-refusal';") == 12)
	assert(W.get_meta("linux_next_event_id") == cursor, "retry must reuse the original reserved IDs")
	assert(not K.has_flush_debt() and K._pending_buffer_count_for_test() == 0)
	pass("actual EVP recovery writes exactly one genuine encrypted row and all twelve aggregate counts")
else
	assert(not AES.available, "this fixture covers actual PUC Lua without FFI")
	local previous, calls = io.popen, 0
	io.popen = function() calls = calls + 1; error("missing native capability must not invoke CLI KDF or AES") end
	local ok, err = pcall(function()
		assert(Cipher.is_available() == false)
		assert(Cipher.encrypt("owned", 1, "synthetic text") == nil)
		assert(Cipher.decrypt("ergopti-enc-v1:" .. string.rep("ab", 16) .. ":YQ==") == "")
	end)
	io.popen = previous
	assert(ok, err); assert(calls == 0)
	assert(K.flush() == false and not Drain.wait(K))
	assert(K._pending_buffer_count_for_test() == 12 and K.has_flush_debt())
	assert(scalar("SELECT COUNT(*) FROM events_typing;") == 0 and scalar("SELECT COUNT(*) FROM ngram_chars;") == 0)
	assert(W.get_meta("linux_next_event_id") == cursor and W.get_revision() == revision)
	pass("actual PUC Lua refusal precedes all KDF/AES processes and preserves reserved IDs, watermarks and source")
end
local deadline = uv.hrtime() + 4000000000
repeat uv.run("nowait"); if K.stop() then break end; uv.sleep(1) until uv.hrtime() >= deadline
assert(K.stop() and K.get_flush_status().stopping)
if not rawget(_G, "jit") then
	assert(not K.get_flush_status().committed and K._pending_buffer_count_for_test() == 12)
	assert(scalar("SELECT COUNT(*) FROM events_typing;") == 0)
end
pass("shutdown acknowledges exact physical retirement independently of refused business persistence")
W.close_db()
local function remove(path)
	if assert(uv.fs_lstat(path)).type == "directory" then
		for name in uv.fs_scandir_next, assert(uv.fs_scandir(path)) do remove(path .. "/" .. name) end
		assert(uv.fs_rmdir(path))
	else assert(uv.fs_unlink(path)) end
end
remove(root)
assert(not uv.loop_alive())
assert(checks == 3)
print(string.format("Native cipher-owned SQLite flush: %d checks, 0 failures", checks))
