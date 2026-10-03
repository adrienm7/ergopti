--- tests/hardware/run_crypto_cli_receipts.lua
--- ==============================================================================
--- MODULE: Native Linux CLI SHA-256 Exit Receipts
--- DESCRIPTION:
--- Runs the production CLI fallback under actual Lua 5.4 without an FFI digest
--- provider. Fault wrappers delegate real OpenSSL, then fail or return only part
--- of real decoder output. Useful stdout cannot acknowledge a failed primitive.
--- Independent shared byte vectors and large quoting controls preserve the
--- healthy transport. Requires an ordinary user; no hardware input is claimed.
--- ==============================================================================

local uv = require("luv")
local Shell = require("adapters.shell_runner")
assert(uv.getuid() ~= 0, "native CLI tests require an ordinary user")
assert(not require("infra.openssl_digest").available, "run this actual fallback fixture with lua5.4, without FFI")
local Crypto = require("adapters.crypto")
local real = assert(Shell.exec_line("command -v openssl"))
local real_head = assert(Shell.exec_line("command -v head"))
local original_path = assert(os.getenv("PATH"))
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-cli-crypto-XXXXXX"))
local checks, failures = 0, 0

local function write(path, text)
	local file = assert(io.open(path, "w"))
	assert(file:write(text) and file:close())
end

write(root .. "/openssl", table.concat({
	"#!/bin/sh",
	"operation=other",
	'case "$1" in dgst) operation=digest;; base64) operation=decode;; esac',
	"read target fault < " .. Shell.quote(root .. "/mode"),
	'if [ "$operation" = decode ] && [ "$target" = decode ] && [ "${fault#PARTIAL}" != "$fault" ]; then',
	Shell.quote(real) .. ' "$@" > ' .. Shell.quote(root .. "/native-output"),
	"native_status=$?",
	Shell.quote(real_head) .. " -c 1 " .. Shell.quote(root .. "/native-output"),
	'fault=${fault#PARTIAL}',
	"else",
	Shell.quote(real) .. ' "$@"',
	"native_status=$?",
	"fi",
	"printf '%s %s\\n' \"$operation\" \"$native_status\" >> " .. Shell.quote(root .. "/calls"),
	'if [ "$operation" = "$target" ]; then',
	'case "$fault" in TERM) kill -TERM $$;; KILL) kill -KILL $$;; *) exit "$fault";; esac',
	"fi",
	'exit "$native_status"',
	"",
}, "\n"))
assert(uv.fs_chmod(root .. "/openssl", 448))
assert(uv.os_setenv("PATH", root .. ":" .. original_path))

local function mode(operation, fault)
	write(root .. "/mode", operation .. " " .. tostring(fault or 0) .. "\n")
	write(root .. "/calls", "")
end

local function observed(operation)
	local file = assert(io.open(root .. "/calls", "r"))
	local calls = assert(file:read("*a"))
	assert(file:close())
	assert(calls:find(operation .. " 0\n", 1, true), "the wrapper must delegate successful actual OpenSSL work")
end

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

for _, input in ipairs({ "abc", "a\0retained bytes" }) do
	local kind = input:find("\0", 1, true) and "binary" or "text"
	for _, fault in ipairs({ 1, 7, 23, "TERM", "KILL" }) do
		check("failed actual " .. kind .. " digest refuses useful stdout " .. fault, function()
			mode("digest", fault)
			local digest = Crypto.sha256(input)
			observed("digest")
			assert(digest == "", "an unsuccessful native primitive admitted a useful digest")
		end)
	end
end

for _, fault in ipairs({ 1, 7, 23, "TERM", "KILL", "PARTIAL7", "PARTIALTERM" }) do
	check("failed actual decoder invalidates its digest consumer " .. fault, function()
		mode("decode", fault)
		local digest = Crypto.sha256("a\0retained bytes")
		observed("decode")
		observed("digest")
		assert(digest == "", "a failed producer admitted a digest of untrusted or shortened bytes")
	end)
end

mode("success")
for _, row in ipairs(require("tests.support.crypto_vectors")) do
	-- The existing CLI capability explicitly retains Linux's exec size limit.
	-- Oversized rows are covered by the separate actual native SHA256 fixture.
	if #row.input <= 10000 then
		check("healthy actual fallback preserves shared byte vector " .. row.id, function()
			assert(Crypto.sha256(row.input) == row.sha256)
			observed("digest")
		end)
	end
end

check("healthy fallback retains repeated quotes without requoting the stdin body", function()
	local data = string.rep("'a", 22000)
	local command = require("shell.heredoc").with_exact_stdin(Shell.quote(real) .. " dgst -sha256 -hex", data)
	local expected = assert(Shell.exec_line(command)):match("[0-9a-f]+$")
	assert(expected and #expected == 64)
	assert(Crypto.sha256(data) == expected, "supervision must not expand the data argument beyond its original byte budget")
end)

assert(uv.os_setenv("PATH", original_path))
local request = assert(uv.fs_scandir(root))
while true do
	local name = uv.fs_scandir_next(request)
	if not name then break end
	assert(uv.fs_unlink(root .. "/" .. name))
end
assert(uv.fs_rmdir(root))
print(string.format("Native CLI crypto receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
