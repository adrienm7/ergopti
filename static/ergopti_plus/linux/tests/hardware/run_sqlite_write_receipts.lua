--- tests/hardware/run_sqlite_write_receipts.lua
--- ==============================================================================
--- MODULE: Native Linux SQLite Write Receipts
--- DESCRIPTION:
--- Runs the production metrics writer against the genuine sqlite3 CLI and an
--- owned database. Silent nonzero exits cannot acknowledge durable writes.
--- Large quote-heavy SQL retains its original stdin transport and byte budget.
--- No SQLite, file or process adapter is mocked; no keyboard is required.
--- ==============================================================================

local uv = require("luv")
local Writer = require("modules.keylogger.sqlite_writer")
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-sqlite-receipts-XXXXXX"))
local checks, failures = 0, 0
assert(Writer.open_db(root .. "/metrics.sqlite"), "actual canonical schema must bootstrap")
assert(Writer.exec_sql("CREATE TABLE receipt (value TEXT);"))

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

for _, status in ipairs({ 1, 7, 23, 127, 255 }) do
	check("actual silent SQLite exit " .. status .. " refuses the write receipt", function()
		assert(Writer.exec_sql(".exit " .. status) == false, "nonzero CLI exit reported a successful write")
	end)
end

for _, signal in ipairs({ "TERM", "KILL" }) do
	check("actual SQLite " .. signal .. " termination refuses the write receipt", function()
		-- SQLite owns the .shell child; that child's PPID is this exact CLI,
		-- never a daemon, shell wrapper or unrelated process.
		assert(Writer.exec_sql('.shell kill -' .. signal .. ' "$PPID"') == false,
			"native SQLite termination reported a successful write")
	end)
end

check("actual silent SQLite success remains accepted", function()
	assert(Writer.exec_sql(".exit 0") == true)
end)

check("ordinary actual SQLite write persists exact bytes", function()
	assert(Writer.exec_sql("INSERT INTO receipt VALUES ('native receipt');"))
	local rows = assert(Writer.query_rows("SELECT value FROM receipt;"))
	assert(#rows == 1 and rows[1] == "native receipt", "accepted write is absent from the native database")
end)

check("actual SQLite syntax failure refuses and leaves the writer retryable", function()
	assert(Writer.exec_sql("INSERT INTO missing_receipt VALUES (1);") == false)
	assert(Writer.exec_sql("INSERT INTO receipt VALUES ('retry receipt');"))
	local rows = assert(Writer.query_rows("SELECT count(*) FROM receipt;"))
	assert(#rows == 1 and rows[1] == "2", "retry duplicated or lost a durable row")
end)

check("large quote-heavy SQLite input retains its original native argv budget", function()
	local sql = "INSERT INTO receipt VALUES ('" .. string.rep("a''", 35000) .. "');"
	assert(#sql > 100000 and #sql < 110000)
	assert(Writer.exec_sql(sql), "receipt framing added another shell-quoting expansion")
	local rows = assert(Writer.query_rows("SELECT length(value), hex(substr(value,1,4)) FROM receipt WHERE length(value)>100;"))
	assert(#rows == 1 and rows[1] == "70000|61276127", "large batch lost or changed native SQL bytes")
end)

check("actual SQLite write needs no temporary receipt directory", function()
	local previous = os.getenv("TMPDIR")
	assert(uv.os_setenv("TMPDIR", root .. "/absent-receipt-directory"))
	local ok, err = pcall(function()
		assert(Writer.exec_sql("INSERT INTO receipt VALUES ('no temporary receipt');"))
		assert(not uv.fs_lstat(root .. "/absent-receipt-directory"))
	end)
	if previous then uv.os_setenv("TMPDIR", previous) else uv.os_unsetenv("TMPDIR") end
	assert(ok, err)
	local rows = assert(Writer.query_rows("SELECT value FROM receipt WHERE value='no temporary receipt';"))
	assert(#rows == 1 and rows[1] == "no temporary receipt")
end)

Writer.close_db()
for name in uv.fs_scandir_next, assert(uv.fs_scandir(root)) do assert(uv.fs_unlink(root .. "/" .. name)) end
assert(uv.fs_rmdir(root))
print(string.format("Native SQLite write receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
