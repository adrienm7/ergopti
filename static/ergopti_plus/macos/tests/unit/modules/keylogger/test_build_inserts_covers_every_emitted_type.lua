--- tests/unit/modules/keylogger/test_build_inserts_covers_every_emitted_type.lua

--- ==============================================================================
--- MODULE: Regression — every emitted event type has a build_inserts builder (G2)
--- DESCRIPTION:
--- sqlite_writer.M.build_inserts dispatched on 16 event types and fell through to
--- `return {}` for anything else. modules/keylogger/init.lua nevertheless emits
--- `llm_generation_failed` (and context_tracker emits `sys_autocorrect`), so those
--- entries were written to today.log and then dropped at ingest.
---
--- They did NOT "re-appear on the next ingest" as the old trailing comment
--- claimed: ingest_once advances the today.log cursor past every consumed line
--- whatever build_inserts returns, and Rotation.rollover deletes today.log at the
--- next day boundary. The event was lost forever — silently breaking the very
--- guarantee log_llm_failed's docstring promises ("without this event a tail of
--- the log shows only successes, and 'are predictions silently dropping?'
--- becomes impossible to answer").
---
--- WHY THIS TEST IS SELF-MAINTAINING:
--- A hardcoded list of type strings would go false-green the day a new producer
--- is added. Instead it REFLECTS over the public log_* surface of
--- modules/keylogger/init.lua, drives each producer through the real log manager,
--- captures whatever types actually reach the log, and demands a builder for
--- every one. A new producer with no builder fails automatically; a new producer
--- with no coverage entry here fails too (section 2).
---
--- Section 4 additionally pins the trap that makes the obvious fix wrong: routing
--- llm_generation_failed into events_llm with kind='generation_failed' passes a
--- naive "non-empty array" check while SQLite's CHECK constraint makes
--- INSERT OR IGNORE drop the row — the same data loss, just harder to see.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ========================================
-- ========================================
-- ======= 1/ Producer-side Harness =======
-- ========================================
-- ========================================

--- Timings stub so the harness never depends on the real constants.toml.
local _TIMINGS_MS = { keylogger = { max_keystroke_delay_ms = 5000 } }

--- Arguments used to drive each public producer. A new `M.log_*` function with no
--- entry here fails section 2 — that is what keeps this suite honest over time.
local PRODUCER_ARGS = {
	log_hotstring           = { "btw", "by the way", "personal" },
	log_llm                 = { "some context", { { to_type = "prediction" } }, "TestApp", { backend = "ollama" } },
	log_llm_failed          = { "some context", "TestApp", { backend = "ollama", failure_reason = "timeout" } },
	log_shortcut            = { "Cmd+C", "TestApp" },
	log_hotstring_suggested = { "TestApp", "btw", "by the way", "personal" },
	log_hotstring_dismissed = { "TestApp", "btw", "by the way", "personal" },
	log_llm_suggested       = { "TestApp", 2 },
	log_llm_dismissed       = { "TestApp", { "a", "b" } },
	log_llm_accepted        = { "prediction", "TestApp", { "a", "b" }, 1, 3, "pre" },
}

--- Loads the real keylogger engine with only its I/O edges stubbed, so every
--- producer travels the true log_manager path and the captured type is exactly
--- what production would write to today.log.
--- @return table module, table captured_entries
local function load_real_keylogger()
	local captured_entries = {}

	package.loaded["modules.keylogger.rotation"] = {
		init             = function() end,
		is_initialized   = function() return true end,
		append_log       = function(e) table.insert(captured_entries, e) end,
		read_new_entries = function() return {}, 0 end,
		get_offset       = function() return 0 end,
		get_date         = function() return os.date("%Y-%m-%d") end,
		set_offset       = function() end,
		rollover         = function() end,
	}
	package.loaded["modules.keylogger.sqlite_writer"] = {
		init                  = function() end,
		open_db               = function() return true end,
		close_db              = function() end,
		get_db                = function() return nil end,
		build_inserts         = function() return {} end,
		get_next_event_id     = function() return 0 end,
		set_next_event_id     = function() end,
		persist_next_event_id = function() end,
	}
	package.loaded["modules.keylogger.aggregator"] = {
		init = function() end, walk_typing = function() end, walk_app_switch = function() end,
		walk_window_switch = function() end, walk_system_event = function() end, flush = function() end,
		get_ngram_ctx = function() return {} end, set_ngram_ctx = function() end,
		reset_ngram_ctx = function() end,
	}
	package.loaded["modules.keylogger.export"] = {
		init = function() end, get_native_app_category = function() return "other" end,
		get_device_short_id = function() return "abcd" end,
		get_sqlite_path = function() return "/tmp/test.sqlite" end,
		get_db_rev = function() return 0 end, sync_foreign_data_sql = function() end,
	}
	package.loaded["infra.i18n"] = { t = function(k) return k end, get = function(k) return k end }
	package.loaded["infra.timings"] = {
		ms  = function(section, key) return (_TIMINGS_MS[section] or {})[key] or 1000 end,
		sec = function() return 1.0 end,
	}
	package.loaded["modules.keylogger.context_tracker"] = {
		init = function() end, update_private_status = function() end,
		app_watcher_cb = function() end, update_ax_observer = function() end,
	}
	package.loaded["adapters.keyboard_hook"] = {
		start = function() end, stop = function() end, isRunning = function() return true end,
	}

	package.loaded["modules.keylogger.log_manager"] = nil
	package.loaded["modules.keylogger.kc_bridge"]   = nil
	package.loaded["modules.keylogger.watchers"]    = nil

	local KL = helpers.load_with_stubs("modules.keylogger.init", {
		eventtap = {
			new = function() return { start = function() end, stop = function() end, isEnabled = function() return true end } end,
			event = { types = { keyDown = 10, keyUp = 11, flagsChanged = 12, leftMouseDown = 1, rightMouseDown = 2, scrollWheel = 3 } },
			checkKeyboardModifiers = function() return {} end,
		},
		application = {
			watcher = { new = function() return { start = function() end, stop = function() end } end, activated = 1 },
			frontmostApplication = function()
				return {
					title = function() return "TestApp" end, mainWindow = function() return nil end,
					pid = function() return 123 end, bundleID = function() return "com.example.TestApp" end,
				}
			end,
		},
		caffeinate = { watcher = { new = function() return { start = function() end, stop = function() end } end } },
		timer = {
			doAfter = function(_d, fn) fn() end,
			new = function() return { start = function() end, stop = function() end } end,
			absoluteTime = (function()
				local STEP_NS = 80 * 1000000
				local t = 0
				return function() t = t + STEP_NS ; return t end
			end)(),
		},
		fs = { attributes = function() return nil end, dir = function() return function() return nil end end },
		keycodes = { currentLayout = function() return "ABC" end },
		execute = function() return "" end,
	})

	KL.start({ is_paused = function() return false end })
	return KL, captured_entries
end





-- ================================================
-- ================================================
-- ======= 2/ Producer Coverage Is Complete =======
-- ================================================
-- ================================================

local KL, CAPTURED = load_real_keylogger()

--- Every public producer discovered by reflection on the module surface.
local DISCOVERED_PRODUCERS = {}
for name, value in pairs(KL) do
	if type(name) == "string" and name:match("^log_") and type(value) == "function" then
		DISCOVERED_PRODUCERS[#DISCOVERED_PRODUCERS + 1] = name
	end
end
table.sort(DISCOVERED_PRODUCERS)

helpers.describe("keylogger: every public log_* producer is covered by this test", function()
	helpers.it("no public log_* function is missing from PRODUCER_ARGS", function()
		helpers.assert_true(#DISCOVERED_PRODUCERS > 0,
			"reflection must find the producers — otherwise this whole file is inert")
		local missing = {}
		for _, name in ipairs(DISCOVERED_PRODUCERS) do
			if not PRODUCER_ARGS[name] then missing[#missing + 1] = name end
		end
		helpers.assert_eq(#missing, 0,
			"new producer(s) " .. table.concat(missing, ", ")
			.. " have no entry in PRODUCER_ARGS — add one so their event type is "
			.. "checked against build_inserts (that omission is how llm_generation_failed "
			.. "shipped with no builder)")
	end)
end)





-- ========================================================
-- ========================================================
-- ======= 3/ Every Emitted Type Has A Real Builder =======
-- ========================================================
-- ========================================================

-- Drive every producer, then collect the distinct types that reached the log.
for _, name in ipairs(DISCOVERED_PRODUCERS) do
	local args = PRODUCER_ARGS[name]
	if args then pcall(KL[name], table.unpack(args)) end
end

-- context_tracker's own writer types. They travel the same today.log -> ingest
-- pipeline and are just as lossy when unhandled, but the tracker is driven by OS
-- watchers rather than a log_* call, so they are appended explicitly here.
local CONTEXT_TRACKER_TYPES = { "window_switch", "sys_autocorrect" }

local EMITTED_TYPES = {}
local function remember(t)
	if type(t) == "string" then EMITTED_TYPES[t] = true end
end
for _, entry in ipairs(CAPTURED) do remember(entry.type) end
for _, t in ipairs(CONTEXT_TRACKER_TYPES) do remember(t) end

--- Minimal well-formed entry for a type, so build_inserts is exercised on a
--- realistic payload rather than a bare `{ type = … }`.
--- @param t string Event type.
--- @return table Entry table.
local function sample_entry(t)
	for _, entry in ipairs(CAPTURED) do
		if entry.type == t then return entry end
	end
	return { type = t, app = "TestApp", timestamp = "2026-07-20 12:00:00.000" }
end

local SW = helpers.load_with_stubs("modules.keylogger.sqlite_writer")
SW.init({
	paths = { sqlite_path = "/tmp/test.sqlite" },
	device_obj = { device_id = "test-device", name = "Test", os = "darwin", host_signature = "sig", created_at = "2026-07-20 00:00:00.000" },
	device_id = "test-device",
})

local SORTED_TYPES = {}
for t in pairs(EMITTED_TYPES) do SORTED_TYPES[#SORTED_TYPES + 1] = t end
table.sort(SORTED_TYPES)

helpers.describe("keylogger/sqlite_writer: build_inserts handles every emitted event type", function()
	helpers.it("at least one producer type was captured", function()
		helpers.assert_true(#SORTED_TYPES > 0,
			"no event types captured — the harness is inert and would pass vacuously")
	end)

	for _, t in ipairs(SORTED_TYPES) do
		helpers.it("'" .. t .. "' produces at least one INSERT", function()
			local stmts = SW.build_inserts(sample_entry(t))
			helpers.assert_eq(type(stmts), "table")
			helpers.assert_true(#stmts > 0,
				"event type '" .. t .. "' is written to today.log but has no builder — "
				.. "the ingest cursor advances past it and rollover deletes today.log, "
				.. "so the event is lost forever")
		end)
	end
end)





-- ====================================================================
-- ====================================================================
-- ======= 4/ Emitted Rows Satisfy The Schema CHECK Constraints =======
-- ====================================================================
-- ====================================================================

--- Parses `CHECK (<col> IN ('a','b'))` constraints out of the canonical schema.
--- @return table Map of table name -> { column -> { allowed value -> true } }.
local function parse_check_constraints()
	local fh = io.open(helpers.shared("data/db/schema.sql"), "r")
	helpers.assert_true(fh ~= nil, "schema.sql must be readable")
	local schema = fh:read("*a"); fh:close()

	local constraints = {}
	for table_name, body in schema:gmatch("CREATE TABLE IF NOT EXISTS ([%w_]+)%s*%((.-)\n%);") do
		for column, allowed_blob in body:gmatch("([%w_]+)%s+TEXT NOT NULL CHECK %(%s*[%w_]+ IN %((.-)%)%)") do
			local allowed = {}
			for value in allowed_blob:gmatch("'([^']*)'") do allowed[value] = true end
			constraints[table_name] = constraints[table_name] or {}
			constraints[table_name][column] = allowed
		end
	end
	return constraints
end

--- Splits a SQL VALUES tuple into its literals, honouring '' escapes so a comma
--- inside a quoted JSON payload is not mistaken for a separator.
--- @param blob string The text between the VALUES parentheses.
--- @return table Array of unquoted literal values.
local function split_sql_values(blob)
	local out, buf, in_string = {}, {}, false
	local i = 1
	while i <= #blob do
		local c = blob:sub(i, i)
		if in_string then
			if c == "'" then
				if blob:sub(i + 1, i + 1) == "'" then
					buf[#buf + 1] = "'" ; i = i + 1
				else
					in_string = false
				end
			else
				buf[#buf + 1] = c
			end
		elseif c == "'" then
			in_string = true
		elseif c == "," then
			out[#out + 1] = table.concat(buf) ; buf = {}
		elseif c ~= " " then
			buf[#buf + 1] = c
		end
		i = i + 1
	end
	out[#out + 1] = table.concat(buf)
	return out
end

local CHECK_CONSTRAINTS = parse_check_constraints()

helpers.describe("keylogger/sqlite_writer: no emitted row violates a schema CHECK constraint", function()
	helpers.it("the schema parser found the constraints it is meant to enforce", function()
		helpers.assert_true(CHECK_CONSTRAINTS.events_llm ~= nil
			and CHECK_CONSTRAINTS.events_llm.kind ~= nil,
			"events_llm.kind CHECK must be parsed — otherwise this section is inert")
	end)

	for _, t in ipairs(SORTED_TYPES) do
		helpers.it("'" .. t .. "' emits only values the schema accepts", function()
			for _, stmt in ipairs(SW.build_inserts(sample_entry(t))) do
				local table_name, column_blob, value_blob =
					stmt:match("INSERT OR IGNORE INTO ([%w_]+) %((.-)%) VALUES %((.*)%);")
				helpers.assert_true(table_name ~= nil, "unparsable statement: " .. stmt)

				local per_column = CHECK_CONSTRAINTS[table_name]
				if per_column then
					local columns = {}
					for column in column_blob:gmatch("[%w_]+") do columns[#columns + 1] = column end
					local values = split_sql_values(value_blob)

					for index, column in ipairs(columns) do
						local allowed = per_column[column]
						if allowed then
							helpers.assert_true(allowed[values[index]] == true,
								"'" .. t .. "' writes " .. table_name .. "." .. column .. "='"
								.. tostring(values[index]) .. "', which the schema CHECK rejects — "
								.. "INSERT OR IGNORE drops such a row SILENTLY, so the event would "
								.. "still be lost even though a builder now exists")
						end
					end
				end
			end
		end)
	end
end)
