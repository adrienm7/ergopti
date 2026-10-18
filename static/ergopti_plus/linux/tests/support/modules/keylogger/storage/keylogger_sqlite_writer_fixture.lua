--- tests/support/modules/keylogger/storage/keylogger_sqlite_writer_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_keylogger_sqlite_writer
--- DESCRIPTION:
--- Prelude shared by the test_keylogger_sqlite_writer_* test files: their modules, stubs and
--- helpers. Each part loads it fresh, so no state leaks from one file to the
--- next.
--- ==============================================================================

local helpers = require("tests.helpers")

local it = require("tests.support.metrics_preferences_fixture").it

local sw     = helpers.load_module("modules.keylogger.sqlite_writer")

--- Recognizes the mandatory additive initializer separately from target faults.
--- A real CLI first-open control below checks that this DDL actually commits.
local function is_media_schema_startup(command)
	return command:find("CREATE TABLE IF NOT EXISTS ngram_media_keys", 1, true)
		and command:find("CREATE TABLE IF NOT EXISTS agg_app_day_media_hold", 1, true)
		and command:find("COMMIT;", 1, true)
end

--- Models native stdout and LuaJIT's ambiguous pclose without replacing the
--- production builder or query logic. lines()/read() both mirror the real ABI.
local function with_writer_read_receipts(body, status, test, startup_status)
	local writer = helpers.load_module("modules.keylogger.sqlite_writer")
	local previous_execute, previous_popen = os.execute, io.popen
	local path = os.tmpname()
	local file = assert(io.open(path, "w"))
	assert(file:write("existing native database fixture") and file:close())
	os.execute = function() return 0 end
	io.popen = function(command)
		local content, code
		if command:find("SELECT sql FROM sqlite_master", 1, true) then
			content, code = "CREATE TABLE devices (os CHECK (os IN ('linux')))\n", 0
		elseif is_media_schema_startup(command) then
			content, code = "", startup_status or 0
		else
			content, code = type(body) == "function" and body(command) or body, status
		end
		return {
			read = function(_, mode)
				if mode == "*l" then return content:match("^([^\n]*)") end
				if command:find("ERGOPTI_SQL_EXIT_STATUS=", 1, true) and code ~= "missing" then
					return content .. "\nERGOPTI_SQL_EXIT_STATUS=" .. code .. "\n"
				end
				return content
			end,
			lines = function()
				if content == "" then return function() return nil end end
				local framed = content:sub(-1) == "\n" and content or (content .. "\n")
				return framed:gmatch("([^\n]*)\n")
			end,
			close = function() return true end,
		}
	end
	local ok, err = xpcall(function()
		helpers.assert_true(writer.open_db(path))
		test(writer)
	end, debug.traceback)
	os.execute, io.popen = previous_execute, previous_popen
	writer.close_db()
	os.remove(path)
	if not ok then error(err, 0) end
end

--- Models CLI exit receipts while retaining the production builder and writer.
local function with_category_commands(refusal, test, retain_startup)
	local writer = helpers.load_module("modules.keylogger.sqlite_writer")
	local previous_execute, previous_popen = os.execute, io.popen
	local path = os.tmpname()
	local file = assert(io.open(path, "w"))
	assert(file:write("existing native database fixture") and file:close())
	local commands = {}
	os.execute = function() return 0 end
	io.popen = function(command)
		local content, status = "", 0
		if command:find("SELECT sql FROM sqlite_master", 1, true) then
			content = "CREATE TABLE devices (os CHECK (os IN ('linux')))\n"
		else
			commands[#commands + 1] = command
			if refusal == "score" and command:find("INSERT OR REPLACE INTO meta", 1, true) then status = 7 end
			if refusal == "category" and command:find("UPDATE agg_app_day", 1, true) then status = 7 end
		end
		return {
			read = function() return content .. "\nERGOPTI_SQL_EXIT_STATUS=" .. status .. "\n" end,
			close = function() return true end,
		}
	end
	local ok, reason = xpcall(function()
		helpers.assert_true(writer.open_db(path))
		-- Startup has its own acknowledged schema migration; these observations
		-- belong only to the category operation whose transaction is under test.
		if not retain_startup then
			for index = #commands, 1, -1 do commands[index] = nil end
		end
		test(writer, commands)
	end, debug.traceback)
	os.execute, io.popen = previous_execute, previous_popen
	writer.close_db()
	os.remove(path)
	if not ok then error(reason, 0) end
end

--- Captures actual Writer SQL while simulating only the CLI exit receipt.
local function with_ngram_sql(test)
	local command = require("modules.keylogger.sqlite_command")
	local previous_build, statements = command.build, {}
	command.build = function(path, sql, options)
		if sql:find("INSERT INTO ngram_", 1, true) then statements[#statements + 1] = sql end
		return previous_build(path, sql, options)
	end
	local ok, reason = xpcall(function()
		with_category_commands(nil, function(writer) test(writer, statements) end)
	end, debug.traceback)
	command.build = previous_build
	if not ok then error(reason, 0) end
end

--- Models the native CLI's two scalar representations without replacing the
--- production builder, checked receipt parser or shared JSON decoder.
local function with_meta_value_output(value, status, test)
	local writer = helpers.load_module("modules.keylogger.sqlite_writer")
	local previous_execute, previous_popen = os.execute, io.popen
	local path = os.tmpname()
	local file = assert(io.open(path, "w"))
	assert(file:write("existing native database fixture") and file:close())
	os.execute = function() return 0 end
	io.popen = function(command)
		local content, code = "", status
		if command:find("SELECT sql FROM sqlite_master", 1, true) then
			content, code = "CREATE TABLE devices (os CHECK (os IN ('linux')))\n", 0
		elseif is_media_schema_startup(command) then
			content, code = "", 0
		elseif command:find("SELECT json_quote(value)", 1, true) then
			content = value == nil and "" or require("json").encode(value) .. "\n"
		elseif command:find("SELECT value FROM meta", 1, true) then
			-- sqlite3's raw TEXT printer stops at NUL; scalar Lua framing stops at LF.
			content = value == nil and "" or (value:match("^[^%z]*") .. "\n")
		else
			error("metadata test received an unexpected query")
		end
		return {
			read = function() return content .. "\nERGOPTI_SQL_EXIT_STATUS=" .. code .. "\n" end,
			close = function() return true end,
		}
	end
	local ok, reason = xpcall(function()
		helpers.assert_true(writer.open_db(path))
		test(writer)
	end, debug.traceback)
	os.execute, io.popen = previous_execute, previous_popen
	writer.close_db()
	os.remove(path)
	if not ok then error(reason, 0) end
end

--- Captures the production histogram statement while modeling only CLI receipts.
--- The shared decoder independently checks the key bytes supplied to SQLite.
local function with_burst_histogram_statement(row, test)
	local command = require("modules.keylogger.sqlite_command")
	local previous_build = command.build
	local statement
	command.build = function(path, sql, options)
		if sql:find("INSERT INTO agg_app_day_burst", 1, true) then statement = sql end
		return previous_build(path, sql, options)
	end
	local ok, reason = xpcall(function()
		with_writer_read_receipts("", 0, function(writer)
			helpers.assert_true(writer.upsert_burst("owned-device", row))
			helpers.assert_eq(type(statement), "string")
			local encoded = statement:match("VALUES %('owned%-device','2000%-01%-01','owned%-app',0,0%.000000,0,'(.-)',0,0,0%)")
			helpers.assert_eq(type(encoded), "string", "existing counter defaults remain zero")
			local decoded = require("json").decode((encoded:gsub("''", "'")))
			helpers.assert_eq(type(decoded), "table", "SQLite receives a JSON object")
			test(decoded)
		end)
	end, debug.traceback)
	command.build = previous_build
	if not ok then error(reason, 0) end
end

-- Date formatting and writer receipts below are declared unit doubles; the
-- separate native fixture uses real libc and SQLite for the same public APIs.
local function with_local_day_clock(body)
	local previous_date = os.date
	os.date = function(format, epoch)
		if format == "%Y-%m-%d" then return "2026-01-02" end
		if format == "!%Y-%m-%d" then return "2026-01-01" end
		if format == "!%Y-%m-%d %H:%M:%S" then return "2026-01-01 23:59:59" end
		return previous_date(format, epoch)
	end
	local ok, err = xpcall(body, debug.traceback)
	os.date = previous_date
	if not ok then error(err, 0) end
end

return {
	helpers = helpers,
	it = it,
	sw = sw,
	is_media_schema_startup = is_media_schema_startup,
	with_writer_read_receipts = with_writer_read_receipts,
	with_category_commands = with_category_commands,
	with_ngram_sql = with_ngram_sql,
	with_meta_value_output = with_meta_value_output,
	with_burst_histogram_statement = with_burst_histogram_statement,
	with_local_day_clock = with_local_day_clock,
}
