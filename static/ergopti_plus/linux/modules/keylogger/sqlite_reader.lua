--- modules/keylogger/sqlite_reader.lua

--- ==============================================================================
--- MODULE: Keylogger SQLite Reader (Linux)
--- DESCRIPTION:
--- Read-only SQLite projection for the shared metrics dashboards. It returns
--- the same manifest and n-gram envelopes as macOS and Windows while keeping
--- the Linux CLI backend out of the rendering path.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local SqliteCommand = require("modules.keylogger.sqlite_command")
local ok_json, Json = pcall(require, "json")
local LOG = "modules.keylogger.sqlite_reader"

local EMPTY_NGRAMS = { "c", "bg", "tg", "qg", "pg", "hx", "hp", "w", "sc", "sc_bg", "w_bg", "kc", "sc_kb" }

-- Which table backs each code the dashboard asks for. Only "c" was ever read
-- here: the other eight codes were handed back as permanently empty maps, so
-- the word lists, the pair lists and every panel keyed on a sequence longer
-- than one character rendered blank whatever the database held.
local NGRAM_TYPE_TABLE = {
	c    = "ngram_chars",
	bg   = "ngram_bigrams",
	tg   = "ngram_trigrams",
	qg   = "ngram_quadgrams",
	pg   = "ngram_pentagrams",
	hx   = "ngram_hexagrams",
	hp   = "ngram_heptagrams",
	w    = "ngram_words",
	w_bg = "ngram_word_bigrams",
}

-- Read in a fixed order so a failure is reproducible and the SQL a test greps
-- for is the SQL that runs. `pairs` over the map above would do neither.
local NGRAM_CODES = { "c", "bg", "tg", "qg", "pg", "hx", "hp", "w", "w_bg" }

local function sql_quote(value)
	return "'" .. tostring(value or ""):gsub("'", "''") .. "'"
end

local function valid_date(value)
	return type(value) == "string" and value:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil
end

--- Executes a read-only JSON query through sqlite3.
local function read_rows(sqlite_path, sql)
	if not ok_json or type(sqlite_path) ~= "string" or sqlite_path == "" then return {} end
	-- Same rule as the writer: the script goes on stdin, never through a file in
	-- a world-writable directory.
	local cmd = SqliteCommand.build(sqlite_path, sql, { flags = { "-json" } })
	if not cmd then return {} end
	local pipe = io.popen(cmd, "r")
	if not pipe then return {} end
	local body = pipe:read("*a") or ""
	pipe:close()
	if body == "" then return {} end
	local ok, rows = pcall(Json.decode, body)
	if not ok or type(rows) ~= "table" then
		Logger.warn(LOG, "SQLite read returned invalid JSON; dashboard projection skipped.")
		return {}
	end
	return rows
end

local function filters(start_date, end_date, apps)
	local clauses = {}
	if valid_date(start_date) then clauses[#clauses + 1] = "date >= " .. sql_quote(start_date) end
	if valid_date(end_date) then clauses[#clauses + 1] = "date <= " .. sql_quote(end_date) end
	if type(apps) == "table" and #apps > 0 then
		local quoted = {}
		for _, app in ipairs(apps) do
			if type(app) == "string" and app ~= "" then quoted[#quoted + 1] = sql_quote(app) end
		end
		if #quoted > 0 then clauses[#clauses + 1] = "app IN (" .. table.concat(quoted, ",") .. ")" end
	end
	return #clauses > 0 and (" WHERE " .. table.concat(clauses, " AND ")) or ""
end

local function new_entry()
	return {
		chars = 0, pauses = 0, time = 0, think_time = 0,
		hs_chars = 0, llm_chars = 0, hs_triggers = 0, llm_triggers = 0,
		hs_suggested = 0, llm_suggested = 0, hs_input_chars = 0,
		llm_input_chars = 0, app_time_ms = 0, category = "Unknown",
		hourly = {}, hourly_min5 = {}, time_buckets = {}, credited_buckets = {},
		hs_input_time_buckets = {}, hs_input_credited_buckets = {},
		llm_input_time_buckets = {}, llm_input_credited_buckets = {},
	}
end

local function get_entry(manifest, date, app)
	manifest[date] = manifest[date] or {}
	manifest[date][app] = manifest[date][app] or new_entry()
	return manifest[date][app]
end

--- Builds the shared date/app manifest from persisted aggregates.
function M.read_manifest(sqlite_path, start_date, end_date, apps)
	local manifest = {}
	local rows = read_rows(sqlite_path, string.format([[
SELECT date, app, SUM(chars) AS chars, SUM(pauses) AS pauses,
       SUM(time_ms) AS time_ms, SUM(think_time_ms) AS think_time_ms,
       SUM(hs_chars) AS hs_chars, SUM(llm_chars) AS llm_chars,
       SUM(hs_triggers) AS hs_triggers, SUM(llm_triggers) AS llm_triggers,
       SUM(hs_suggested) AS hs_suggested, SUM(llm_suggested) AS llm_suggested,
       SUM(hs_input_chars) AS hs_input_chars, SUM(llm_input_chars) AS llm_input_chars,
       SUM(app_time_ms) AS app_time_ms, MAX(category) AS category
FROM agg_app_day%s GROUP BY date, app;
]], filters(start_date, end_date, apps)))
	for _, row in ipairs(rows) do
		local entry = get_entry(manifest, row.date, row.app)
		entry.chars = row.chars or 0
		entry.pauses = row.pauses or 0
		entry.time = row.time_ms or 0
		entry.think_time = row.think_time_ms or 0
		entry.hs_chars = row.hs_chars or 0
		entry.llm_chars = row.llm_chars or 0
		entry.hs_triggers = row.hs_triggers or 0
		entry.llm_triggers = row.llm_triggers or 0
		entry.hs_suggested = row.hs_suggested or 0
		entry.llm_suggested = row.llm_suggested or 0
		entry.hs_input_chars = row.hs_input_chars or 0
		entry.llm_input_chars = row.llm_input_chars or 0
		entry.app_time_ms = row.app_time_ms or 0
		entry.category = row.category or "Unknown"
	end
	return manifest
end

local function empty_ngrams()
	local out = {}
	for _, code in ipairs(EMPTY_NGRAMS) do out[code] = {} end
	return out
end

local function source_count(esrc_json, source)
	if type(esrc_json) ~= "string" or esrc_json == "" then return 0 end
	if ok_json then
		local ok, decoded = pcall(Json.decode, esrc_json)
		if ok and type(decoded) == "table" then return tonumber(decoded[source]) or 0 end
	end
	local raw = esrc_json:match('"' .. source .. '"%s*:%s*(%d+)')
	return tonumber(raw) or 0
end

local function merge_ngram(target, token, count, esrc_json, total_delay, error_count)
	if type(token) ~= "string" or token == "" then return end
	local item = target[token] or { c = 0, t = 0, e = 0, hs = 0, llm = 0, o = 0 }
	item.c = item.c + (tonumber(count) or 0)
	-- The delay total and the error count are what turn a frequency list into a
	-- cost ranking. Both were dropped on the floor here while the writer stored
	-- them, so the dashboard sorted "your most expensive sequences" by zero.
	item.t = item.t + (tonumber(total_delay) or 0)
	item.e = item.e + (tonumber(error_count) or 0)
	item.hs = item.hs + source_count(esrc_json, "hotstring")
	item.llm = item.llm + source_count(esrc_json, "llm")
	item.o = item.o + source_count(esrc_json, "other")
	target[token] = item
end

--- Reads character and physical-scancode n-grams for a range. Character source
--- JSON is merged in Lua rather than selected with MIN()/MAX(): source counts
--- are additive across dates and devices, just like the token count itself.
function M.read_ngrams(sqlite_path, start_date, end_date, apps)
	local out = empty_ngrams()
	local where = filters(start_date, end_date, apps)
	for _, code in ipairs(NGRAM_CODES) do
		local rows = read_rows(sqlite_path, string.format(
			"SELECT token, c, td, e, esrc_json FROM %s%s;", NGRAM_TYPE_TABLE[code], where))
		for _, row in ipairs(rows) do
			merge_ngram(out[code], row.token, row.c, row.esrc_json, row.td, row.e)
		end
	end
	local sc_rows = read_rows(sqlite_path, string.format(
		"SELECT scancode, SUM(c) AS c FROM ngram_scancodes%s GROUP BY scancode;",
		filters(start_date, end_date, apps)))
	for _, row in ipairs(sc_rows) do merge_ngram(out.sc_kb, tostring(row.scancode), row.c) end
	return out
end

--- Returns historical n-grams before today plus per-app n-grams for today.
function M.read_range_split_today(sqlite_path, start_date, end_date, apps)
	local today = os.date("%Y-%m-%d")
	local yesterday = os.date("%Y-%m-%d", os.time() - 86400)
	local historical_end = valid_date(end_date) and end_date < today and end_date or yesterday
	local historical = M.read_ngrams(sqlite_path, start_date, historical_end, apps)
	local today_by_app = {}
	local today_where = filters(today, today, apps)
	for _, code in ipairs(NGRAM_CODES) do
		local rows = read_rows(sqlite_path, string.format(
			"SELECT app, token, c, td, e, esrc_json FROM %s%s;",
			NGRAM_TYPE_TABLE[code], today_where))
		for _, row in ipairs(rows) do
			today_by_app[row.app] = today_by_app[row.app] or empty_ngrams()
			merge_ngram(today_by_app[row.app][code], row.token, row.c, row.esrc_json, row.td, row.e)
		end
	end
	local sc_rows = read_rows(sqlite_path, string.format(
		"SELECT app, scancode, SUM(c) AS c FROM ngram_scancodes%s GROUP BY app, scancode;",
		filters(today, today, apps)))
	for _, row in ipairs(sc_rows) do
		today_by_app[row.app] = today_by_app[row.app] or empty_ngrams()
		merge_ngram(today_by_app[row.app].sc_kb, tostring(row.scancode), row.c)
	end
	return { historical = historical, today = today_by_app }
end

return M
