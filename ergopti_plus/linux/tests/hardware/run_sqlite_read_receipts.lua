--- tests/hardware/run_sqlite_read_receipts.lua
--- ==============================================================================
--- MODULE: Native Linux SQLite Read Receipts
--- DESCRIPTION:
--- Drives the production migration/scalar/dashboard readers against an owned
--- native SQLite database. A CLI wrapper delegates unchanged argv and stdin to
--- real sqlite3, then refuses its terminal status. Every row is produced by
--- SQLite, never forged. This is a controlled faulty CLI adapter on actual
--- database reads; the ordinary controls run that same real CLI successfully.
--- ==============================================================================

local uv = require("luv")
local Shell = require("adapters.shell_runner")
local Writer = require("modules.keylogger.sqlite_writer")
local Reader = require("modules.keylogger.sqlite_reader")
local real_sqlite = assert(Shell.exec_line("command -v sqlite3"))
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-sqlite-reads-XXXXXX"))
local database = root .. "/metrics.sqlite"
local previous_path = assert(os.getenv("PATH"))
local checks, failures = 0, 0

local function write(path, content)
	local file = assert(io.open(path, "w"))
	assert(file:write(content) and file:close())
end

assert(Writer.open_db(database))
assert(Writer.exec_sql("CREATE TABLE receipt(value TEXT); INSERT INTO receipt VALUES ('one'),('two'),('three');"))
assert(Writer.set_meta("native-read-receipt", "trusted scalar"))
assert(Writer.set_meta("native-empty-receipt", ""))
assert(Writer.exec_sql("INSERT INTO agg_system_day(device_id,date,wifi_changes) VALUES ('native','2026-10-03',42);"))

write(root .. "/sqlite3", table.concat({
	"#!/bin/sh",
	"mode=$(cat " .. Shell.quote(root .. "/mode") .. ")",
	'if [ "$mode" = success ]; then exec ' .. Shell.quote(real_sqlite) .. ' "$@"; fi',
	Shell.quote(real_sqlite) .. ' "$@"',
	'result=$?; [ "$result" -eq 0 ] || exit "$result"',
	'case "$mode" in term) kill -TERM $$;; kill) kill -KILL $$;; *) exit "$mode";; esac',
	"",
}, "\n"))
assert(uv.fs_chmod(root .. "/sqlite3", 448))

local function mode(value) write(root .. "/mode", value) end

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

for _, status in ipairs({ 1, 7, 23, 127, 255 }) do
	check("actual SELECT followed by SQLite exit " .. status .. " cannot return accepted migration rows", function()
		assert(Writer.query_rows("SELECT value FROM receipt;\n.exit " .. status) == nil,
			"failed query admitted a prefix of rows")
	end)
end

assert(uv.os_setenv("PATH", root .. ":" .. previous_path))
for _, failure in ipairs({ "7", "127", "term", "kill" }) do
	check("real SQLite rows with terminal " .. failure .. " are refused", function()
		mode(failure)
		assert(Writer.query_rows("SELECT value FROM receipt;") == nil, "failed CLI returned accepted rows")
	end)
	check("real SQLite scalar with terminal " .. failure .. " is refused", function()
		mode(failure)
		assert(Writer.get_meta("native-read-receipt") == nil, "failed CLI returned a trusted migration scalar")
	end)
	check("real SQLite JSON with terminal " .. failure .. " is refused by the dashboard", function()
		mode(failure)
		assert(next(Reader.read_system_days(database, "2026-10-03", "2026-10-03")) == nil,
			"failed CLI published native rows as a successful projection")
	end)
end

mode("success")
check("ordinary native multi-row and scalar reads preserve exact data", function()
	local rows = assert(Writer.query_rows("SELECT value FROM receipt ORDER BY rowid;"))
	assert(#rows == 3 and table.concat(rows, "|") == "one|two|three")
	assert(Writer.get_meta("native-read-receipt") == "trusted scalar")
	assert(Writer.get_meta("native-empty-receipt") == "", "successful empty scalar changed meaning")
end)

check("ordinary native empty query remains an accepted empty table", function()
	local rows = Writer.query_rows("SELECT value FROM receipt WHERE 0;")
	assert(type(rows) == "table" and next(rows) == nil, "empty success was confused with failure")
end)

check("ordinary native JSON projection remains byte-derived and complete", function()
	local days = Reader.read_system_days(database, "2026-10-03", "2026-10-03")
	assert(days["2026-10-03"] and days["2026-10-03"].wifi_changes == 42)
	assert(next(Reader.read_system_days(database, "2026-10-04", "2026-10-04")) == nil)
end)

check("native marker-looking row bytes remain ordinary user data", function()
	local rows = assert(Writer.query_rows("SELECT char(10)||'ERGOPTI_SQL_EXIT_STATUS=7'||char(10);"))
	assert(#rows == 3 and rows[1] == "" and rows[2] == "ERGOPTI_SQL_EXIT_STATUS=7" and rows[3] == "")
end)

check("large native query output stays complete without a receipt file", function()
	local rows = assert(Writer.query_rows("SELECT printf('%.*c',150000,'x');"))
	assert(#rows == 1 and rows[1] == string.rep("x", 150000), "native query output was truncated")
end)

assert(uv.os_setenv("PATH", previous_path))
for index, method in ipairs({ "read_system_days", "read_manifest", "read_ngrams", "read_range_split_today" }) do
	for _, alias in ipairs({ false, true }) do
		check("native " .. method .. " cannot create " .. (alias and "a dangling alias target" or "an absent database"), function()
			local target = root .. "/absent-" .. index .. "-" .. tostring(alias) .. ".sqlite"
			local selected = alias and (target .. ".alias") or target
			local identity
			if alias then
				assert(uv.fs_symlink(target, selected))
				identity = assert(uv.fs_lstat(selected))
			end
			local result = Reader[method](selected, "2026-10-03", "2026-10-03", {})
			assert(type(result) == "table", "absent source lost its stable empty projection contract")
			assert(not uv.fs_lstat(target), "read-only projection created a phantom database file")
			assert(not uv.fs_lstat(target .. "-journal") and not uv.fs_lstat(target .. "-wal") and not uv.fs_lstat(target .. "-shm"),
				"absent-source refusal created native sidecars")
			if alias then
				local current = assert(uv.fs_lstat(selected))
				assert(current.type == "link" and current.dev == identity.dev and current.ino == identity.ino
					and uv.fs_readlink(selected) == target, "read-only refusal replaced its foreign alias")
			end
		end)
	end
end
Writer.close_db()
for name in uv.fs_scandir_next, assert(uv.fs_scandir(root)) do assert(uv.fs_unlink(root .. "/" .. name)) end
assert(uv.fs_rmdir(root))
print(string.format("Native SQLite read receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
