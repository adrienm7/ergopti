--- tests/unit/modules/keystats/storage/test_sqlite_child.lua

--- ==============================================================================
--- MODULE: Persistent sqlite3 Child Tests (Linux)
--- DESCRIPTION:
--- The synchronous metrics writer runs its statements on one long-lived
--- sqlite3 (docs/design/linux-sqlite-persistent-child.md) instead of a shell and
--- a process per call. These cases drive the real sqlite3 CLI through LuaJIT
--- FFI: one child serves the store boot; a success needs this call's random
--- token; a refused statement rolls its batch back and ends the child; a child
--- that died is replaced; a hung child is killed at its deadline; and no typed
--- byte reaches a log line.
--- ==============================================================================

local helpers = require("tests.helpers")
local Child = require("modules.keystats.sqlite_child")

-- These cases drive the real sqlite3 CLI, which every CI image installs:
-- its absence is a broken host, never a skipped case.
local SQLITE3_STATUS = os.execute("command -v sqlite3 >/dev/null 2>&1")
assert(SQLITE3_STATUS == true or SQLITE3_STATUS == 0, "the sqlite3 CLI is not on PATH")

local SECRET = "typed-secret-7f3a"

--- Runs a shell command and returns its whole output.
local function sh(command)
	local pipe = assert(io.popen(command .. " 2>&1", "r"))
	local out = pipe:read("*a")
	pipe:close()
	return out
end

--- A fresh private directory and a store path inside it.
local function scratch_db()
	local dir = assert(sh("mktemp -d"):match("^(%S+)"))
	return dir .. "/metrics.sqlite", dir
end

--- Whether a process id is alive (not a zombie), read from the kernel's
--- /proc/<pid>/stat rather than `ps -p`: BusyBox ps (Alpine) has no -p, and
--- the first letter of its usage error read as a live state.
local function alive(pid)
	local file = io.open("/proc/" .. tostring(pid) .. "/stat", "r")
	if not file then return false end
	local stat = file:read("*a")
	file:close()
	-- The command name in parentheses may hold spaces or parentheses: the state
	-- is the field after the last ")".
	local state = stat:match("^.*%)%s+(%a)")
	assert(state, "unreadable /proc/" .. tostring(pid) .. "/stat")
	return state ~= "Z" and state ~= "X"
end

--- Records every log line of the shim logger the writer and the child use.
local function capture_logs(body)
	local Logger = require("core.logger.engine.shim")
	local lines, saved = {}, {}
	for _, level in ipairs({ "debug", "info", "warn", "error", "success", "start" }) do
		saved[level] = Logger[level]
		Logger[level] = function(_, message, ...)
			local ok, text = pcall(string.format, message, ...)
			lines[#lines + 1] = level .. " " .. (ok and text or message)
		end
	end
	local ok, err = pcall(body, lines)
	for level, fn in pairs(saved) do Logger[level] = fn end
	if not ok then error(err, 0) end
	return lines
end

local RUN = 2000

helpers.describe("persistent sqlite3 child", function()
	if not rawget(_G, "jit") then
		helpers.it("is unavailable on stock Lua, whose writer keeps one process per statement", function()
			helpers.assert_eq(Child.available(), false)
		end)
		return
	end

	helpers.it("is available under LuaJIT", function()
		helpers.assert_true(Child.available(), "the CI lane's LuaJIT must host the child")
	end)

	helpers.it("serves the whole store boot from one child and ends it at close", function()
		local db, dir = scratch_db()
		local Writer = helpers.fresh_module("modules.keystats.sqlite_writer")
		local spawned = 0
		local native_popen = io.popen
		io.popen = function(command, ...)
			if command:find("sqlite3", 1, true) then spawned = spawned + 1 end
			return native_popen(command, ...)
		end
		local ok, err = pcall(function()
			helpers.assert_true(Writer.open_db(db, { persistent_child = true }), "the store opens")
			local pid = Child.pid()
			helpers.assert_true(pid ~= nil and alive(pid), "one child is live")
			helpers.assert_true(Writer.register_device("linux-test", "test", "linux", "6", "sig"), "registration")
			Writer.ensure_token_encoding()
			Writer.read_open_walk("linux-test")
			helpers.assert_true(Writer.set_meta("probe", "a\nb"), "set_meta")
			helpers.assert_eq(Writer.get_meta("probe"), "a\nb", "get_meta through the child")
			helpers.assert_eq(Writer.query_rows("SELECT 1 UNION ALL SELECT 2;")[2], "2", "query_rows")
			helpers.assert_eq(Child.pid(), pid, "every statement used the same child")
			helpers.assert_eq(spawned, 0, "no sqlite3 process per statement")
			Writer.close_db()
			helpers.assert_nil(Child.pid(), "close_db ends the child")
			helpers.assert_true(not alive(pid), "and waits for it")
		end)
		io.popen = native_popen
		Writer.close_db()
		sh("rm -rf " .. dir)
		if not ok then error(err, 0) end
	end)

	helpers.it("accepts only this call's random token, never a forged acknowledgement", function()
		local db, dir = scratch_db()
		local forged = "ERGOPTI_SQL_ACK_" .. string.rep("0", 32)
		local result = Child.run("sqlite3", db, ".print " .. forged .. "\nSELECT 'after';", RUN)
		helpers.assert_eq(result.status, "ok")
		helpers.assert_eq(result.output, forged .. "\nafter\n", "the forged line is data, the real token follows")
		local row = Child.run("sqlite3", db, "SELECT '" .. forged .. "';", RUN)
		helpers.assert_eq(row.output, forged .. "\n", "a stored row equal to a token is data")
		Child.close(RUN)
		sh("rm -rf " .. dir)
	end)

	helpers.it("ends the child on a refused statement, rolls the batch back and starts a new one", function()
		local db, dir = scratch_db()
		helpers.assert_eq(Child.run("sqlite3", db, "CREATE TABLE t(x);", RUN).status, "ok")
		local pid = Child.pid()
		local refused = Child.run("sqlite3", db, "BEGIN; INSERT INTO t VALUES(1); INSERT INTO absent VALUES(2); COMMIT;", RUN)
		helpers.assert_eq(refused.status, "refused")
		helpers.assert_true(refused.exit_code ~= 0, "the child exited with an error")
		helpers.assert_nil(Child.pid(), "the refused child is reaped")
		helpers.assert_true(not alive(pid), "and gone")
		local count = Child.run("sqlite3", db, "SELECT count(*) FROM t;", RUN)
		helpers.assert_eq(count.status, "ok")
		helpers.assert_eq(count.output, "0\n", "the batch rolled back")
		helpers.assert_true(Child.pid() ~= pid, "the next call started a new child")
		local open = Child.run("sqlite3", db, "BEGIN; INSERT INTO t VALUES(3);", RUN)
		helpers.assert_eq(open.status, "refused", "a script that leaves a transaction open is refused")
		helpers.assert_eq(Child.run("sqlite3", db, "SELECT count(*) FROM t;", RUN).output, "0\n", "and rolled back")
		Child.close(RUN)
		sh("rm -rf " .. dir)
	end)

	helpers.it("replaces a child that died between calls and refuses one that dies mid-call", function()
		local db, dir = scratch_db()
		helpers.assert_eq(Child.run("sqlite3", db, "CREATE TABLE t(x);", RUN).status, "ok")
		local pid = Child.pid()
		sh("kill -9 " .. pid)
		-- Dead between calls: wait until the kernel has made it a zombie.
		for _ = 1, 100 do
			if not alive(pid) then break end
			sh("sleep 0.01")
		end
		helpers.assert_true(not alive(pid), "the child died")
		local result = Child.run("sqlite3", db, "INSERT INTO t VALUES(1); SELECT count(*) FROM t;", RUN)
		helpers.assert_eq(result.status, "ok", "a dead child is replaced before the script is sent")
		helpers.assert_eq(result.output, "1\n")
		helpers.assert_true(Child.pid() ~= pid, "by a new child")
		local mid = Child.run("sqlite3", db, "BEGIN; INSERT INTO t VALUES(2);\n.system kill -9 $PPID\nCOMMIT;", RUN)
		helpers.assert_true(mid.status == "refused" or mid.status == "lost", "a child that dies mid-call is no success")
		helpers.assert_nil(Child.pid(), "and is reaped")
		helpers.assert_eq(Child.run("sqlite3", db, "SELECT count(*) FROM t;", RUN).output, "1\n", "its batch rolled back")
		Child.close(RUN)
		sh("rm -rf " .. dir)
	end)

	helpers.it("kills a child that misses its read deadline", function()
		local db, dir = scratch_db()
		helpers.assert_eq(Child.run("sqlite3", db, "SELECT 1;", RUN).status, "ok")
		local pid = Child.pid()
		local clock = os.time()
		local hung = Child.run("sqlite3", db, ".system sleep 5", 300)
		helpers.assert_eq(hung.status, "lost")
		helpers.assert_eq(hung.detail, "deadline")
		helpers.assert_true(os.time() - clock <= 2, "the deadline, not the hung child, ended the wait")
		helpers.assert_nil(Child.pid(), "the hung child is reaped")
		helpers.assert_true(not alive(pid), "and killed")
		helpers.assert_eq(Child.run("sqlite3", db, "SELECT 2;", RUN).output, "2\n", "the next call starts a new child")
		Child.close(RUN)
		sh("rm -rf " .. dir)
	end)

	helpers.it("ends a child that wrote out of frame before the next call", function()
		local db, dir = scratch_db()
		helpers.assert_eq(Child.run("sqlite3", db, ".system (sleep 0.2; echo late) &", RUN).status, "ok")
		local pid = Child.pid()
		sh("sleep 0.5")
		local result = Child.run("sqlite3", db, "SELECT 3;", RUN)
		helpers.assert_eq(result.output, "3\n", "late bytes never join another call's output")
		helpers.assert_true(Child.pid() ~= pid, "the child that wrote them was replaced")
		Child.close(RUN)
		sh("rm -rf " .. dir)
	end)

	helpers.it("keeps typed text out of every log line", function()
		local db, dir = scratch_db()
		local Writer = helpers.fresh_module("modules.keystats.sqlite_writer")
		local lines = capture_logs(function()
			helpers.assert_true(Writer.open_db(db, { persistent_child = true }), "the store opens")
			helpers.assert_eq(Writer.exec_sql("INSERT INTO absent_table VALUES('" .. SECRET .. "');"), false)
			helpers.assert_eq(Writer.exec_sql("INSERT INTO meta(key, value) VALUES('" .. SECRET .. "' 'x');"), false)
			helpers.assert_nil(Writer.query_rows("SELECT * FROM '" .. SECRET .. "';"))
			Writer.close_db()
		end)
		local refusals = 0
		for _, line in ipairs(lines) do
			helpers.assert_true(not line:find(SECRET, 1, true), "a log line carries typed text: " .. line)
			if line:find("SQLite error", 1, true) or line:find("read refused", 1, true) then refusals = refusals + 1 end
		end
		helpers.assert_true(refusals >= 3, "each refusal is still logged, as a category")
		sh("rm -rf " .. dir)
	end)
end)
