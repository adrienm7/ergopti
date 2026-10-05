--- tests/hardware/run_sqlite_meta_values.lua
--- ==============================================================================
--- MODULE: Native SQLite Metadata Value Framing (Linux)
--- DESCRIPTION:
--- Public metadata writes and reads use real sqlite3 and owned files. Native
--- hex(value) independently proves stored bytes before testing scalar framing.
--- A controlled CLI wrapper delegates argv/stdin to real sqlite3, then refuses
--- its exit status; returned rows are genuine, not simulated. This tests the
--- supported metadata API, not ordinary compact migration-cursor corruption.
--- ==============================================================================

local uv = require("luv")
require("compat.utf8").install()
local Shell = require("adapters.shell_runner")
local Writer = require("modules.keylogger.sqlite_writer")
local real_sqlite = assert(Shell.exec_line("command -v sqlite3"))
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-sqlite-meta-values-XXXXXX"))
local original_path = assert(os.getenv("PATH"))
local database = root .. "/metrics.sqlite"
local checks, failures = 0, 0

local function write(path, content)
	local file = assert(io.open(path, "wb"))
	assert(file:write(content) and file:close())
end

local function check(name, fn)
	checks = checks + 1
	local ok, reason = xpcall(fn, debug.traceback)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(reason) .. "\n")
	end
end

local function hex(value)
	return (value:gsub(".", function(byte) return string.format("%02X", byte:byte()) end))
end

assert(Writer.open_db(database))
local cases = {
	{ "ordinary compact migration cursor", '{"table":"events_typing","id":7}' },
	{ "empty string", "" },
	{ "UTF-8 quote CR and tab", "été 😀 ' \r\t literal" },
	{ "line feed", "one\ntwo" },
	{ "leading line feed", "\ntwo" },
	{ "trailing line feed", "one\n" },
	{ "CRLF", "one\r\ntwo" },
	{ "NUL suffix", "one\0two" },
	{ "leading NUL", "\0two" },
	{ "trailing NUL", "one\0" },
	{ "mixed native control bytes", "\0first\r\nsecond\0third\n" },
	{ "receipt-looking text", "\nERGOPTI_SQL_EXIT_STATUS=7\n" },
	{ "JSON-looking text", "null" },
	{ "large value", string.rep('été " literal\n', 4000) },
}

for index, case in ipairs(cases) do
	local key = "owned-meta-" .. index
	assert(Writer.set_meta(key, case[2]), "native metadata fixture write refused")
	check(case[1] .. " preserves exact public metadata bytes", function()
		local stored = assert(Writer.query_rows("SELECT hex(value) FROM meta WHERE key='" .. key .. "';"))
		assert(#stored == 1 and stored[1] == hex(case[2]), "native write changed the independent stored bytes")
		assert(Writer.get_meta(key) == case[2], "scalar framing truncated or changed the stored metadata value")
	end)
end

check("missing metadata remains distinct from an empty stored string", function()
	assert(Writer.get_meta("owned-absent-meta") == nil)
	assert(Writer.get_meta("owned-meta-2") == "")
end)

write(root .. "/sqlite3", table.concat({
	"#!/bin/sh",
	Shell.quote(real_sqlite) .. ' "$@"',
	'owned_result=$?; [ "$owned_result" -eq 0 ] || exit "$owned_result"',
	"owned_mode=$(cat " .. Shell.quote(root .. "/mode") .. ")",
	'case "$owned_mode" in success) exit 0;; term) kill -TERM $$;; *) exit "$owned_mode";; esac',
	"",
}, "\n"))
assert(uv.fs_chmod(root .. "/sqlite3", 448))
assert(uv.os_setenv("PATH", root .. ":" .. original_path))
for _, status in ipairs({ "7", "23", "term" }) do
	write(root .. "/mode", status)
	check("genuine native metadata rows followed by " .. status .. " remain refused", function()
		assert(Writer.get_meta("owned-meta-8") == nil, "a failed CLI published its valid metadata prefix")
	end)
end

write(root .. "/mode", "success")
check("same-owner native retry retains the full NUL suffix and empty value", function()
	assert(Writer.get_meta("owned-meta-8") == "one\0two")
	assert(Writer.get_meta("owned-meta-2") == "")
end)
assert(uv.os_setenv("PATH", original_path))

check("all native metadata rows remain unchanged after framing and refusal checks", function()
	local rows = assert(Writer.query_rows("SELECT key,hex(value) FROM meta WHERE key LIKE 'owned-meta-%' ORDER BY key;"))
	assert(#rows == #cases, "metadata read/refusal created or removed rows")
	local actual = {}
	for _, row in ipairs(rows) do
		local key, value = assert(row:match("^([^|]+)|([0-9A-F]*)$"))
		actual[key] = value
	end
	for index, case in ipairs(cases) do assert(actual["owned-meta-" .. index] == hex(case[2])) end
end)

Writer.close_db()
for name in uv.fs_scandir_next, assert(uv.fs_scandir(root)) do assert(uv.fs_unlink(root .. "/" .. name)) end
assert(uv.fs_rmdir(root))
assert(checks == 20, "native metadata regression check floor changed")
print(string.format("Native SQLite metadata values: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
