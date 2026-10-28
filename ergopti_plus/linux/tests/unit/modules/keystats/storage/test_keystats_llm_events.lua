--- tests/unit/modules/keystats/storage/test_keystats_llm_events.lua

--- ==============================================================================
--- MODULE: LLM Events In The Linux Metrics Database
--- DESCRIPTION:
--- The dashboard's AI tab reads events_llm (generation, suggested, dismissed,
--- accepted). Windows and macOS write it; this driver kept only per-application
--- counters, so the tab stayed empty. This replays the shared vectors
--- (_shared/tests/corpus/keystats/llm_events_vectors.json) through the real
--- writer, pins its columns to the canonical schema, and proves the keystats
--- recorder buffers the events and flushes them once.
--- ==============================================================================

package.loaded["tests.support.modules.keystats.storage.keystats_sqlite_writer_fixture"] = nil
local Fixture = require("tests.support.modules.keystats.storage.keystats_sqlite_writer_fixture")
local helpers = Fixture.helpers
local Fakes = helpers.load_module("tests.fakes")
local Json = require("json")

local function read(path)
	local handle = assert(io.open(path, "rb"), "cannot open " .. path)
	local text = handle:read("*a")
	handle:close()
	return text
end

local corpus = Json.decode_lossless(read(helpers.driver_root() .. "/../_shared/tests/corpus/keystats/llm_events_vectors.json"))

--- Splits one SQL tuple "(a,'b',NULL,3)" into Lua values (nil for NULL).
--- @param text string The text between the parentheses.
--- @return table values Array; NULL is false so the positions survive.
local function split_tuple(text)
	local values, position = {}, 1
	while position <= #text do
		local char = text:sub(position, position)
		if char == "'" then
			local value, cursor = {}, position + 1
			while true do
				local quote = text:find("'", cursor, true)
				assert(quote, "unterminated literal in " .. text)
				value[#value + 1] = text:sub(cursor, quote - 1)
				if text:sub(quote + 1, quote + 1) == "'" then
					value[#value + 1] = "'"
					cursor = quote + 2
				else
					position = quote + 1
					break
				end
			end
			values[#values + 1] = table.concat(value)
		else
			local stop = text:find(",", position, true) or (#text + 1)
			local token = text:sub(position, stop - 1)
			if token == "NULL" then
				values[#values + 1] = false
			else
				values[#values + 1] = assert(tonumber(token), "bad token " .. token)
			end
			position = stop
		end
		if text:sub(position, position) == "," then position = position + 1 end
	end
	return values
end

--- The columns of events_llm in the canonical schema.
--- @return table columns Names in declaration order.
local function schema_columns()
	local schema = read(helpers.driver_root() .. "/../_shared/data/db/schema.sql")
	local body = schema:match("CREATE TABLE IF NOT EXISTS events_llm %((.-)\n%);")
	assert(body, "events_llm is not in the schema")
	local columns = {}
	for line in body:gmatch("[^\n]+") do
		local name = line:match("^%s*([%w_]+)%s+[A-Z]")
		if name and name ~= "PRIMARY" then columns[#columns + 1] = name end
	end
	return columns
end

--- Runs the writer over one batch and returns the parsed INSERT. Only the sqlite3
--- CLI's exit receipt is simulated: the statement is the writer's own.
--- @param events table The batch.
--- @return table|nil parsed { columns = {..}, rows = { { column = value } } }, nil when refused.
local function write(events)
	local command = require("modules.keystats.sqlite_command")
	local Cipher = require("modules.keystats.text_cipher")
	local previous_build, previous_cipher = command.build, Cipher.is_enabled()
	local previous_execute, previous_popen = os.execute, io.popen
	local statement, body = nil, ""
	local path = os.tmpname()
	local seed = assert(io.open(path, "w"))
	assert(seed:write("owned native fixture") and seed:close())
	Cipher.set_enabled(false)
	command.build = function(selected, sql, options)
		if sql:find("INSERT OR IGNORE INTO events_llm", 1, true) then statement = sql end
		body = ""
		if sql:find("SELECT sql FROM sqlite_master", 1, true) then
			body = "CREATE TABLE devices(os CHECK(os IN ('linux')));\n"
		elseif sql:find("SELECT CAST(value AS INTEGER)", 1, true) then body = "1\n" end
		return previous_build(selected, sql, options)
	end
	os.execute = function() return 0 end
	io.popen = function()
		local output = body .. "\nERGOPTI_SQL_EXIT_STATUS=0\n"
		return { read = function() return output end, close = function() return true end }
	end
	local writer, result
	local ok, reason = xpcall(function()
		writer = helpers.load_module("modules.keystats.sqlite_writer")
		helpers.assert_true(writer.open_db(path))
		result = writer.insert_llm_events("owned", events)
	end, debug.traceback)
	command.build = previous_build
	os.execute, io.popen = previous_execute, previous_popen
	Cipher.set_enabled(previous_cipher)
	if writer then writer.close_db() end
	os.remove(path)
	if not ok then error(reason, 0) end
	if result == false or not statement then return nil end
	local columns_text, values_text = statement:match("INSERT OR IGNORE INTO events_llm %((.-)%) VALUES (.-);")
	assert(columns_text and values_text, "the INSERT could not be read: " .. statement)
	local columns = {}
	for name in columns_text:gmatch("[%w_]+") do columns[#columns + 1] = name end
	local rows = {}
	for tuple in values_text:gmatch("%b()") do
		local values = split_tuple(tuple:sub(2, -2))
		assert(#values == #columns, "row and column counts differ")
		local row = {}
		for index, name in ipairs(columns) do row[name] = values[index] end
		rows[#rows + 1] = row
	end
	return { columns = columns, rows = rows }
end

helpers.describe("keystats llm events: the writer replays the shared vectors", function()
	helpers.it("llm-events: the INSERT lists exactly the canonical schema columns", function()
		local parsed = write({ { app = "owned", kind = "suggested", count = 1 } })
		helpers.assert_not_nil(parsed)
		helpers.assert_eq(parsed.columns, schema_columns(),
			"a column the schema lacks fails every insert; one it has but we omit is silently NULL")
	end)

	for _, case in ipairs(corpus.cases) do
		helpers.it("llm-events: vector " .. case.id, function()
			local parsed = write({ case.event })
			helpers.assert_not_nil(parsed, "the batch must be written")
			local row = parsed.rows[1]
			for column, expected in pairs(case.row) do
				local actual = row[column]
				if Json.is_null(expected) or expected == nil then
					helpers.assert_eq(actual, false, column .. " must be NULL")
				else
					helpers.assert_eq(actual, expected, column)
				end
			end
		end)
	end

	helpers.it("llm-events: a kind the table's CHECK would drop silently is refused", function()
		for _, kind in ipairs(corpus.refused_kinds) do
			helpers.assert_nil(write({ { app = "owned", kind = kind } }), "kind '" .. kind .. "' must be refused")
		end
	end)
end)

helpers.describe("keystats llm events: the recorder buffers and flushes them once", function()
	helpers.it("llm-events: record_llm_event reaches the writer in one flush and is not replayed", function()
		local fake_writer = setmetatable({
			open_db = function() return true end,
			register_device = function() return true end,
			read_open_walk = function() return nil, true end,
			upsert_open_walk = function() return true end,
			is_available = function() return true end,
			bump_rev = function() return true end,
		}, { __index = Fakes.sqlite_writer() })
		require("tests.support.sqlite_flush_fake").attach(fake_writer)
		local writer_name, keystats_name = "modules.keystats.sqlite_writer", "modules.keystats.keystats"
		local previous_writer, previous_keystats = package.loaded[writer_name], package.loaded[keystats_name]
		package.loaded[writer_name], package.loaded[keystats_name] = fake_writer, nil
		local ok, err = pcall(function()
			local keystats = require(keystats_name)
			keystats.init({ sqlite_path = "/tmp/ergopti_keystats_llm_mock.sqlite" })
			require("tests.support.metrics_consent_fixture").enable(keystats)
			keystats.reset_session()
			keystats.record_llm_event("org.mozilla.firefox", "generation", { count = 2, prompt_tokens = 5, completion_tokens = 7, total_tokens = 12 })
			keystats.record_llm_event("org.mozilla.firefox", "suggested", { count = 2 })
			keystats.record_llm_event("org.mozilla.firefox", "accepted", { prediction = "salut", all_predictions = { "salut", "yo" }, chosen_index = 1, deletes = 2 })
			keystats.record_llm_event("org.mozilla.firefox", "dismissed", { all_predictions = { "a" } })
			keystats.record_llm_event("org.mozilla.firefox", "failed", {})
			keystats.flush()
			helpers.assert_eq(#fake_writer.llm, 4, "the four kinds are written, the fifth is refused")
			local kinds = {}
			for _, entry in ipairs(fake_writer.llm) do kinds[#kinds + 1] = entry.row.kind end
			helpers.assert_eq(kinds, { "generation", "suggested", "accepted", "dismissed" })
			helpers.assert_eq(fake_writer.llm[3].row.net_saved_chars, 3, "net saved is the typed length minus the erased characters")
			keystats.flush()
			helpers.assert_eq(#fake_writer.llm, 4, "a second flush must not replay the events")
		end)
		package.loaded[writer_name], package.loaded[keystats_name] = previous_writer, previous_keystats
		if not ok then error(err, 0) end
	end)
end)
