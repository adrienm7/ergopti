--- tests/unit/modules/keystats/storage/test_keystats_sqlite_read_concurrency.lua

--- ==============================================================================
--- MODULE: Dashboard read versus the single writer (Linux)
--- DESCRIPTION:
--- The metrics database uses a rollback journal (docs/memory/maintainer-decisions.md,
--- « Metrics dashboard »). A dashboard read that meets the writer's COMMIT lock
--- used to be refused at once ("database is locked") and the dashboard showed
--- nothing or less than the store held. A hot journal left by an interrupted
--- write must stay the writer's to recover: the reader refuses and touches nothing.
---
--- FEATURES & RATIONALE:
--- 1. The command builder places the busy wait on the script's first line.
--- 2. The real sqlite3 CLI waits for a held lock and returns the committed rows,
---    where the same command without the wait fails (the original defect).
--- 3. The real sqlite3 CLI refuses a database with a hot journal and leaves the
---    journal file in place (recovery is the writer's).
--- 4. The reader asks for the wait, from the shared timings registry.
--- ==============================================================================

local helpers = require("tests.helpers")
local Cmd = helpers.load_module("modules.keystats.sqlite_command")
local Timings = require("core.timing.engine.timings")

-- These cases drive the real sqlite3 CLI, which every CI image installs:
-- its absence is a broken host, never a skipped case.
local SQLITE3_STATUS = os.execute("command -v sqlite3 >/dev/null 2>&1")
assert(SQLITE3_STATUS == true or SQLITE3_STATUS == 0, "the sqlite3 CLI is not on PATH")

--- Runs a shell command and returns its whole output.
local function sh(command)
	local pipe = assert(io.popen(command .. " 2>&1", "r"))
	local out = pipe:read("*a")
	pipe:close()
	return out
end

--- Creates a private directory.
local function make_dir()
	local dir = assert(sh("mktemp -d"):match("^(%S+)"))
	return dir
end

helpers.describe("keystats sqlite read concurrency", function()
	helpers.it("composes the busy wait as the first stdin line", function()
		local cmd = Cmd.build("/db/m.sqlite", "SELECT 1;", { busy_timeout_ms = 500 })
		helpers.assert_contains(cmd, "\n.timeout 500\nSELECT 1;\n")
		local bad, reason = Cmd.build("/db/m.sqlite", "SELECT 1;", { busy_timeout_ms = -1 })
		helpers.assert_nil(bad)
		helpers.assert_contains(reason, "busy_timeout_ms")
	end)

	helpers.it("waits for the writer's lock instead of refusing the read", function()
		local dir = make_dir()
		local db = dir .. "/m.sqlite"
		sh("sqlite3 " .. db .. " 'PRAGMA journal_mode=DELETE; CREATE TABLE a(x); INSERT INTO a VALUES(1);'")
		local script = dir .. "/writer.sql"
		local fh = assert(io.open(script, "w"))
		fh:write("BEGIN EXCLUSIVE;\nINSERT INTO a VALUES(2);\n.shell sleep 1\nCOMMIT;\n")
		fh:close()
		os.execute("sqlite3 " .. db .. " < " .. script .. " >/dev/null 2>&1 &")
		os.execute("sleep 0.3")

		local without = sh(Cmd.build(db, "SELECT count(*) AS c FROM a;",
			{ flags = { "-readonly", "-json" }, capture_stderr = true }))
		helpers.assert_contains(without, "database is locked", "without a wait the read is refused (the old behaviour)")

		local waited = sh(Cmd.build(db, "SELECT count(*) AS c FROM a;",
			{ flags = { "-readonly", "-json" }, capture_stderr = true, busy_timeout_ms = 3000 }))
		helpers.assert_contains(waited, '"c":2', "the read waits for the COMMIT and returns the committed rows")
		os.execute("sleep 1; rm -rf " .. dir)
	end)

	helpers.it("refuses a hot journal and leaves its recovery to the writer", function()
		local dir = make_dir()
		local db = dir .. "/m.sqlite"
		sh("sqlite3 " .. db .. " 'PRAGMA journal_mode=DELETE; CREATE TABLE a(x); INSERT INTO a VALUES(1);'")
		-- An interrupted write: the journal of a transaction that never committed.
		local crashed = sh("python3 -I -c \"import sqlite3,shutil;"
			.. "c=sqlite3.connect('" .. db .. "',isolation_level=None);c.execute('begin');"
			.. "c.execute('pragma cache_size=1');"
			.. "[c.execute('insert into a values(?)',(i,)) for i in range(5000)];"
			.. "shutil.copy('" .. db .. "','" .. dir .. "/h.sqlite');"
			.. "shutil.copy('" .. db .. "-journal','" .. dir .. "/h.sqlite-journal')\"")
		helpers.assert_eq(crashed, "", "the fixture must leave a hot journal")
		local out = sh(Cmd.build(dir .. "/h.sqlite", "SELECT count(*) AS c FROM a;",
			{ flags = { "-readonly", "-json" }, capture_stderr = true, busy_timeout_ms = 500 }))
		helpers.assert_contains(out, "attempt to write a readonly database")
		helpers.assert_eq(Cmd.sanitise_error(out), "attempt to write a readonly database")
		helpers.assert_contains(sh("ls " .. dir), "h.sqlite-journal", "the reader must not delete or roll back the journal")
		os.execute("rm -rf " .. dir)
	end)

	helpers.it("passes the registry's wait to every dashboard read", function()
		local src = assert(helpers.read_driver_unit("local function sql_quote("))
		helpers.assert_contains(src, "busy_timeout_ms = READ_BUSY_TIMEOUT_MS")
		helpers.assert_contains(src, 'ms("keystats", "sqlite_read_busy_timeout_ms")')
		local wait = Timings.ms("keystats", "sqlite_read_busy_timeout_ms")
		helpers.assert_true(wait > 0 and wait < Timings.ms("keystats", "sqlite_operation_timeout_ms"),
			"the read wait stays below the hard deadline of one SQLite child")
	end)
end)
