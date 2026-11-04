--- tests/unit/modules/keystats/storage/test_keystats_sqlite_writer_token_encoding.lua

--- ==============================================================================
--- MODULE: N-gram Key Migration Of The Linux Store
--- DESCRIPTION:
--- Linux keeps its derived keys in the database alone, so token encoding 2 is
--- written into them once. These cases run the real writer over a modelled CLI:
--- the backup comes before the one transaction, a store already moved is left
--- alone, and a refused backup changes nothing.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs the migration against modelled store answers.
--- @param answers table { version, keys = table name -> hex rows, refuse = pattern }
--- @return boolean result
--- @return table commands Every CLI script, in order.
local function migrate(answers)
	local writer = helpers.load_module("modules.keystats.sqlite_writer")
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
		elseif command:find("key='ngram_token_encoding'", 1, true) then
			content = answers.version and (answers.version .. "\n") or ""
		else
			local family = command:match("SELECT DISTINCT hex%(token%) FROM ([%w_]+)")
			if family then content = (answers.keys or {})[family] or "" end
			commands[#commands + 1] = command
			if answers.refuse and command:find(answers.refuse, 1, true) then status = 7 end
		end
		return {
			read = function() return content .. "\nERGOPTI_SQL_EXIT_STATUS=" .. status .. "\n" end,
			lines = function() return content:gmatch("([^\n]*)\n") end,
			close = function() return true end,
		}
	end
	local ok, result = xpcall(function()
		helpers.assert_true(writer.open_db(path))
		commands = {}
		return writer.ensure_token_encoding()
	end, debug.traceback)
	os.execute, io.popen = previous_execute, previous_popen
	writer.close_db()
	os.remove(path)
	if not ok then error(result, 0) end
	return result, commands
end

local function position(commands, needle)
	for index, command in ipairs(commands) do
		if command:find(needle, 1, true) then return index end
	end
	return nil
end

helpers.describe("keystats sqlite writer: n-gram token encoding", function()
	helpers.it("token-encoding: the backup precedes the one rewriting transaction", function()
		local result, commands = migrate({ keys = { ngram_chars = "5B\n" } })
		helpers.assert_true(result)
		local backup = position(commands, "VACUUM INTO")
		local update = position(commands, "UPDATE OR ROLLBACK ngram_chars SET token=CAST(X'5B5B' AS TEXT)")
		helpers.assert_true(backup ~= nil and update ~= nil and backup < update)
		helpers.assert_true(commands[update]:find("BEGIN IMMEDIATE;", 1, true) ~= nil)
		helpers.assert_true(commands[update]:find("'ngram_token_encoding','2'", 1, true) ~= nil,
			"the version is recorded by the same transaction")
	end)

	helpers.it("token-encoding: a store with nothing to rewrite only records the version", function()
		local result, commands = migrate({})
		helpers.assert_true(result)
		helpers.assert_nil(position(commands, "VACUUM INTO"))
		helpers.assert_true(position(commands, "'ngram_token_encoding','2'") ~= nil)
	end)

	helpers.it("token-encoding: a store already moved is left alone", function()
		local result, commands = migrate({ version = "2" })
		helpers.assert_true(result)
		helpers.assert_eq(#commands, 0, "keys already escaped are never escaped twice")
	end)

	helpers.it("token-encoding: a refused backup rewrites nothing", function()
		local result, commands = migrate({ keys = { ngram_chars = "5B\n" }, refuse = "VACUUM INTO" })
		helpers.assert_eq(result, false)
		helpers.assert_nil(position(commands, "UPDATE OR ROLLBACK"))
	end)
end)
