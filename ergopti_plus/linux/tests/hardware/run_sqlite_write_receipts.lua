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

for index, script in ipairs({
	"INSERT INTO receipt VALUES ('nul-write-one');\n\0INSERT INTO receipt VALUES ('suffix');",
	"CREATE TABLE nul_ddl_receipt(value TEXT);\n\0SELECT 1;",
	"INSERT INTO receipt VALUES ('nul-write-two');\n-- comment prefix\0suffix",
}) do
	check("native SQL NUL " .. index .. " cannot execute its complete prefix", function()
		assert(Writer.exec_sql("DELETE FROM receipt WHERE value LIKE 'nul-write-%'; DROP TABLE IF EXISTS nul_ddl_receipt;"))
		assert(Writer.exec_sql(script) == false, "unrepresentable raw SQL reported success")
		local rows = assert(Writer.query_rows("SELECT value FROM receipt WHERE value LIKE 'nul-write-%';"))
		assert(#rows == 0, "refused command executed a durable INSERT prefix")
		local tables = assert(Writer.query_rows("SELECT name FROM sqlite_master WHERE name='nul_ddl_receipt';"))
		assert(#tables == 0, "refused command executed a durable DDL prefix")
	end)
end

check("native query NUL cannot execute its preceding write", function()
	local rows = Writer.query_rows("INSERT INTO receipt VALUES ('nul-query-prefix');\n\0SELECT value FROM receipt;")
	assert(rows == nil, "unrepresentable query reported accepted rows")
	local persisted = assert(Writer.query_rows("SELECT value FROM receipt WHERE value='nul-query-prefix';"))
	assert(#persisted == 0, "refused query executed a durable write prefix")
end)

check("native legal SQL retains Unicode, shell literals and encoded NUL bytes", function()
	assert(Writer.exec_sql("INSERT INTO receipt VALUES ('été\t'||char(13)||char(10)||'quote'' $() `literal` \"double\"'); INSERT INTO receipt VALUES (CAST(X'610062' AS TEXT));"))
	local encoded = assert(Writer.query_rows("SELECT hex(value) FROM receipt WHERE hex(value)='610062';"))
	assert(#encoded == 1 and encoded[1] == "610062", "encoded NUL data was rejected or shortened")
	local literal = assert(Writer.query_rows("SELECT hex(value) FROM receipt WHERE value LIKE 'été%';"))
	local expected = "été\t\r\nquote' $() `literal` \"double\""
	local expected_hex = expected:gsub(".", function(byte) return string.format("%02X", string.byte(byte)) end)
	assert(#literal == 1 and literal[1] == expected_hex, "legal literal SQL bytes were changed: " .. tostring(literal[1]) .. " expected " .. expected_hex)
end)

assert(Writer.exec_sql("CREATE TABLE transaction_receipt(value TEXT UNIQUE CHECK(value <> 'denied-check')); INSERT INTO transaction_receipt VALUES ('retained');"))
for _, case in ipairs({
	{ "missing table", "INSERT INTO absent_native_transaction VALUES (1);" },
	{ "syntax", "SELECT FROM;" },
	{ "unique", "INSERT INTO transaction_receipt VALUES ('retained');" },
	{ "check", "INSERT INTO transaction_receipt VALUES ('denied-check');" },
}) do
	check("native multiline transaction " .. case[1] .. " cannot commit after a failed statement", function()
		assert(Writer.exec_sql("DELETE FROM transaction_receipt WHERE value <> 'retained';"))
		-- The migration backend joins complete statements on separate lines.
		-- sqlite3_exec stops within one line, but the default CLI continues at
		-- the next line, including COMMIT, unless its native bail flag is set.
		local script = "BEGIN;\nINSERT INTO transaction_receipt VALUES ('prefix');\n"
			.. case[2] .. "\nINSERT INTO transaction_receipt VALUES ('suffix');\nCOMMIT;"
		assert(Writer.exec_sql(script) == false, "failed statement reported successful transaction")
		local rows = assert(Writer.query_rows("SELECT value FROM transaction_receipt ORDER BY value;"))
		assert(#rows == 1 and rows[1] == "retained", "failed transaction persisted a prefix/suffix or lost prior data")
	end)
end

check("native same-line SQL error still closes and rolls back its transaction", function()
	assert(Writer.exec_sql("DELETE FROM transaction_receipt WHERE value <> 'retained';"))
	assert(Writer.exec_sql("BEGIN; INSERT INTO transaction_receipt VALUES ('same-line'); INSERT INTO absent_native_transaction VALUES (1); COMMIT;") == false)
	local rows = assert(Writer.query_rows("SELECT value FROM transaction_receipt ORDER BY value;"))
	assert(#rows == 1 and rows[1] == "retained")
end)

check("native healthy multiline commit and explicit rollback retain their semantics", function()
	assert(Writer.exec_sql("BEGIN;\nINSERT INTO transaction_receipt VALUES ('healthy-prefix');\nINSERT INTO transaction_receipt VALUES ('healthy-suffix');\nCOMMIT;"))
	local committed = assert(Writer.query_rows("SELECT value FROM transaction_receipt WHERE value LIKE 'healthy-%' ORDER BY value;"))
	assert(#committed == 2 and committed[1] == "healthy-prefix" and committed[2] == "healthy-suffix")
	assert(Writer.exec_sql("BEGIN;\nINSERT INTO transaction_receipt VALUES ('explicit-rollback');\nROLLBACK;"))
	local rolled_back = assert(Writer.query_rows("SELECT value FROM transaction_receipt WHERE value='explicit-rollback';"))
	assert(#rolled_back == 0, "healthy explicit rollback was committed")
end)

Writer.close_db()
for name in uv.fs_scandir_next, assert(uv.fs_scandir(root)) do assert(uv.fs_unlink(root .. "/" .. name)) end
assert(uv.fs_rmdir(root))
print(string.format("Native SQLite write receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
