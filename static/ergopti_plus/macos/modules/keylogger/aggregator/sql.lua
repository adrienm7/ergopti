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
local Logger  = require("lib.logger")
local LOG     = "keylogger.aggregator"

local SqliteWriter = require("modules.keylogger.sqlite_writer")
local Export       = require("modules.keylogger.export")

local S = require("modules.keylogger.aggregator.state")
local C = require("modules.keylogger.aggregator.core")





-- ================================
-- ==============================
-- ======= 1/ SQL Helpers =======
-- ==============================
-- ================================

--- Execute a SQL statement against the open db; log on failure.
local function exec(sql)
	local db = SqliteWriter.get_db()
	if not db then return end
	local rc = db:exec(sql)
	if rc ~= sqlite3.OK then
		Logger.error(LOG, "exec failed: %s — %s.", db:errmsg() or "?", sql:sub(1, 200))
	end
end

local function json_lit(tbl)
	if type(tbl) ~= "table" then return "'{}'" end
	local ok, s = pcall(json.encode, tbl)
	if not ok then return "'{}'" end
	return "'" .. (s:gsub("'", "''")) .. "'"
end

local function sq(s)
	return "'" .. tostring(s):gsub("'", "''") .. "'"
end

local function i(n)
	return math.floor(tonumber(n) or 0)
end





-- ===================================
-- =================================
-- ======= 2/ Batch DB Flush =======
-- =================================
-- ===================================

--- Flush all pending batch deltas into SQLite aggregate tables.
--- Must be called inside an open transaction managed by the caller.
function M.flush()
	if not C.require_init("flush") then return end
	if not S.agg_batch then return end
	local db = SqliteWriter.get_db()
	if not db then return end
	local d = sq(S.device_id)

	for _, row in pairs(S.agg_batch.app_day) do
		local cat = Export.get_native_app_category(row.app)
		exec(string.format(
			"INSERT INTO agg_app_day (device_id, date, app, chars, pauses, time_ms, think_time_ms, hs_chars, llm_chars, hs_triggers, llm_triggers, hs_input_chars, llm_input_chars, category) "
			.. "VALUES (%s,%s,%s,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%s) "
			.. "ON CONFLICT(device_id, date, app) DO UPDATE SET "
			.. "chars=chars+excluded.chars,pauses=pauses+excluded.pauses,"
			.. "time_ms=time_ms+excluded.time_ms,think_time_ms=think_time_ms+excluded.think_time_ms,"
			.. "hs_chars=hs_chars+excluded.hs_chars,llm_chars=llm_chars+excluded.llm_chars,"
			.. "hs_triggers=hs_triggers+excluded.hs_triggers,llm_triggers=llm_triggers+excluded.llm_triggers,"
			.. "hs_input_chars=hs_input_chars+excluded.hs_input_chars,"
			.. "llm_input_chars=llm_input_chars+excluded.llm_input_chars,"
			.. "category=COALESCE(agg_app_day.category, excluded.category)",
			d, sq(row.date), sq(row.app),
			i(row.chars), i(row.pauses), i(row.time_ms), i(row.think_time_ms),
			i(row.hs_chars), i(row.llm_chars),
			i(row.hs_triggers), i(row.llm_triggers),
			i(row.hs_input_chars), i(row.llm_input_chars), sq(cat)))
	end

	for _, row in pairs(S.agg_batch.app_time) do
		local cat = Export.get_native_app_category(row.app)
		exec(string.format(
			"INSERT INTO agg_app_day (device_id, date, app, app_time_ms, category) VALUES (%s,%s,%s,%d,%s) "
			.. "ON CONFLICT(device_id, date, app) DO UPDATE SET "
			.. "app_time_ms=app_time_ms+excluded.app_time_ms,"
			.. "category=COALESCE(agg_app_day.category, excluded.category)",
			d, sq(row.date), sq(row.app), i(row.ms), sq(cat)))
	end

	for _, row in pairs(S.agg_batch.app_buckets) do
		exec(string.format(
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
	end

	for tbl_name, tbl in pairs(S.agg_batch.ngram) do
		for key, item in pairs(tbl) do
			local s, e = key:find("\1")
			local date_str = key:sub(1, s - 1)
			local rest = key:sub(e + 1)
			local s2, e2 = rest:find("\1")
			local app = rest:sub(1, s2 - 1)
			local token = rest:sub(e2 + 1)
			exec(string.format(
				"INSERT INTO %s (device_id, date, app, token, c, td, cd, e, esrc_json) VALUES (%s,%s,%s,%s,%d,%d,%d,%d,%s) "
				.. "ON CONFLICT(device_id, date, app, token) DO UPDATE SET "
				.. "c=c+excluded.c, td=td+excluded.td, cd=cd+excluded.cd, e=e+excluded.e, "
				.. "esrc_json=excluded.esrc_json",
				tbl_name, d, sq(date_str), sq(app), sq(token),
				i(item.c), i(item.td), i(item.cd), i(item.e),
				json_lit(item.esrc)))
		end
	end

	for _, row in pairs(S.agg_batch.kc_ngram) do
		exec(string.format(
			"INSERT INTO ngram_keycodes (device_id, date, app, keycode, c) VALUES (%s,%s,%s,%d,%d) "
			.. "ON CONFLICT(device_id, date, app, keycode) DO UPDATE SET c=c+excluded.c",
			d, sq(row.date), sq(row.app), i(row.keycode), i(row.count)))
	end

	for tbl_name, tbl in pairs(S.agg_batch.sc_ngram) do
		for _, row in pairs(tbl) do
			exec(string.format(
				"INSERT INTO %s (device_id, date, app, token, c) VALUES (%s,%s,%s,%s,%d) "
				.. "ON CONFLICT(device_id, date, app, token) DO UPDATE SET c=c+excluded.c",
				tbl_name, d, sq(row.date), sq(row.app), sq(row.token), i(row.count)))
		end
	end

	for _, row in pairs(S.agg_batch.kc_hold) do
		exec(string.format(
			"INSERT INTO agg_app_day_kc_hold (device_id, date, app, keycode, sum_ms, count, max_ms, tap_count, hold_count) VALUES (%s,%s,%s,%d,%d,%d,%d,%d,%d) "
			.. "ON CONFLICT(device_id, date, app, keycode) DO UPDATE SET "
			.. "sum_ms=sum_ms+excluded.sum_ms,count=count+excluded.count,"
			.. "max_ms=MAX(max_ms, excluded.max_ms),"
			.. "tap_count=tap_count+excluded.tap_count,hold_count=hold_count+excluded.hold_count",
			d, sq(row.date), sq(row.app), i(row.keycode),
			i(row.sum_ms), i(row.count), i(row.max_ms), i(row.tap_count), i(row.hold_count)))
	end

	for _, row in pairs(S.agg_batch.titles) do
		exec(string.format(
			"INSERT INTO agg_app_day_titles (device_id, date, app, title, c, ms) VALUES (%s,%s,%s,%s,%d,%d) "
			.. "ON CONFLICT(device_id, date, app, title) DO UPDATE SET c=c+excluded.c, ms=ms+excluded.ms",
			d, sq(row.date), sq(row.app), sq(row.title), i(row.c), i(row.ms)))
	end
	for key, _ in pairs(S.agg_batch.titles) do
		local s, e = key:find("\1")
		local rest = key:sub(e + 1)
		local s2, e2 = rest:find("\1")
		local date_str = key:sub(1, s - 1)
		local app = rest:sub(1, s2 - 1)
		exec(string.format(
			"DELETE FROM agg_app_day_titles WHERE device_id=%s AND date=%s AND app=%s AND title NOT IN ("
			.. "SELECT title FROM agg_app_day_titles WHERE device_id=%s AND date=%s AND app=%s "
			.. "ORDER BY (c + ms) DESC LIMIT %d)",
			d, sq(date_str), sq(app), d, sq(date_str), sq(app), C.TITLE_CAP_PER_APP_DAY))
	end

	for _, row in pairs(S.agg_batch.hourly) do
		exec(string.format(
			"INSERT INTO agg_app_day_hourly (device_id, date, app, hour, c, e, em, es, e_buckets_json) VALUES (%s,%s,%s,%s,%d,%d,%d,%d,%s) "
			.. "ON CONFLICT(device_id, date, app, hour) DO UPDATE SET "
			.. "c=c+excluded.c, e=e+excluded.e, em=em+excluded.em, es=es+excluded.es, "
			.. "e_buckets_json=excluded.e_buckets_json",
			d, sq(row.date), sq(row.app), sq(row.hour),
			i(row.c), i(row.e), i(row.em), i(row.es), json_lit(row.e_buckets)))
	end

	for _, row in pairs(S.agg_batch.hourly_min5) do
		exec(string.format(
			"INSERT INTO agg_app_day_hourly_min5 (device_id, date, app, slot, c, e, es, e_buckets_json) VALUES (%s,%s,%s,%s,%d,%d,%d,%s) "
			.. "ON CONFLICT(device_id, date, app, slot) DO UPDATE SET "
			.. "c=c+excluded.c, e=e+excluded.e, es=es+excluded.es, "
			.. "e_buckets_json=excluded.e_buckets_json",
			d, sq(row.date), sq(row.app), sq(row.slot),
			i(row.c), i(row.e), i(row.es), json_lit(row.e_buckets)))
	end

	for _, row in pairs(S.agg_batch.layouts) do
		exec(string.format(
			"INSERT INTO agg_app_day_layouts (device_id, date, app, layout, count) VALUES (%s,%s,%s,%s,%d) "
			.. "ON CONFLICT(device_id, date, app, layout) DO UPDATE SET count=count+excluded.count",
			d, sq(row.date), sq(row.app), sq(row.layout), i(row.count)))
	end

	for _, row in pairs(S.agg_batch.chars_class) do
		exec(string.format(
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
	end

	for _, row in pairs(S.agg_batch.errors) do
		exec(string.format(
			"INSERT INTO agg_app_day_errors (device_id, date, app, bs_total, cascade_count, cascade_max_len, recovery_sum_ms, recovery_count) VALUES (%s,%s,%s,%d,%d,%d,%d,%d) "
			.. "ON CONFLICT(device_id, date, app) DO UPDATE SET "
			.. "bs_total=bs_total+excluded.bs_total,cascade_count=cascade_count+excluded.cascade_count,"
			.. "cascade_max_len=MAX(cascade_max_len, excluded.cascade_max_len),"
			.. "recovery_sum_ms=recovery_sum_ms+excluded.recovery_sum_ms,"
			.. "recovery_count=recovery_count+excluded.recovery_count",
			d, sq(row.date), sq(row.app),
			i(row.bs_total), i(row.cascade_count), i(row.cascade_max_len),
			i(row.recovery_sum_ms), i(row.recovery_count)))
	end

	for _, row in pairs(S.agg_batch.ergo) do
		exec(string.format(
			"INSERT INTO agg_app_day_ergo (device_id, date, app, same_finger_streak_max, same_hand_streak_max, auto_repeat_count) VALUES (%s,%s,%s,%d,%d,%d) "
			.. "ON CONFLICT(device_id, date, app) DO UPDATE SET "
			.. "same_finger_streak_max=MAX(same_finger_streak_max, excluded.same_finger_streak_max),"
			.. "same_hand_streak_max=MAX(same_hand_streak_max, excluded.same_hand_streak_max),"
			.. "auto_repeat_count=auto_repeat_count+excluded.auto_repeat_count",
			d, sq(row.date), sq(row.app),
			i(row.same_finger_streak_max), i(row.same_hand_streak_max), i(row.auto_repeat_count)))
	end

	for _, row in pairs(S.agg_batch.bursts) do
		exec(string.format(
			"INSERT INTO agg_app_day_burst (device_id, date, app, count_total, max_cpm, max_chars, length_buckets_json, inter_delay_count, inter_delay_sum, inter_delay_sumsq) VALUES (%s,%s,%s,%d,%f,%d,%s,%d,%d,%d) "
			.. "ON CONFLICT(device_id, date, app) DO UPDATE SET "
			.. "count_total=count_total+excluded.count_total,"
			.. "max_cpm=MAX(max_cpm, excluded.max_cpm),max_chars=MAX(max_chars, excluded.max_chars),"
			.. "length_buckets_json=excluded.length_buckets_json,"
			.. "inter_delay_count=inter_delay_count+excluded.inter_delay_count,"
			.. "inter_delay_sum=inter_delay_sum+excluded.inter_delay_sum,"
			.. "inter_delay_sumsq=inter_delay_sumsq+excluded.inter_delay_sumsq",
			d, sq(row.date), sq(row.app),
			i(row.count_total), row.max_cpm, i(row.max_chars),
			json_lit(row.length_buckets),
			i(row.inter_count), i(row.inter_sum), i(row.inter_sumsq)))
	end

	for _, row in pairs(S.agg_batch.sessions) do
		exec(string.format(
			"INSERT INTO agg_app_day_session (device_id, date, app, count_total, longest_ms, longest_chars, total_active_ms, durations_json) VALUES (%s,%s,%s,%d,%d,%d,%d,%s) "
			.. "ON CONFLICT(device_id, date, app) DO UPDATE SET "
			.. "count_total=count_total+excluded.count_total,"
			.. "longest_ms=MAX(longest_ms, excluded.longest_ms),"
			.. "longest_chars=MAX(longest_chars, excluded.longest_chars),"
			.. "total_active_ms=total_active_ms+excluded.total_active_ms,"
			.. "durations_json=excluded.durations_json",
			d, sq(row.date), sq(row.app),
			i(row.count_total), i(row.longest_ms), i(row.longest_chars), i(row.total_active_ms),
			json_lit(row.durations)))
	end

	for _, row in pairs(S.agg_batch.switches_to) do
		exec(string.format(
			"INSERT INTO agg_app_day_switches_to (device_id, date, app_from, app_to, count) VALUES (%s,%s,%s,%s,%d) "
			.. "ON CONFLICT(device_id, date, app_from, app_to) DO UPDATE SET count=count+excluded.count",
			d, sq(row.date), sq(row.app_from), sq(row.app_to), i(row.count)))
	end

	for _, row in pairs(S.agg_batch.system_day) do
		exec(string.format(
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
	end

	C.reset_batch()
end

return M
