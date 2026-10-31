--- tests/unit/modules/keystats/storage/test_sql_literal_c_string.lua

--- ==============================================================================
--- MODULE: SQL Literal C-String Regression Tests
--- DESCRIPTION:
--- hs.sqlite3's db:exec passes SQL to sqlite3_exec as a C string
--- (luaL_checkstring in Hammerspoon's lsqlite3.c), so the statement ends at the
--- first NUL. The keystats quoted values by doubling apostrophes only: one NUL
--- in a typed text, window title or URL cut the batch inside a literal, SQLite
--- refused it, the whole ingest transaction rolled back and the same batch was
--- retried, and refused, on every tick (sql-literal-nul-2026-10-21). Values now
--- go through the shared sqlite.literal encoder, which spells NUL and CR as
--- char() expressions.
--- ==============================================================================

local helpers = require("tests.helpers")

local EVENT_TYPES = {
	"typing", "app_switch", "window_switch", "shortcut", "system_event",
	"hotstring", "hotstring_suggested", "hotstring_dismissed",
	"llm_generation", "llm_suggested", "llm_dismissed", "llm_accepted",
	"llm_generation_failed", "sys_autocorrect",
	"session_start", "session_end", "idle_start", "idle_end",
}

local SENTINEL = "a\0b'c\rd\0"

local STRING_FIELDS = {
	"app", "title", "url", "text", "context", "deleted_text", "document_path", "field_role",
	"key", "layout", "next_app", "next_title", "prediction", "prev_app", "prev_title",
	"replacement", "rich_text", "trigger", "action",
}

--- Evaluates a SQLite value expression made of quoted literals and char(N)
--- terms joined by ||, as SQLite would. Returns nil for any other expression.
--- @param expression string
--- @return string|nil
local function evaluate_literal(expression)
	local out, index = {}, 1
	while index <= #expression do
		if expression:sub(index, index) == "'" then
			local value, cursor = {}, index + 1
			while true do
				local char = expression:sub(cursor, cursor)
				if char == "" then return nil end
				if char == "'" then
					if expression:sub(cursor + 1, cursor + 1) ~= "'" then break end
					cursor = cursor + 1
				end
				value[#value + 1] = char
				cursor = cursor + 1
			end
			out[#out + 1] = table.concat(value)
			index = cursor + 1
		else
			local code, rest = expression:match("^char%((%d+)%)()", index)
			if not code then return nil end
			out[#out + 1] = string.char(tonumber(code))
			index = rest
		end
		if index <= #expression then
			if expression:sub(index, index + 1) ~= "||" then return nil end
			index = index + 2
		end
	end
	return table.concat(out)
end

--- Splits a VALUES(...) payload on top-level commas, respecting quotes.
--- @param values string
--- @return table
local function split_values(values)
	local out, depth, current, in_string = {}, 0, {}, false
	for index = 1, #values do
		local char = values:sub(index, index)
		if char == "'" then in_string = not in_string end
		if not in_string and char == "(" then depth = depth + 1 end
		if not in_string and char == ")" then depth = depth - 1 end
		if not in_string and depth == 0 and char == "," then
			out[#out + 1] = table.concat(current):match("^%s*(.-)%s*$")
			current = {}
		else
			current[#current + 1] = char
		end
	end
	out[#out + 1] = table.concat(current):match("^%s*(.-)%s*$")
	return out
end


helpers.describe("keystats SQL literals survive the sqlite3_exec C string (sql-literal-nul-2026-10-21)", function()
	helpers.it("builds NUL-free statements whose literals keep every byte", function()
		local Writer = helpers.load_with_stubs("modules.keystats.sqlite_writer")
		Writer.init({
			paths = { db = "/tmp/ergopti_test.db" },
			device_obj = { id = "test-device" },
			device_id = "00000000-0000-4000-8000-000000000001",
		})
		local preserved = 0
		for _, event_type in ipairs(EVENT_TYPES) do
			local event = { type = event_type, timestamp = "2026-10-21 12:34:56.000" }
			for _, field in ipairs(STRING_FIELDS) do event[field] = SENTINEL end
			for _, sql in ipairs(Writer.build_inserts(event) or {}) do
				helpers.assert_true(sql:find("\0", 1, true) == nil,
					"sqlite3_exec would cut the " .. event_type .. " statement at its NUL")
				local values = sql:match("VALUES%s*%((.*)%);")
				helpers.assert_true(values ~= nil, "unparsed statement: " .. sql)
				for _, expression in ipairs(split_values(values)) do
					if evaluate_literal(expression) == SENTINEL then preserved = preserved + 1 end
				end
			end
		end
		helpers.assert_true(preserved >= #EVENT_TYPES,
			"each event's text fields must decode to the exact original bytes, got " .. preserved)
	end)

	helpers.it("encodes aggregate, outbox and reader literals the same way", function()
		local Literal = require("sqlite.literal")
		local escaped = "'" .. Literal.escape(SENTINEL) .. "'"
		helpers.assert_eq(evaluate_literal(escaped), SENTINEL)
		-- The whole keystats tree, not a list of helper names: a named list went
		-- stale when a helper was renamed, and never covered the foreign-device
		-- watermark queries of export.lua that still doubled apostrophes only.
		local root = helpers.driver_root()
		local pipe = assert(io.popen("cd '" .. root .. "' && find modules/keystats -name '*.lua' -type f"))
		local offenders, scanned = {}, 0
		for relative in pipe:lines() do
			local file = assert(io.open(root .. relative, "rb"))
			local source = file:read("*a")
			file:close()
			scanned = scanned + 1
			for line in source:gmatch("[^\n]+") do
				if not line:match("^%s*%-%-") and line:find('gsub("\'", "\'\'")', 1, true) then
					offenders[#offenders + 1] = relative .. ": " .. line:gsub("^%s+", "")
				end
			end
		end
		pipe:close()
		helpers.assert_true(scanned >= 20, "the scan must reach the keystats tree, saw " .. scanned)
		helpers.assert_eq(#offenders, 0, "quote SQL text through sqlite.literal:\n" .. table.concat(offenders, "\n"))
	end)
end)
