--- tests/unit/modules/keylogger/test_build_inserts_never_nulls_not_null.lua

--- ==============================================================================
--- MODULE: Regression — build_inserts must never emit NULL for a NOT NULL column
--- DESCRIPTION:
--- Silent data loss. _builders.typing passed is_fullscreen and in_meeting through
--- _sql_num() with no fallback:
---   _sql_num(e.is_fullscreen), _sql_num(e.in_meeting),
--- _sql_num(nil) returns the literal string "NULL", both columns are declared
--- INTEGER NOT NULL in _shared/data/db/schema.sql, and the statement is
--- INSERT OR IGNORE — so the constraint violation did NOT raise. SQLite quietly
--- skipped the row and the ENTIRE typing event (text, per-keystroke events_json,
--- wpm, timings) was discarded with nothing logged anywhere.
---
--- The trigger is real, not theoretical: context_tracker assigned
--- `_state.is_fullscreen = win:isFullScreen()`, and hs.window:isFullScreen()
--- returns nil for any window that does not expose the attribute. The three
--- sibling columns on the very next lines (mouse_clicks, mouse_scrolls,
--- mouse_distance_px) always carried `or 0` for precisely this reason — these two
--- were the forgotten siblings inside the same statement.
---
--- WHY THIS TEST IS CLASS-WIDE:
--- Pinning the two fixed columns would leave every other NOT NULL column, and
--- every column added later, unguarded — the documented failure mode of this repo
--- (project-ahk-guard-tests-must-loop-the-class). Instead this test PARSES the real
--- schema.sql for the NOT NULL columns of every table, drives EVERY event type
--- through the real M.build_inserts with all optional fields absent, and asserts no
--- NOT NULL column ever receives the literal NULL. A new builder, a new event type
--- or a new NOT NULL column is covered automatically.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Every event type build_inserts dispatches on, driven with a bare entry so all
-- optional fields are nil — the exact shape that produced the silent drop.
local EVENT_TYPES = {
	"typing", "app_switch", "window_switch", "shortcut", "system_event",
	"hotstring", "hotstring_suggested", "hotstring_dismissed",
	"llm_generation", "llm_suggested", "llm_dismissed", "llm_accepted",
	"llm_generation_failed", "sys_autocorrect",
	"session_start", "session_end", "idle_start", "idle_end",
}

-- Timestamp shape the builders slice for the denormalised `date` column.
local TIMESTAMP = "2026-07-21 12:34:56.000"





-- ==========================================
-- ==========================================
-- ======= 1/ Schema NOT NULL Parsing =======
-- ==========================================
-- ==========================================

--- Parses schema.sql into { [table_name] = { [column_name] = true } } for the
--- columns declared NOT NULL. Reading the real schema rather than restating it
--- keeps this guard honest when the schema changes.
--- @return table not_null Map of table -> set of NOT NULL column names.
local function parse_not_null_columns()
	local driver_root = helpers.driver_root()
	local shared_root = driver_root:gsub("[/\\]macos[/\\]?$", "") .. "/_shared"
	local path        = shared_root .. "/data/db/schema.sql"

	local fh = io.open(path, "r")
	helpers.assert_true(fh ~= nil, "schema.sql must be readable at " .. path)
	if not fh then return {} end
	local src = fh:read("*a")
	fh:close()

	local out = {}
	for table_name, body in src:gmatch("CREATE TABLE IF NOT EXISTS%s+([%w_]+)%s*%((.-)%);") do
		local cols = {}
		for line in body:gmatch("[^\n]+") do
			-- Strip trailing SQL comments so a "-- NOT NULL" note never counts.
			local clean = line:gsub("%-%-.*$", "")
			local name  = clean:match("^%s*([%w_]+)")
			if name and clean:upper():find("NOT NULL", 1, true) then
				cols[name] = true
			end
		end
		out[table_name] = cols
	end
	return out
end

--- Splits a VALUES(...) payload on top-level commas, respecting quotes.
--- @param values string The contents between VALUES( and the closing paren.
--- @return table list Ordered value expressions.
local function split_values(values)
	local out, depth, cur, in_str = {}, 0, "", false
	local i = 1
	while i <= #values do
		local c = values:sub(i, i)
		if in_str then
			if c == "'" then
				-- '' is an escaped quote inside a SQL string literal.
				if values:sub(i + 1, i + 1) == "'" then cur = cur .. "''" ; i = i + 1
				else in_str = false end
			end
			cur = cur .. c
		elseif c == "'" then
			in_str = true
			cur = cur .. c
		elseif c == "(" then
			depth = depth + 1 ; cur = cur .. c
		elseif c == ")" then
			depth = depth - 1 ; cur = cur .. c
		elseif c == "," and depth == 0 then
			out[#out + 1] = cur ; cur = ""
		else
			cur = cur .. c
		end
		i = i + 1
	end
	if cur ~= "" then out[#out + 1] = cur end
	for k, v in ipairs(out) do out[k] = v:gsub("^%s+", ""):gsub("%s+$", "") end
	return out
end





-- ==========================================
-- ==========================================
-- ======= 2/ No NULL Where Forbidden =======
-- ==========================================
-- ==========================================

helpers.describe("build_inserts never emits NULL for a NOT NULL column", function()
	helpers.it("every event type produces a statement with no NULL in a NOT NULL column", function()
		local NOT_NULL = parse_not_null_columns()
		helpers.assert_true(next(NOT_NULL) ~= nil,
			"the schema parse must find at least one table — an empty map would make this guard vacuous")

		local Writer = helpers.load_with_stubs("modules.keylogger.sqlite_writer")
		Writer.init({
			paths      = { db = "/tmp/ergopti_test.db" },
			device_obj = { id = "test-device" },
			device_id  = "00000000-0000-4000-8000-000000000001",
		})

		local violations = {}

		for _, event_type in ipairs(EVENT_TYPES) do
			-- Deliberately bare: only the discriminator and the timestamp every
			-- builder slices. Every other field is absent, which is exactly the
			-- state hs.window:isFullScreen() returning nil produced in the field.
			local statements = Writer.build_inserts({ type = event_type, timestamp = TIMESTAMP })

			helpers.assert_true(type(statements) == "table" and #statements > 0,
				"build_inserts must produce a statement for event type '" .. event_type .. "'")

			for _, sql in ipairs(statements or {}) do
				local table_name, col_list, value_list =
					sql:match("INSERT OR IGNORE INTO%s+([%w_]+)%s*%((.-)%)%s*VALUES%s*%((.*)%);")

				helpers.assert_true(table_name ~= nil,
					"could not parse the statement for '" .. event_type .. "': " .. tostring(sql))

				if table_name then
					local cols = {}
					for c in col_list:gmatch("[%w_]+") do cols[#cols + 1] = c end
					local vals = split_values(value_list)

					local required = NOT_NULL[table_name] or {}
					for idx, col in ipairs(cols) do
						if required[col] and vals[idx] == "NULL" then
							violations[#violations + 1] = string.format(
								"%s.%s (event type '%s')", table_name, col, event_type)
						end
					end
				end
			end
		end

		helpers.assert_true(#violations == 0, string.format(
			"%d NOT NULL column(s) received a literal NULL. INSERT OR IGNORE swallows the "
			.. "constraint violation, so the WHOLE row is silently discarded with nothing logged: %s",
			#violations, table.concat(violations, ", ")))
	end)
end)
