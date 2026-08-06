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

	-- The per-app-day aggregates. Field names match the macOS projection exactly,
	-- because the dashboard that reads them is the same one.
	local where = filters(start_date, end_date, apps)

	for _, row in ipairs(read_rows(sqlite_path, string.format([[
SELECT date, app, SUM(letter) AS letter, SUM(digit) AS digit, SUM(punct) AS punct,
       SUM(space) AS space, SUM(other) AS other,
       MIN(first_typed_min) AS first_min, MAX(last_typed_min) AS last_min
FROM agg_app_day_chars_class%s GROUP BY date, app;
]], where))) do
		local entry = get_entry(manifest, row.date, row.app)
		entry.char_letter = row.letter or 0
		entry.char_digit = row.digit or 0
		entry.char_punct = row.punct or 0
		entry.char_space = row.space or 0
		entry.char_other = row.other or 0
		-- MIN and MAX rather than the last row's value: several devices sync into
		-- one database, and the earliest keystroke of the day is the earliest
		-- across all of them.
		entry.first_typed_min = row.first_min
		entry.last_typed_min = row.last_min
	end

	for _, row in ipairs(read_rows(sqlite_path, string.format([[
SELECT date, app, SUM(bs_total) AS bs_total, SUM(cascade_count) AS cascade_count,
       MAX(cascade_max_len) AS cascade_max_len,
       SUM(recovery_sum_ms) AS recovery_sum, SUM(recovery_count) AS recovery_count
FROM agg_app_day_errors%s GROUP BY date, app;
]], where))) do
		local entry = get_entry(manifest, row.date, row.app)
		entry.bs_total = row.bs_total or 0
		entry.cascade_count_total = row.cascade_count or 0
		entry.cascade_max_len = row.cascade_max_len or 0
		entry.recovery_time_sum_ms = row.recovery_sum or 0
		entry.recovery_time_count = row.recovery_count or 0
	end

	for _, row in ipairs(read_rows(sqlite_path, string.format([[
SELECT date, app, hour, SUM(c) AS c, SUM(e) AS e, SUM(em) AS em, SUM(es) AS es
FROM agg_app_day_hourly%s GROUP BY date, app, hour;
]], where))) do
		local entry = get_entry(manifest, row.date, row.app)
		entry.hourly[row.hour] = {
			c = row.c or 0, e = row.e or 0, em = row.em or 0, es = row.es or 0,
			e_buckets = {},
		}
	end

	for _, row in ipairs(read_rows(sqlite_path, string.format([[
SELECT date, app, slot, SUM(c) AS c, SUM(e) AS e, SUM(es) AS es
FROM agg_app_day_hourly_min5%s GROUP BY date, app, slot;
]], where))) do
		local entry = get_entry(manifest, row.date, row.app)
		entry.hourly_min5[row.slot] = {
			c = row.c or 0, e = row.e or 0, es = row.es or 0, e_buckets = {},
		}
	end

	for _, row in ipairs(read_rows(sqlite_path, string.format([[
SELECT date, app, bucket_ms, SUM(time_sum) AS time_sum, SUM(credited) AS credited,
       SUM(hs_input_time_sum) AS hs_in_t, SUM(hs_input_credited) AS hs_in_c,
       SUM(llm_input_time_sum) AS llm_in_t, SUM(llm_input_credited) AS llm_in_c
FROM agg_app_day_buckets%s GROUP BY date, app, bucket_ms;
]], where))) do
		local entry = get_entry(manifest, row.date, row.app)
		local key = tostring(row.bucket_ms)
		entry.time_buckets[key] = (entry.time_buckets[key] or 0) + (row.time_sum or 0)
		entry.credited_buckets[key] = (entry.credited_buckets[key] or 0) + (row.credited or 0)
		entry.hs_input_time_buckets[key] = (entry.hs_input_time_buckets[key] or 0) + (row.hs_in_t or 0)
		entry.hs_input_credited_buckets[key] = (entry.hs_input_credited_buckets[key] or 0) + (row.hs_in_c or 0)
		entry.llm_input_time_buckets[key] = (entry.llm_input_time_buckets[key] or 0) + (row.llm_in_t or 0)
		entry.llm_input_credited_buckets[key] = (entry.llm_input_credited_buckets[key] or 0) + (row.llm_in_c or 0)
	end

	-- Grouped by the histogram blob as well as by app-day, so two devices'
	-- distinct blobs each come back as their own row and are merged below.
	-- Collapsing them in SQL would take one arbitrarily and discard the other.
	for _, row in ipairs(read_rows(sqlite_path, string.format([[
SELECT date, app, SUM(count_total) AS count_total, MAX(max_cpm) AS max_cpm,
       MAX(max_chars) AS max_chars, SUM(inter_delay_count) AS inter_count,
       SUM(inter_delay_sum) AS inter_sum, SUM(inter_delay_sumsq) AS inter_sumsq,
       length_buckets_json
FROM agg_app_day_burst%s GROUP BY date, app, length_buckets_json;
]], where))) do
		local entry = get_entry(manifest, row.date, row.app)
		entry.burst_count_total = (entry.burst_count_total or 0) + (row.count_total or 0)
		entry.burst_max_cpm = math.max(entry.burst_max_cpm or 0, row.max_cpm or 0)
		entry.burst_max_chars = math.max(entry.burst_max_chars or 0, row.max_chars or 0)
		entry.burst_inter_delay_count = (entry.burst_inter_delay_count or 0) + (row.inter_count or 0)
		entry.burst_inter_delay_sum = (entry.burst_inter_delay_sum or 0) + (row.inter_sum or 0)
		entry.burst_inter_delay_sumsq = (entry.burst_inter_delay_sumsq or 0) + (row.inter_sumsq or 0)
		entry.burst_length_buckets = entry.burst_length_buckets or {}
		if ok_json and type(row.length_buckets_json) == "string" then
			local decoded_ok, buckets = pcall(Json.decode, row.length_buckets_json)
			if decoded_ok and type(buckets) == "table" then
				for label, count in pairs(buckets) do
					entry.burst_length_buckets[label] =
						(entry.burst_length_buckets[label] or 0) + (tonumber(count) or 0)
				end
			end
		end
	end

	for _, row in ipairs(read_rows(sqlite_path, string.format([[
SELECT date, app, count_total, longest_ms, longest_chars, total_active_ms, durations_json
FROM agg_app_day_session%s;
]], where))) do
		local entry = get_entry(manifest, row.date, row.app)
		entry.session_count_total = (entry.session_count_total or 0) + (row.count_total or 0)
		-- The longest session of the day is a record across devices, not a sum:
		-- adding two machines' longest stretches would invent one nobody sat through.
		if (row.longest_ms or 0) > (entry.session_longest_ms or 0) then
			entry.session_longest_ms = row.longest_ms
		end
		if (row.longest_chars or 0) > (entry.session_longest_chars or 0) then
			entry.session_longest_chars = row.longest_chars
		end
		entry.session_total_active_ms = (entry.session_total_active_ms or 0) + (row.total_active_ms or 0)
		entry.session_durations = entry.session_durations or {}
		if ok_json and type(row.durations_json) == "string" then
			local decoded_ok, durations = pcall(Json.decode, row.durations_json)
			if decoded_ok and type(durations) == "table" then
				for _, duration in ipairs(durations) do
					entry.session_durations[#entry.session_durations + 1] = duration
				end
			end
		end
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
