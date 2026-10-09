--- modules/keylogger/aggregator/sql.lua

--- ==============================================================================
--- MODULE: Aggregator SQL — Batch DB Flush
--- DESCRIPTION:
--- Drains the per-tick in-memory accumulator (S.agg_batch) into the SQLite
--- aggregate tables using ON CONFLICT … DO UPDATE (UPSERT) statements. All
--- writes are expected to run inside a transaction opened by the caller.
---
--- SQL helpers (exec, json_lit, sq, i) are intentionally private to this
--- module — they are pure formatting utilities with no need for external access.
---
--- MIRRORS: windows/modules/keylogger/keylogger_walker_sql.ahk
--- ==============================================================================

local M = {}

local json    = require("hs.json")
local sqlite3 = require("hs.sqlite3")
local Logger  = require("infra.logger")
local LOG     = "keylogger.aggregator"

local SqliteWriter = require("modules.keylogger.sqlite_writer")
local Export       = require("modules.keylogger.export")
local AggHelper    = require("keylogger.aggregator_helpers")

local S = require("modules.keylogger.aggregator.state")
local C = require("modules.keylogger.aggregator.core")





-- ==============================
-- ==============================
-- ======= 1/ SQL Helpers =======
-- ==============================
-- ==============================

--- Execute a SQL statement against the open db; log on failure.
---
--- The statement itself is NEVER logged. Aggregate statements are built from user
--- content — n-gram tokens and window titles are interpolated straight into them —
--- so echoing the first 200 characters put typed text and window titles into the
--- 14-day unified log. Every other diagnostic in this subsystem is careful about
--- exactly this: notify_synthetic logs only a source type and counts, the context
--- tracker logs only the app name, and the expander deliberately withholds a
--- private trigger and replacement. This one call site was the exception, because
--- it was written for developer convenience without classifying its payload.
--- The table name plus the driver's own message is what a reader actually needs.
---
--- The name is derived from the statement rather than threaded through all
--- nineteen call sites, for two reasons: an extra argument is exactly the kind of
--- parameter one site forgets, and the pattern below can only ever yield a bare
--- SQL identifier ([%w_]+), so this diagnostic is structurally incapable of
--- carrying user content no matter what a future statement interpolates.
--- @param sql string The statement to execute.
--- @return boolean True on success; false when the db is unavailable or the
--- statement failed (the row's caller must NOT drop its batch delta on false —
--- see F-MED-2: a dropped delta here is unrecoverable, the source keystrokes
--- are never replayed).
local function exec(sql)
	local db = SqliteWriter.get_db()
	if not db then return false end
	local rc = db:exec(sql)
	if rc ~= sqlite3.OK then
		local target = sql:match("INSERT%s+INTO%s+([%w_]+)")
			or sql:match("INSERT%s+OR%s+%u+%s+INTO%s+([%w_]+)")
			or sql:match("UPDATE%s+([%w_]+)")
			or sql:match("DELETE%s+FROM%s+([%w_]+)")
			or "?"
		Logger.error(LOG, "exec failed on '%s': %s.", target, db:errmsg() or "?")
		return false
	end
	return true
end

local function json_lit(tbl)
	if type(tbl) ~= "table" then return "'{}'" end
	local ok, s = pcall(json.encode, tbl)
	if not ok then return "'{}'" end
	return "'" .. (s:gsub("'", "''")) .. "'"
end

local NUMBER_MAP_JSON_COLUMNS = {
	esrc_json = true,
	e_buckets_json = true,
	length_buckets_json = true,
}

--- Builds a SQLite expression that merges an incoming JSON number map into the
--- stored map by summing every key present in the current batch delta.
---
--- These maps are per-tick deltas: every successful flush deletes the batch row.
--- Assigning `excluded.<column>` therefore leaves only the latest window while
--- the scalar totals keep accumulating and make the loss hard to notice.
---
--- MIRRORS the Windows driver's KLW_EsrcMergeExpr (keylogger_walker_sql.ahk),
--- generalized to every number-map distribution owned by this writer.
--- @param column string One of NUMBER_MAP_JSON_COLUMNS.
--- @param delta table|nil The per-tick number-map delta.
--- @return string A SQL expression usable as the column assignment.
local function number_map_merge_expr(column, delta)
	if not NUMBER_MAP_JSON_COLUMNS[column] then
		error("unsupported JSON number-map column: " .. tostring(column))
	end
	if type(delta) ~= "table" or next(delta) == nil then
		return string.format("COALESCE(%s,'{}')", column)
	end
	local parts = { string.format("json_set(COALESCE(%s,'{}')", column) }
	for k in pairs(delta) do
		-- The result is spliced into a string.format template, so "%" must be
		-- doubled as well as the SQL quote escaped.
		local path = "$." .. tostring(k):gsub("'", "''"):gsub("%%", "%%%%")
		parts[#parts + 1] = string.format(
			",'%s',COALESCE(json_extract(%s,'%s'),0)+COALESCE(json_extract(excluded.%s,'%s'),0)",
			path, column, path, column, path)
	end
	parts[#parts + 1] = ")"
	return table.concat(parts)
end

--- Builds the bounded append expression for the session-duration JSON array.
--- Stored samples come first, so once the shared cap is reached later flushes
--- cannot displace earlier samples and every driver observes the same bound.
--- @return string A SQL expression usable as the durations_json assignment.
local function session_durations_merge_expr()
	return "(SELECT json_group_array(duration) FROM ("
		.. "SELECT value AS duration FROM json_each(COALESCE(durations_json,'[]')) "
		.. "UNION ALL SELECT value FROM json_each(COALESCE(excluded.durations_json,'[]')) "
		.. "LIMIT " .. AggHelper.SESSION_DURATIONS_CAP .. "))"
end

local function sq(s)
	return "'" .. tostring(s):gsub("'", "''") .. "'"
end

local function i(n)
	return math.floor(tonumber(n) or 0)
end





-- =================================
-- =================================
-- ======= 2/ Batch DB Flush =======
-- =================================
-- =================================

--- Flush all pending batch deltas into SQLite aggregate tables.
--- Must be called inside an open transaction managed by the caller.
---
--- F-MED-2: exec() failures (a broken statement, a disk-full write, a schema
--- mismatch) used to be logged and then silently discarded — the caller
--- cleared the ENTIRE batch unconditionally afterwards regardless of which
--- rows actually committed. A single failed row (e.g. a locked db during one
--- tick) permanently lost that row's aggregate delta; the source keystrokes
--- are never replayed, so the data is gone forever with only a log line as
--- evidence. Every "for _, row in pairs(S.agg_batch.X)" loop below now
--- deletes ONLY the rows that succeeded (safe: Lua explicitly allows setting
--- the current iteration key to nil inside pairs()); rows whose exec() call
--- failed are left in S.agg_batch.X so the very next flush() tick retries
--- them with the row's already-accumulated totals intact.
function M.flush()
	if not C.require_init("flush") then return end
	if not S.agg_batch then return end
	local db = SqliteWriter.get_db()
	if not db then return end
	local d = sq(S.device_id)

	for key, row in pairs(S.agg_batch.app_day) do
		local cat = Export.get_native_app_category(row.app)
		local ok = exec(string.format(
			"INSERT INTO agg_app_day (device_id, date, app, chars, pauses, time_ms, think_time_ms, hs_chars, llm_chars, hs_triggers, llm_triggers, hs_suggested, llm_suggested, hs_input_chars, llm_input_chars, category) "
			.. "VALUES (%s,%s,%s,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%s) "
			.. "ON CONFLICT(device_id, date, app) DO UPDATE SET "
			.. "chars=chars+excluded.chars,pauses=pauses+excluded.pauses,"
			.. "time_ms=time_ms+excluded.time_ms,think_time_ms=think_time_ms+excluded.think_time_ms,"
			.. "hs_chars=hs_chars+excluded.hs_chars,llm_chars=llm_chars+excluded.llm_chars,"
			.. "hs_triggers=hs_triggers+excluded.hs_triggers,llm_triggers=llm_triggers+excluded.llm_triggers,"
			.. "hs_suggested=hs_suggested+excluded.hs_suggested,llm_suggested=llm_suggested+excluded.llm_suggested,"
			.. "hs_input_chars=hs_input_chars+excluded.hs_input_chars,"
			.. "llm_input_chars=llm_input_chars+excluded.llm_input_chars,"
			.. "category=COALESCE(agg_app_day.category, excluded.category)",
			d, sq(row.date), sq(row.app),
			i(row.chars), i(row.pauses), i(row.time_ms), i(row.think_time_ms),
			i(row.hs_chars), i(row.llm_chars),
			i(row.hs_triggers), i(row.llm_triggers),
			i(row.hs_suggested), i(row.llm_suggested),
			i(row.hs_input_chars), i(row.llm_input_chars), sq(cat)))
		if ok then S.agg_batch.app_day[key] = nil end
	end

	for key, row in pairs(S.agg_batch.app_time) do
		local cat = Export.get_native_app_category(row.app)
		local ok = exec(string.format(
			"INSERT INTO agg_app_day (device_id, date, app, app_time_ms, category) VALUES (%s,%s,%s,%d,%s) "
			.. "ON CONFLICT(device_id, date, app) DO UPDATE SET "
			.. "app_time_ms=app_time_ms+excluded.app_time_ms,"
			.. "category=COALESCE(agg_app_day.category, excluded.category)",
			d, sq(row.date), sq(row.app), i(row.ms), sq(cat)))
		if ok then S.agg_batch.app_time[key] = nil end
	end

	for key, row in pairs(S.agg_batch.app_buckets) do
		local ok = exec(string.format(
			"INSERT INTO agg_app_day_buckets (device_id, date, app, bucket_ms, time_sum, credited, hs_input_time_sum, hs_input_credited, llm_input_time_sum, llm_input_credited) VALUES (%s,%s,%s,%d,%d,%d,%d,%d,%d,%d) "
			.. "ON CONFLICT(device_id, date, app, bucket_ms) DO UPDATE SET "
			.. "time_sum=time_sum+excluded.time_sum,credited=credited+excluded.credited,"
			.. "hs_input_time_sum=hs_input_time_sum+excluded.hs_input_time_sum,"
			.. "hs_input_credited=hs_input_credited+excluded.hs_input_credited,"
			.. "llm_input_time_sum=llm_input_time_sum+excluded.llm_input_time_sum,"
			.. "llm_input_credited=llm_input_credited+excluded.llm_input_credited",
			d, sq(row.date), sq(row.app), i(row.bucket_ms),
			i(row.time_sum), i(row.credited),
			i(row.hs_in_t), i(row.hs_in_c), i(row.llm_in_t), i(row.llm_in_c)))
		if ok then S.agg_batch.app_buckets[key] = nil end
	end

	for tbl_name, tbl in pairs(S.agg_batch.ngram) do
		for key, item in pairs(tbl) do
			local s, e = key:find("\1")
			local date_str = key:sub(1, s - 1)
			local rest = key:sub(e + 1)
			local s2, e2 = rest:find("\1")
			local app = rest:sub(1, s2 - 1)
			local token = rest:sub(e2 + 1)
			local ok = exec(string.format(
				"INSERT INTO %s (device_id, date, app, token, c, td, cd, e, esrc_json) VALUES (%s,%s,%s,%s,%d,%d,%d,%d,%s) "
				.. "ON CONFLICT(device_id, date, app, token) DO UPDATE SET "
				.. "c=c+excluded.c, td=td+excluded.td, cd=cd+excluded.cd, e=e+excluded.e, "
				.. "esrc_json=" .. number_map_merge_expr("esrc_json", item.esrc),
				tbl_name, d, sq(date_str), sq(app), sq(token),
				i(item.c), i(item.td), i(item.cd), i(item.e),
				json_lit(item.esrc)))
			if ok then tbl[key] = nil end
		end
	end

	for key, row in pairs(S.agg_batch.kc_ngram) do
		local ok = exec(string.format(
			"INSERT INTO ngram_keycodes (device_id, date, app, keycode, c) VALUES (%s,%s,%s,%d,%d) "
			.. "ON CONFLICT(device_id, date, app, keycode) DO UPDATE SET c=c+excluded.c",
			d, sq(row.date), sq(row.app), i(row.keycode), i(row.count)))
		if ok then S.agg_batch.kc_ngram[key] = nil end
	end

	for tbl_name, tbl in pairs(S.agg_batch.sc_ngram) do
		for key, row in pairs(tbl) do
			local ok = exec(string.format(
				"INSERT INTO %s (device_id, date, app, token, c) VALUES (%s,%s,%s,%s,%d) "
				.. "ON CONFLICT(device_id, date, app, token) DO UPDATE SET c=c+excluded.c",
				tbl_name, d, sq(row.date), sq(row.app), sq(row.token), i(row.count)))
			if ok then tbl[key] = nil end
		end
	end

	for key, row in pairs(S.agg_batch.kc_hold) do
		local ok = exec(string.format(
			"INSERT INTO agg_app_day_kc_hold (device_id, date, app, keycode, sum_ms, count, max_ms, tap_count, hold_count) VALUES (%s,%s,%s,%d,%d,%d,%d,%d,%d) "
			.. "ON CONFLICT(device_id, date, app, keycode) DO UPDATE SET "
			.. "sum_ms=sum_ms+excluded.sum_ms,count=count+excluded.count,"
			.. "max_ms=MAX(max_ms, excluded.max_ms),"
			.. "tap_count=tap_count+excluded.tap_count,hold_count=hold_count+excluded.hold_count",
			d, sq(row.date), sq(row.app), i(row.keycode),
			i(row.sum_ms), i(row.count), i(row.max_ms), i(row.tap_count), i(row.hold_count)))
		if ok then S.agg_batch.kc_hold[key] = nil end
	end

	-- Title-cap cleanup (DELETE ... NOT IN LIMIT N) must run against the FULL
	-- set of app-day keys queued this tick, before any successful title row is
	-- removed below — otherwise an app-day whose titles all inserted cleanly
	-- would never get its cleanup DELETE and the table would grow unbounded.
	local title_app_days_seen = {}
	for key in pairs(S.agg_batch.titles) do
		local s, e = key:find("\1")
		local rest = key:sub(e + 1)
		local s2, e2 = rest:find("\1")
		local date_str = key:sub(1, s - 1)
		local app = rest:sub(1, s2 - 1)
		title_app_days_seen[date_str .. "\1" .. app] = { date = date_str, app = app }
	end
	local title_cleanup_ok = {}
	for ad_key, ad in pairs(title_app_days_seen) do
		title_cleanup_ok[ad_key] = exec(string.format(
			"DELETE FROM agg_app_day_titles WHERE device_id=%s AND date=%s AND app=%s AND title NOT IN ("
			.. "SELECT title FROM agg_app_day_titles WHERE device_id=%s AND date=%s AND app=%s "
			.. "ORDER BY (c + ms) DESC LIMIT %d)",
			d, sq(ad.date), sq(ad.app), d, sq(ad.date), sq(ad.app), C.TITLE_CAP_PER_APP_DAY))
	end
	for key, row in pairs(S.agg_batch.titles) do
		local ok = exec(string.format(
			"INSERT INTO agg_app_day_titles (device_id, date, app, title, c, ms) VALUES (%s,%s,%s,%s,%d,%d) "
			.. "ON CONFLICT(device_id, date, app, title) DO UPDATE SET c=c+excluded.c, ms=ms+excluded.ms",
			d, sq(row.date), sq(row.app), sq(row.title), i(row.c), i(row.ms)))
		-- Only drop the row once BOTH the insert and this app-day's cleanup
		-- DELETE succeeded — otherwise a failed cleanup would silently stop
		-- enforcing the per-app-day title cap for this row's app-day forever.
		local ad_key = row.date .. "\1" .. row.app
		if ok and title_cleanup_ok[ad_key] then
			S.agg_batch.titles[key] = nil
		end
	end

	for key, row in pairs(S.agg_batch.hourly) do
		local ok = exec(string.format(
			"INSERT INTO agg_app_day_hourly (device_id, date, app, hour, c, e, em, es, e_buckets_json) VALUES (%s,%s,%s,%s,%d,%d,%d,%d,%s) "
			.. "ON CONFLICT(device_id, date, app, hour) DO UPDATE SET "
			.. "c=c+excluded.c, e=e+excluded.e, em=em+excluded.em, es=es+excluded.es, "
			.. "e_buckets_json=" .. number_map_merge_expr("e_buckets_json", row.e_buckets),
			d, sq(row.date), sq(row.app), sq(row.hour),
			i(row.c), i(row.e), i(row.em), i(row.es), json_lit(row.e_buckets)))
		if ok then S.agg_batch.hourly[key] = nil end
	end

	for key, row in pairs(S.agg_batch.hourly_min5) do
		local ok = exec(string.format(
			"INSERT INTO agg_app_day_hourly_min5 (device_id, date, app, slot, c, e, es, e_buckets_json) VALUES (%s,%s,%s,%s,%d,%d,%d,%s) "
			.. "ON CONFLICT(device_id, date, app, slot) DO UPDATE SET "
			.. "c=c+excluded.c, e=e+excluded.e, es=es+excluded.es, "
			.. "e_buckets_json=" .. number_map_merge_expr("e_buckets_json", row.e_buckets),
			d, sq(row.date), sq(row.app), sq(row.slot),
			i(row.c), i(row.e), i(row.es), json_lit(row.e_buckets)))
		if ok then S.agg_batch.hourly_min5[key] = nil end
	end

	for key, row in pairs(S.agg_batch.layouts) do
		local ok = exec(string.format(
			"INSERT INTO agg_app_day_layouts (device_id, date, app, layout, count) VALUES (%s,%s,%s,%s,%d) "
			.. "ON CONFLICT(device_id, date, app, layout) DO UPDATE SET count=count+excluded.count",
			d, sq(row.date), sq(row.app), sq(row.layout), i(row.count)))
		if ok then S.agg_batch.layouts[key] = nil end
	end

	for key, row in pairs(S.agg_batch.chars_class) do
		local ok = exec(string.format(
			"INSERT INTO agg_app_day_chars_class (device_id, date, app, letter, digit, punct, space, other, first_typed_min, last_typed_min) VALUES (%s,%s,%s,%d,%d,%d,%d,%d,%s,%s) "
			.. "ON CONFLICT(device_id, date, app) DO UPDATE SET "
			.. "letter=letter+excluded.letter,digit=digit+excluded.digit,"
			.. "punct=punct+excluded.punct,space=space+excluded.space,other=other+excluded.other,"
			.. "first_typed_min=COALESCE(agg_app_day_chars_class.first_typed_min, excluded.first_typed_min),"
			.. "last_typed_min=COALESCE(excluded.last_typed_min, agg_app_day_chars_class.last_typed_min)",
			d, sq(row.date), sq(row.app),
			i(row.letter), i(row.digit), i(row.punct), i(row.space), i(row.other),
			row.first_typed_min and sq(row.first_typed_min) or "NULL",
			row.last_typed_min  and sq(row.last_typed_min)  or "NULL"))
		if ok then S.agg_batch.chars_class[key] = nil end
	end

	for key, row in pairs(S.agg_batch.errors) do
		local ok = exec(string.format(
			"INSERT INTO agg_app_day_errors (device_id, date, app, bs_total, cascade_count, cascade_max_len, recovery_sum_ms, recovery_count) VALUES (%s,%s,%s,%d,%d,%d,%d,%d) "
			.. "ON CONFLICT(device_id, date, app) DO UPDATE SET "
			.. "bs_total=bs_total+excluded.bs_total,cascade_count=cascade_count+excluded.cascade_count,"
			.. "cascade_max_len=MAX(cascade_max_len, excluded.cascade_max_len),"
			.. "recovery_sum_ms=recovery_sum_ms+excluded.recovery_sum_ms,"
			.. "recovery_count=recovery_count+excluded.recovery_count",
			d, sq(row.date), sq(row.app),
			i(row.bs_total), i(row.cascade_count), i(row.cascade_max_len),
			i(row.recovery_sum_ms), i(row.recovery_count)))
		if ok then S.agg_batch.errors[key] = nil end
	end

	for key, row in pairs(S.agg_batch.ergo) do
		local ok = exec(string.format(
			"INSERT INTO agg_app_day_ergo (device_id, date, app, same_finger_streak_max, same_hand_streak_max, auto_repeat_count, focus_to_first_key_sum_ms, focus_to_first_key_count) VALUES (%s,%s,%s,%d,%d,%d,%d,%d) "
			.. "ON CONFLICT(device_id, date, app) DO UPDATE SET "
			.. "same_finger_streak_max=MAX(same_finger_streak_max, excluded.same_finger_streak_max),"
			.. "same_hand_streak_max=MAX(same_hand_streak_max, excluded.same_hand_streak_max),"
			.. "auto_repeat_count=auto_repeat_count+excluded.auto_repeat_count,"
			.. "focus_to_first_key_sum_ms=focus_to_first_key_sum_ms+excluded.focus_to_first_key_sum_ms,"
			.. "focus_to_first_key_count=focus_to_first_key_count+excluded.focus_to_first_key_count",
			d, sq(row.date), sq(row.app),
			i(row.same_finger_streak_max), i(row.same_hand_streak_max), i(row.auto_repeat_count),
			i(row.focus_to_first_key_sum_ms), i(row.focus_to_first_key_count)))
		if ok then S.agg_batch.ergo[key] = nil end
	end

	for key, row in pairs(S.agg_batch.bursts) do
		local ok = exec(string.format(
			"INSERT INTO agg_app_day_burst (device_id, date, app, count_total, max_cpm, max_chars, length_buckets_json, inter_delay_count, inter_delay_sum, inter_delay_sumsq) VALUES (%s,%s,%s,%d,%f,%d,%s,%d,%d,%d) "
			.. "ON CONFLICT(device_id, date, app) DO UPDATE SET "
			.. "count_total=count_total+excluded.count_total,"
			.. "max_cpm=MAX(max_cpm, excluded.max_cpm),max_chars=MAX(max_chars, excluded.max_chars),"
			.. "length_buckets_json=" .. number_map_merge_expr("length_buckets_json", row.length_buckets) .. ","
			.. "inter_delay_count=inter_delay_count+excluded.inter_delay_count,"
			.. "inter_delay_sum=inter_delay_sum+excluded.inter_delay_sum,"
			.. "inter_delay_sumsq=inter_delay_sumsq+excluded.inter_delay_sumsq",
			d, sq(row.date), sq(row.app),
			i(row.count_total), row.max_cpm, i(row.max_chars),
			json_lit(row.length_buckets),
			i(row.inter_count), i(row.inter_sum), i(row.inter_sumsq)))
		if ok then S.agg_batch.bursts[key] = nil end
	end

	for key, row in pairs(S.agg_batch.sessions) do
		local ok = exec(string.format(
			"INSERT INTO agg_app_day_session (device_id, date, app, count_total, longest_ms, longest_chars, total_active_ms, durations_json) VALUES (%s,%s,%s,%d,%d,%d,%d,%s) "
			.. "ON CONFLICT(device_id, date, app) DO UPDATE SET "
			.. "count_total=count_total+excluded.count_total,"
			.. "longest_ms=MAX(longest_ms, excluded.longest_ms),"
			.. "longest_chars=MAX(longest_chars, excluded.longest_chars),"
			.. "total_active_ms=total_active_ms+excluded.total_active_ms,"
			.. "durations_json=" .. session_durations_merge_expr(),
			d, sq(row.date), sq(row.app),
			i(row.count_total), i(row.longest_ms), i(row.longest_chars), i(row.total_active_ms),
			json_lit(row.durations)))
		if ok then S.agg_batch.sessions[key] = nil end
	end

	for key, row in pairs(S.agg_batch.switches_to) do
		local ok = exec(string.format(
			"INSERT INTO agg_app_day_switches_to (device_id, date, app_from, app_to, count) VALUES (%s,%s,%s,%s,%d) "
			.. "ON CONFLICT(device_id, date, app_from, app_to) DO UPDATE SET count=count+excluded.count",
			d, sq(row.date), sq(row.app_from), sq(row.app_to), i(row.count)))
		if ok then S.agg_batch.switches_to[key] = nil end
	end

	for key, row in pairs(S.agg_batch.system_day) do
		local ok = exec(string.format(
			"INSERT INTO agg_system_day (device_id, date, wifi_changes, space_switches, audio_muted_ms, locked_ms, sleep_ms, awake_ms, passive_count, night_wake_count) VALUES (%s,%s,%d,%d,%d,%d,%d,%d,%d,%d) "
			.. "ON CONFLICT(device_id, date) DO UPDATE SET "
			.. "wifi_changes=wifi_changes+excluded.wifi_changes,"
			.. "space_switches=space_switches+excluded.space_switches,"
			.. "audio_muted_ms=audio_muted_ms+excluded.audio_muted_ms,"
			.. "locked_ms=locked_ms+excluded.locked_ms,sleep_ms=sleep_ms+excluded.sleep_ms,"
			.. "awake_ms=awake_ms+excluded.awake_ms,"
			.. "passive_count=passive_count+excluded.passive_count,"
			.. "night_wake_count=night_wake_count+excluded.night_wake_count",
			d, sq(row.date), i(row.wifi_changes), i(row.space_switches),
			i(row.audio_muted_ms), i(row.locked_ms), i(row.sleep_ms), i(row.awake_ms),
			i(row.passive_count), i(row.night_wake_count)))
		if ok then S.agg_batch.system_day[key] = nil end
	end
	return not C.has_pending_batch()
end

return M
