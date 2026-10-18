--- tests/support/modules/keylogger/storage/sqlite_reader_projection_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_sqlite_reader_projection
--- DESCRIPTION:
--- Prelude shared by the test_sqlite_reader_projection_* test files: their modules, stubs and
--- helpers. Each part loads it fresh, so no state leaks from one file to the
--- next.
--- ==============================================================================

local helpers = require("tests.helpers")

local NativeCommand = require("modules.keylogger.sqlite_command")

local Json = require("json")

-- Every table the schema declares for character sequences, and the code the
-- dashboard envelope uses for each.
local EXPECTED = {
	{ code = "c", table_name = "ngram_chars" },
	{ code = "bg", table_name = "ngram_bigrams" },
	{ code = "tg", table_name = "ngram_trigrams" },
	{ code = "qg", table_name = "ngram_quadgrams" },
	{ code = "pg", table_name = "ngram_pentagrams" },
	{ code = "hx", table_name = "ngram_hexagrams" },
	{ code = "hp", table_name = "ngram_heptagrams" },
	{ code = "w", table_name = "ngram_words" },
	{ code = "w_bg", table_name = "ngram_word_bigrams" },
}

--- Runs the reader with both ends of its sqlite3 shell-out replaced.
---
--- @param responder function Given the SQL, returns the JSON body sqlite3 would
---        have printed (or "" for no rows).
--- @param body function Receives the freshly loaded reader module.
--- @return table Every SQL statement the reader issued, in order.
local function with_stubbed_sqlite(responder, body)
	local command_name = "modules.keylogger.sqlite_command"
	local reader_name = "modules.keylogger.sqlite_reader"
	local previous_command = package.loaded[command_name]
	local previous_reader = package.loaded[reader_name]
	local previous_popen = io.popen

	local statements, commands = {}, {}
	local next_body = ""

	package.loaded[command_name] = {
		build = function(_path, sql, opts)
			statements[#statements + 1] = sql
			local response = responder(sql) or ""
			local body = type(response) == "table" and response.body or response
			local status = type(response) == "table" and response.status or 0
			next_body = body
			if opts and opts.capture_exit then
				next_body = body .. "\nERGOPTI_SQL_EXIT_STATUS=" .. status .. "\n"
			end
			-- Preserve the real builder/parser ABI; only the CLI response is fake.
			local command, reason = NativeCommand.build(_path, sql, opts)
			commands[#commands + 1] = command
			return command, reason
		end,
		read_exit_receipt = NativeCommand.read_exit_receipt,
		sanitise_error = NativeCommand.sanitise_error,
		escape_literal = NativeCommand.escape_literal,
	}
	io.popen = function()
		local sent = next_body
		return {
			read = function() return sent end,
			close = function() return true end,
		}
	end

	package.loaded[reader_name] = nil
	local ok, err = pcall(function()
		body(require(reader_name))
	end)

	io.popen = previous_popen
	package.loaded[command_name] = previous_command
	package.loaded[reader_name] = previous_reader
	helpers.assert_true(ok, "the projection must complete: " .. tostring(err))
	return statements, commands
end

--- Whether any statement selects from the given table.
--- @param statements table
--- @param table_name string
--- @return boolean
local function queried(statements, table_name)
	for _, sql in ipairs(statements) do
		-- Anchored on the word boundary so ngram_chars does not answer for
		-- ngram_chars_class, and ngram_words does not answer for
		-- ngram_word_bigrams.
		if sql:find("FROM " .. table_name .. "[^%w_]") or sql:find("FROM " .. table_name .. "$") then
			return true
		end
	end
	return false
end

return {
	helpers = helpers,
	NativeCommand = NativeCommand,
	Json = Json,
	EXPECTED = EXPECTED,
	with_stubbed_sqlite = with_stubbed_sqlite,
	queried = queried,
}
