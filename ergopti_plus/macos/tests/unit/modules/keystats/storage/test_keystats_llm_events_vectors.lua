--- tests/unit/modules/keystats/storage/test_keystats_llm_events_vectors.lua

--- ==============================================================================
--- MODULE: LLM Events Corpus Through The macOS Writer
--- DESCRIPTION:
--- The dashboard's AI tab reads events_llm the same way on every device, so the
--- row an event becomes is shared data
--- (_shared/tests/corpus/keystats/llm_events_vectors.json). Windows and Linux
--- replay it through their writers; this replays it through the real macOS
--- build_inserts and compares every column the vector names, NULL included (the
--- dashboard tells a missing token count from a zero).
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")

local handle = assert(io.open(helpers.shared("tests/corpus/keystats/llm_events_vectors.json"), "rb"))
local raw = handle:read("*a")
handle:close()
-- The plain decoder feeds the writer the events; the lossless one keeps the
-- rows' explicit nulls, which the plain one would drop (and with them every
-- NULL column this replay must check).
local corpus = assert(Json.decode(raw), "the LLM event vectors must decode")
local exact = assert(Json.decode_lossless(raw), "the LLM event vectors must decode losslessly")

--- Splits a VALUES(...) payload on top-level commas, respecting quotes.
--- @param values string The contents between VALUES( and the closing paren.
--- @return table list Ordered value expressions.
local function split_values(values)
	local out, current, in_string, index = {}, {}, false, 1
	while index <= #values do
		local char = values:sub(index, index)
		if in_string then
			current[#current + 1] = char
			if char == "'" then
				if values:sub(index + 1, index + 1) == "'" then
					current[#current + 1] = "'"
					index = index + 1
				else
					in_string = false
				end
			end
		elseif char == "'" then
			in_string = true
			current[#current + 1] = char
		elseif char == "," then
			out[#out + 1] = table.concat(current):match("^%s*(.-)%s*$")
			current = {}
		else
			current[#current + 1] = char
		end
		index = index + 1
	end
	out[#out + 1] = table.concat(current):match("^%s*(.-)%s*$")
	return out
end

--- Renders a vector's expected column value as the SQL literal of the INSERT.
--- @param value any A lossless JSON value of the vector's row.
--- @return string literal
local function sql_literal(value)
	if Json.is_null(value) then return "NULL" end
	if type(value) == "number" then
		return value == math.floor(value) and string.format("%d", value) or tostring(value)
	end
	return "'" .. tostring(value):gsub("'", "''") .. "'"
end

helpers.describe("LLM events corpus (macOS writer)", function()
	helpers.it("llm-events-vectors: every shared event becomes its shared events_llm row", function()
		helpers.assert_true(#corpus.cases >= 5, "the LLM event vectors must not be empty")
		local Writer = helpers.load_with_stubs("modules.keystats.sqlite_writer")
		Writer.init({
			paths = { db = "/tmp/ergopti_test.db" },
			device_obj = { id = "test-device" },
			device_id = "00000000-0000-4000-8000-000000000001",
		})
		for position, case in ipairs(corpus.cases) do
			local entry = { timestamp = "2026-11-06 10:00:00.000" }
			for key, value in pairs(case.event) do
				if key ~= "kind" then entry[key] = value end
			end
			entry.type = "llm_" .. case.event.kind
			local statements = Writer.build_inserts(entry)
			helpers.assert_eq(#statements, 1, case.id .. ": one statement per event")
			local table_name, columns, values =
				statements[1]:match("INSERT OR IGNORE INTO%s+([%w_]+)%s*%((.-)%)%s*VALUES%s*%((.*)%);")
			helpers.assert_eq(table_name, "events_llm", case.id .. ": the AI tab's table")
			local row, names = {}, {}
			for name in columns:gmatch("[%w_]+") do names[#names + 1] = name end
			local literals = split_values(values)
			helpers.assert_eq(#literals, #names, case.id .. ": one value per column")
			for index, name in ipairs(names) do row[name] = literals[index] end
			local checked, nulls = 0, 0
			for column, expected in pairs(exact.cases[position].row) do
				helpers.assert_true(row[column] ~= nil, case.id .. ": the writer must set " .. column)
				helpers.assert_eq(row[column], sql_literal(expected), case.id .. " " .. column)
				checked = checked + 1
				if Json.is_null(expected) then nulls = nulls + 1 end
			end
			helpers.assert_true(checked >= 15 and nulls > 0, case.id .. ": every shared column, NULL ones included")
		end
	end)
end)
