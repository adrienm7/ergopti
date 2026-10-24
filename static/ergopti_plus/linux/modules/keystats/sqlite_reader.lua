--- modules/keystats/sqlite_reader.lua

--- ==============================================================================
--- MODULE: Keystats SQLite Reader (Linux)
--- DESCRIPTION:
--- Read-only SQLite projection for the shared metrics dashboards. It returns
--- the same manifest and n-gram envelopes as macOS and Windows while keeping
--- the Linux CLI backend out of the rendering path.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Utils = require("keystats.utils")
local MediaStore = require("keystats.media_store")
local SqliteCommand = require("modules.keystats.sqlite_command")
local Queries = require("keystats.queries")
local ok_json, Json = pcall(require, "json")
local LOG = "modules.keystats.sqlite_reader"

-- An ambiguous media pipe close is never retried or replaced by another query.
local _media_read_debt = nil

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

-- Each projection selects free text as `json_quote(column) AS column_json`;
-- read_rows decodes it back under the column name the projections read.
local QUOTED_TEXT_COLUMNS = { app_json = "app", title_json = "title", layout_json = "layout", app_to_json = "app_to" }

local function sql_quote(value)
	return "'" .. SqliteCommand.escape_literal(tostring(value or "")) .. "'"
end

local function valid_date(value)
	return type(value) == "string" and value:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil
end

--- Executes a read-only JSON query through sqlite3.
local function read_rows(sqlite_path, sql, media_owned)
	if media_owned and _media_read_debt ~= nil then return {}, false end
	if not ok_json or type(sqlite_path) ~= "string" or sqlite_path == "" then return {}, false end
	-- Same rule as the writer: the script goes on stdin, never through a file in
	-- a world-writable directory.
	-- Readonly is an open-time property: SELECT alone still creates a missing
	-- database (or a dangling alias target) under SQLite's default create mode.
	local cmd = SqliteCommand.build(sqlite_path, sql, { flags = { "-readonly", "-json" }, capture_exit = true })
	if not cmd then return {}, false end
	local pipe = io.popen(cmd, "r")
	if not pipe then return {}, false end
	local output
	if media_owned then
		local read_ok, result = pcall(pipe.read, pipe, "*a")
		local close_ok, closed = pcall(pipe.close, pipe)
		if not close_ok or closed ~= true then
			_media_read_debt = pipe
			Logger.warn(LOG, "Semantic media read cleanup failed; exact pipe retained without retry.")
			return {}, false
		end
		if not read_ok or type(result) ~= "string" then
			Logger.warn(LOG, "Semantic media read failed after acknowledged pipe retirement.")
			return {}, false
		end
		output = result
	else
		output = pipe:read("*a")
		pipe:close()
	end
	local accepted, body, reason = SqliteCommand.read_exit_receipt(output)
	if not accepted then
		Logger.warn(LOG, "SQLite read refused: %s.", reason)
		return {}, false
	end
	if body == "" then return {}, true end
	local ok, rows = pcall(Json.decode_lossless, body)
	if not ok or type(rows) ~= "table" then
		Logger.warn(LOG, "SQLite read returned invalid JSON; dashboard projection skipped.")
		return {}, false
	end
	-- SQLite emits scalar object fields, with null for absent SQL values. The
	-- legacy decoder represents null as an ordinary empty table, which defeats
	-- numeric defaults and publishes optional extrema as {}. Only the explicit
	-- lossless token is absent here; inner JSON text and array identities survive.
	for _, row in ipairs(rows) do
		for column, value in pairs(row) do
			if Json.is_null(value) then row[column] = nil end
		end
		-- Free text is selected through json_quote, which escapes NUL before the
		-- CLI can cut it: a shortened application id is another application.
		for quoted, column in pairs(QUOTED_TEXT_COLUMNS) do
			if row[quoted] ~= nil then
				local decoded, text = pcall(Json.decode, row[quoted])
				if not decoded or type(text) ~= "string" then
					Logger.warn(LOG, "SQLite %s text is invalid; dashboard projection skipped.", column)
					return {}, false
				end
				row[column] = text
			end
		end
	end
	return rows, true
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
		media_keys = {}, media_hold = {},
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

--- Decodes an optional TEXT value that SQL quoted with json_quote.
--- decode_lossless answers nil for malformed text rather than raising, and a
--- null token for SQL NULL; an absent column is an absent value.
--- @param quoted string|nil The json_quote output.
--- @return boolean valid
--- @return string|nil text
local function decode_optional_text(quoted)
	if quoted == nil then return true, nil end
	if type(quoted) ~= "string" then return false, nil end
	local value = Json.decode_lossless(quoted)
	if Json.is_null(value) then return true, nil end
	if type(value) == "string" then return true, value end
	return false, nil
end

--- Merges persisted error buckets while retaining identical device contributions.
local function merge_error_buckets(target, row)
	if not ok_json or type(row.e_buckets_json) ~= "string" then return end
	local ok, buckets = pcall(Json.decode, row.e_buckets_json)
	if not ok or type(buckets) ~= "table" then return end
	for label, count in pairs(buckets) do
		target[label] = (target[label] or 0) + (tonumber(count) or 0) * row.source_rows
	end
end

--- Projects local saved category/score overrides for the shared Apps dashboard.
--- One read-only query joins every score to this device's category history;
--- foreign synced categories must not replace the user's own assignment.
--- @param sqlite_path string Database path.
--- @param device_id string Local device owning the category edit.
--- @return table|nil categories Shared { app = { type, score } } map; nil on refusal.
function M.read_user_categories(sqlite_path, device_id)
	if type(device_id) ~= "string" or device_id == "" then return nil end
	local prefix = sql_quote("app_score.")
	-- TEXT substr stops at NUL. The namespace is ASCII, so slice its bytes first.
	local app = "CAST(substr(CAST(scores.key AS BLOB), length(" .. prefix .. ") + 1) AS TEXT)"
	local rows, accepted = read_rows(sqlite_path,
		"SELECT json_quote(" .. app .. ") AS app_json, json_quote(scores.value) AS score_json, "
		.. "json_quote(MAX(owned.category)) AS category_json FROM meta AS scores "
		.. "LEFT JOIN agg_app_day AS owned ON owned.app = " .. app
		.. " AND owned.device_id = " .. sql_quote(device_id)
		.. " WHERE substr(scores.key, 1, length(" .. prefix .. ")) = " .. prefix
		.. " GROUP BY scores.key, scores.value;")
	if not accepted then return nil end
	local categories = {}
	for _, row in ipairs(rows) do
		-- Quote text before the CLI JSON boundary so NUL cannot shorten a key,
		-- category or malformed score into a different, apparently valid value.
		local ok_app, name = pcall(Json.decode, row.app_json)
		local ok_score, raw_score = pcall(Json.decode, row.score_json)
		local ok_category, category = decode_optional_text(row.category_json)
		local score = ok_score and type(raw_score) == "string" and tonumber(raw_score) or nil
		if not ok_app or type(name) ~= "string" or name == "" or not score
			or score ~= score or score == math.huge or score == -math.huge
			or not ok_category or (category ~= nil and type(category) ~= "string") then
			Logger.warn(LOG, "SQLite category metadata is invalid; dashboard projection refused.")
			return nil
		end
		categories[name] = { type = category or new_entry().category, score = score }
	end
	return categories
end

-- Totals of the machine's own day published under manifest[date]._system.
local SYSTEM_DAY_TOTALS = {
	"wifi_changes", "space_switches", "battery_sum", "battery_count", "audio_muted_ms",
	"locked_ms", "sleep_ms", "awake_ms", "passive_count", "night_wake_count",
}

--- Projects one catalogue system-day row onto the page's field names. The
--- battery extrema stay nil on a day no device sampled the battery: the lowest
--- charge of the day is a record, and inventing a zero would be one.
--- @param row table A manifest.system_day row.
--- @return table
local function system_day(row)
	local out = { battery_min = row.battery_min, battery_max = row.battery_max }
	for _, field in ipairs(SYSTEM_DAY_TOTALS) do out[field] = row[field] or 0 end
	return out
end

--- Builds the shared date/app manifest from persisted aggregates.
--- @return table manifest Partial or complete dashboard projection.
--- @return boolean complete Whether every native query was accepted.
function M.read_manifest(sqlite_path, start_date, end_date, apps)
	local manifest = {}
	local complete = true
	-- A partial projection remains a useful first return, but must never become
	-- a successful revision cache entry. Track every CLI pass independently.
	local function query(sql, media_owned)
		local rows, accepted = read_rows(sqlite_path, sql, media_owned)
		if not accepted then complete = false end
		return rows
	end
	-- The per-app-day aggregates. The SQL is the shared catalogue's
	-- (_shared/data/db/queries.sql) in the CLI dialect, so field names match the
	-- macOS and Windows projections exactly: the dashboard is the same one.
	local where = filters(start_date, end_date, apps)
	local function manifest_query(name, media_owned)
		return query(Queries.render(name, "cli_json", { where = where }), media_owned)
	end
	local rows = manifest_query("manifest.app_day")
	for _, row in ipairs(rows) do
		-- Quoted in SQL as read_user_categories quotes it: the CLI's JSON mode
		-- cuts raw TEXT at NUL, so a saved category came back shortened.
		local valid, category = decode_optional_text(row.category_json)
		if not valid then
			Logger.warn(LOG, "SQLite application category is invalid; manifest projection incomplete.")
			complete, category = false, nil
		end
		row.category = category
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

	for _, row in ipairs(manifest_query("manifest.chars_class")) do
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

	for _, row in ipairs(manifest_query("manifest.errors")) do
		local entry = get_entry(manifest, row.date, row.app)
		entry.bs_total = row.bs_total or 0
		entry.cascade_count_total = row.cascade_count or 0
		entry.cascade_max_len = row.cascade_max_len or 0
		entry.recovery_time_sum_ms = row.recovery_sum or 0
		entry.recovery_time_count = row.recovery_count or 0
	end

	for _, row in ipairs(manifest_query("manifest.ergo")) do
		local entry = get_entry(manifest, row.date, row.app)
		-- MAX, not SUM: the longest same-finger run of the day is a record. Adding
		-- two devices' records would invent a streak nobody typed.
		entry.same_finger_streak_max = row.f_max or 0
		entry.same_hand_streak_max = row.h_max or 0
		entry.auto_repeat_count = row.ar_count or 0
		entry.focus_to_first_key_sum_ms = row.focus_sum or 0
		entry.focus_to_first_key_count = row.focus_count or 0
	end

	for _, row in ipairs(manifest_query("manifest.media_keys", true)) do
		get_entry(manifest, row.date, row.app).media_keys[row.media_id] = MediaStore.project_press(row)
	end

	for _, row in ipairs(manifest_query("manifest.media_hold", true)) do
		get_entry(manifest, row.date, row.app).media_hold[row.media_id] = MediaStore.project_hold(row)
	end

	for _, row in ipairs(manifest_query("manifest.kc_hold")) do
		local entry = get_entry(manifest, row.date, row.app)
		entry.kc_hold = entry.kc_hold or {}
		entry.kc_hold[tostring(row.keycode)] = {
			s = row.s or 0, n = row.c or 0,
			-- MAX, not SUM: the longest hold of the day is a record across devices.
			m = row.mx or 0,
			tap = row.t or 0, hold = row.h or 0,
		}
	end

	for _, row in ipairs(manifest_query("manifest.layouts")) do
		local entry = get_entry(manifest, row.date, row.app)
		entry.layouts_seen = entry.layouts_seen or {}
		entry.layouts_seen[row.layout] = (entry.layouts_seen[row.layout] or 0) + (row.count or 0)
	end

	for _, row in ipairs(manifest_query("manifest.titles")) do
		local entry = get_entry(manifest, row.date, row.app)
		-- The shared page reads win_titles, as the Windows and macOS readers name it.
		entry.win_titles = entry.win_titles or {}
		entry.win_titles[row.title] = { c = row.c or 0, ms = row.ms or 0 }
	end

	for _, row in ipairs(manifest_query("manifest.hourly")) do
		local entry = get_entry(manifest, row.date, row.app)
		local bucket = entry.hourly[row.hour] or { c = 0, e = 0, em = 0, es = 0, e_buckets = {} }
		entry.hourly[row.hour] = bucket
		for _, field in ipairs({ "c", "e", "em", "es" }) do
			bucket[field] = bucket[field] + (row[field] or 0)
		end
		merge_error_buckets(bucket.e_buckets, row)
	end

	for _, row in ipairs(manifest_query("manifest.hourly_min5")) do
		local entry = get_entry(manifest, row.date, row.app)
		local bucket = entry.hourly_min5[row.slot] or { c = 0, e = 0, es = 0, e_buckets = {} }
		entry.hourly_min5[row.slot] = bucket
		for _, field in ipairs({ "c", "e", "es" }) do
			bucket[field] = bucket[field] + (row[field] or 0)
		end
		merge_error_buckets(bucket.e_buckets, row)
	end

	for _, row in ipairs(manifest_query("manifest.buckets")) do
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
	-- Count identical blobs too: grouping must not deduplicate their buckets.
	for _, row in ipairs(manifest_query("manifest.burst")) do
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
						(entry.burst_length_buckets[label] or 0) + (tonumber(count) or 0) * row.source_rows
				end
			end
		end
	end

	for _, row in ipairs(manifest_query("manifest.session")) do
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

	-- Application filters select the source app; its destinations remain the
	-- workflow the shared metrics pages display. Alias the source at the SQL
	-- boundary so the same date/app filter policy covers this differently keyed
	-- aggregate, including synchronized contributions from several devices.
	for _, row in ipairs(manifest_query("manifest.switches_to")) do
		local entry = get_entry(manifest, row.date, row.app)
		entry.switches_to = entry.switches_to or {}
		entry.switches_to[row.app_to] = row.count or 0
	end

	-- The machine's own day, which both pages read under _system, as the
	-- Windows reader publishes it. It has no application, so only the dates
	-- filter it.
	local system_sql = Queries.render("manifest.system_day", "cli_json",
		{ where = filters(start_date, end_date, nil) })
	for _, row in ipairs(query(system_sql)) do
		manifest[row.date] = manifest[row.date] or {}
		manifest[row.date]._system = system_day(row)
	end

	return manifest, complete
end

--- Reads the machine's own state for a range: the rows read_manifest publishes
--- under the reserved `_system` pseudo-application, keyed by date alone.
--- @param sqlite_path string
--- @param start_date string|nil
--- @param end_date string|nil
--- @return table date → row
function M.read_system_days(sqlite_path, start_date, end_date)
	local out = {}
	local sql = Queries.render("manifest.system_day", "cli_json", { where = filters(start_date, end_date, nil) })
	for _, row in ipairs(read_rows(sqlite_path, sql)) do
		out[row.date] = system_day(row)
	end
	return out
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
		if ok and type(decoded) == "table" then
			if source ~= "other" then return tonumber(decoded[source]) or 0 end
			-- All additional synthetic labels belong to the shared other bucket.
			-- Numeric array keys are not source labels; scalar admission is unchanged.
			local count = 0
			for label, value in pairs(decoded) do
				if Utils.is_other_synthetic_source(label) then
					count = count + (tonumber(value) or 0)
				end
			end
			return count
		end
	end
	local raw = esrc_json:match('"' .. source .. '"%s*:%s*(%d+)')
	return tonumber(raw) or 0
end

--- Decodes SQL's JSON string before native token bytes become projection keys.
--- The CLI's JSON mode truncates raw TEXT at NUL. json_quote uses SQLite's
--- complete byte length and escapes NUL before the CLI can shorten it.
local function decode_token(row)
	local ok, token = pcall(Json.decode, row.token_json)
	if ok and type(token) == "string" then return token end
	Logger.warn(LOG, "SQLite n-gram token returned invalid JSON; token projection skipped.")
	return nil
end

local function merge_ngram(target, token, count, esrc_json, total_delay, error_count, source_rows)
	if type(token) ~= "string" or token == "" then return end
	local item = target[token] or { c = 0, t = 0, e = 0, hs = 0, llm = 0, o = 0 }
	item.c = item.c + (tonumber(count) or 0)
	-- The delay total and the error count are what turn a frequency list into a
	-- cost ranking. Both were dropped on the floor here while the writer stored
	-- them, so the dashboard sorted "your most expensive sequences" by zero.
	item.t = item.t + (tonumber(total_delay) or 0)
	item.e = item.e + (tonumber(error_count) or 0)
	local copies = tonumber(source_rows) or 1
	item.hs = item.hs + source_count(esrc_json, "hotstring") * copies
	item.llm = item.llm + source_count(esrc_json, "llm") * copies
	item.o = item.o + source_count(esrc_json, "other") * copies
	target[token] = item
end

--- Renders the shared catalogue's n-gram token read (_shared/data/db/queries.sql)
--- for one family table. Source JSON is merged in Lua rather than selected with
--- MIN()/MAX(): source counts are additive across dates and devices, just like
--- the token count. TOTAL accumulates as a float, avoiding SUM's integer
--- overflow, and a row whose counters are not numbers comes back raw for the
--- merge to read as zero.
local function grouped_ngram_sql(table_name, where, by_app)
	return Queries.render(by_app and "ngram.tokens_by_app" or "ngram.tokens", "cli_json", {
		table = table_name, where = where, conjunction = where == "" and " WHERE " or " AND ",
	})
end

--- Reads the n-grams of an inclusive range, every family summed across apps.
--- @param sqlite_path string Database path.
--- @param start_date string|nil Inclusive lower bound.
--- @param end_date string|nil Inclusive upper bound.
--- @param apps table|nil Selected application names.
--- @return table ngrams Partial or complete n-gram dictionaries.
--- @return boolean complete Whether every native query was accepted.
function M.read_ngrams(sqlite_path, start_date, end_date, apps)
	local out = empty_ngrams()
	local complete = true
	local where = filters(start_date, end_date, apps)
	for _, code in ipairs(NGRAM_CODES) do
		local rows, accepted = read_rows(sqlite_path, grouped_ngram_sql(NGRAM_TYPE_TABLE[code], where, false))
		if not accepted then complete = false end
		for _, row in ipairs(rows) do
			merge_ngram(out[code], decode_token(row), row.c, row.esrc_json, row.td, row.e, row.source_rows)
		end
	end
	local sc_rows, sc_accepted = read_rows(sqlite_path, string.format(
		"SELECT scancode, SUM(c) AS c FROM ngram_scancodes%s GROUP BY scancode;",
		filters(start_date, end_date, apps)))
	if not sc_accepted then complete = false end
	for _, row in ipairs(sc_rows) do merge_ngram(out.sc_kb, tostring(row.scancode), row.c) end
	return out, complete
end

--- Resolves inclusive date bounds against one captured local calendar day.
--- Invalid optional bounds are ignored, matching the reader's SQL filters.
--- @param start_date string|nil Inclusive lower bound.
--- @param end_date string|nil Inclusive upper bound.
--- @param today string|nil Captured current day; defaults to the local date.
--- @return table { today, includes_today, historical_end }.
function M.split_bounds(start_date, end_date, today)
	today = today or os.date("%Y-%m-%d")
	assert(valid_date(today), "Invalid current calendar day")
	-- Calendar days can contain 23 or 25 hours. Normalize yesterday at noon
	-- using this captured date, without subtracting a fixed day in seconds.
	local year, month, day = today:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	local yesterday = os.date("%Y-%m-%d", os.time({
		year = tonumber(year), month = tonumber(month), day = tonumber(day) - 1, hour = 12,
	}))
	return {
		today = today,
		includes_today = (not valid_date(start_date) or start_date <= today)
			and (not valid_date(end_date) or end_date >= today),
		historical_end = valid_date(end_date) and end_date < today and end_date or yesterday,
	}
end

--- Returns historical n-grams before today plus per-app n-grams for today.
--- Both slices obey the requested inclusive range and application filters.
--- @param sqlite_path string Database path.
--- @param start_date string|nil Inclusive lower bound.
--- @param end_date string|nil Inclusive upper bound.
--- @param apps table|nil Selected application names.
--- @param today string|nil Current day captured by the projection owner.
--- @return table { historical, today }.
--- @return boolean complete Whether every native query was accepted.
function M.read_range_split_today(sqlite_path, start_date, end_date, apps, today)
	local bounds = M.split_bounds(start_date, end_date, today)
	today = bounds.today
	local historical_end = bounds.historical_end
	local historical, complete = M.read_ngrams(sqlite_path, start_date, historical_end, apps)
	local today_by_app = {}
	if not bounds.includes_today then return { historical = historical, today = today_by_app }, complete end
	local today_where = filters(today, today, apps)
	for _, code in ipairs(NGRAM_CODES) do
		local rows, accepted = read_rows(sqlite_path, grouped_ngram_sql(NGRAM_TYPE_TABLE[code], today_where, true))
		if not accepted then complete = false end
		for _, row in ipairs(rows) do
			today_by_app[row.app] = today_by_app[row.app] or empty_ngrams()
			merge_ngram(today_by_app[row.app][code], decode_token(row), row.c, row.esrc_json, row.td, row.e, row.source_rows)
		end
	end
	local sc_rows, sc_accepted = read_rows(sqlite_path, string.format(
		"SELECT json_quote(app) AS app_json, scancode, SUM(c) AS c FROM ngram_scancodes%s GROUP BY app, scancode;",
		filters(today, today, apps)))
	if not sc_accepted then complete = false end
	for _, row in ipairs(sc_rows) do
		today_by_app[row.app] = today_by_app[row.app] or empty_ngrams()
		merge_ngram(today_by_app[row.app].sc_kb, tostring(row.scancode), row.c)
	end
	return { historical = historical, today = today_by_app }, complete
end

return M
