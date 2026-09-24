--- tests/unit/modules/keylogger/test_sqlite_first_open.lua

--- ==============================================================================
--- MODULE: The Metrics Database On A First Start
--- DESCRIPTION:
--- The schema sets "PRAGMA journal_mode = DELETE", which the sqlite3 CLI
--- answers by printing "delete". The writer read any output as an error, so
--- every first start logged "SQLite error: delete", dropped the database and
--- kept the session's metrics in a JSON file the metrics windows never read.
--- Runs against the real sqlite3 CLI when it is installed (CI installs it).
--- ==============================================================================

local helpers = require("tests.helpers")

local HAS_SQLITE = (function()
	local status = os.execute("command -v sqlite3 >/dev/null 2>&1")
	return status == true or status == 0
end)()

helpers.describe("sqlite_writer: bootstrapping a new database", function()

	helpers.it("opens a fresh database and creates the schema", function()
		local writer = helpers.load_module("modules.keylogger.sqlite_writer")
		local dir = os.tmpname()
		os.remove(dir)
		local path = dir .. "/metrics.sqlite"
		local opened = writer.open_db(path)
		if not HAS_SQLITE then
			helpers.assert_true(not opened, "without sqlite3 the writer refuses, it does not pretend")
			return
		end
		helpers.assert_true(opened, "the first open succeeds")
		helpers.assert_true(writer.is_available())
		local pipe = io.popen("sqlite3 '" .. path .. "' \"SELECT count(*) FROM sqlite_master WHERE type='table';\"")
		local tables = tonumber(pipe:read("*l"))
		pipe:close()
		os.execute("rm -rf '" .. dir .. "'")
		helpers.assert_true(tables and tables > 5, "the schema's tables exist: " .. tostring(tables))
	end)

	helpers.it("finds sqlite3 on a system that has no `which`", function()
		-- Arch's base image ships sqlite3 but not `which`; the probe used it and
		-- disabled SQLite there. Any command starting with it fails here.
		local writer = helpers.load_module("modules.keylogger.sqlite_writer")
		local real_execute = os.execute
		os.execute = function(cmd)
			if type(cmd) == "string" and cmd:match("^%s*which%s") then return 127 end
			return real_execute(cmd)
		end
		local dir = os.tmpname()
		os.remove(dir)
		local ok, opened = pcall(writer.open_db, dir .. "/metrics.sqlite")
		os.execute = real_execute
		os.execute("rm -rf '" .. dir .. "'")
		helpers.assert_true(ok, tostring(opened))
		helpers.assert_eq(opened == true, HAS_SQLITE, "sqlite3 is found exactly when it is installed")
	end)

end)
