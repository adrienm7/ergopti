--- modules/keystats/aggregator/sql.lua

--- ==============================================================================
--- MODULE: Aggregator SQL — Batch DB Flush
--- DESCRIPTION:
--- Drains the per-tick in-memory accumulator (S.agg_batch) into the SQLite
--- aggregate tables using ON CONFLICT … DO UPDATE (UPSERT) statements. All
--- writes are expected to run inside a transaction opened by the caller.
---
--- SQL helpers (exec, json_text, sq, i) are intentionally private to this
--- module — they are pure formatting utilities with no need for external access.
---
--- MIRRORS: windows/modules/keystats/keystats_walker_sql.ahk
--- ==============================================================================

local M = {}

local json    = require("hs.json")
local sqlite3 = require("hs.sqlite3")
local Logger  = require("infra.logger")
local LOG     = "keystats.aggregator"

local SqliteWriter = require("modules.keystats.sqlite_writer")
local Export       = require("modules.keystats.export")
local AggHelper    = require("keystats.aggregator_helpers")
local Literal      = require("sqlite.literal")
local Queries      = require("keystats.queries")

local S = require("modules.keystats.aggregator.state")
local C = require("modules.keystats.aggregator.core")





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

--- Encodes a number map or a list as the compact JSON text a statement stores.
--- @param value table|nil The map, or nil.
--- @return string The JSON text, "{}" for anything that is not a table or cannot be encoded.
local function json_text(value)
	if type(value) ~= "table" then return "{}" end
	local ok, encoded = pcall(json.encode, value)
	if not ok then return "{}" end
	return encoded
end

--- Quotes one SQL text literal through the shared C-string-safe encoder.
local function sq(s)
	return "'" .. Literal.escape(tostring(s)) .. "'"
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
		local ok = exec(Queries.render("agg.app_day", "native", {
			device_id = tostring(S.device_id), date = tostring(row.date), app = tostring(row.app),
			chars = i(row.chars), pauses = i(row.pauses), time_ms = i(row.time_ms),
			think_time_ms = i(row.think_time_ms), hs_chars = i(row.hs_chars), llm_chars = i(row.llm_chars),
			hs_triggers = i(row.hs_triggers), llm_triggers = i(row.llm_triggers),
			hs_suggested = i(row.hs_suggested), llm_suggested = i(row.llm_suggested),
			hs_input_chars = i(row.hs_input_chars), llm_input_chars = i(row.llm_input_chars),
			app_time_ms = 0, category = cat,
		}))
		if ok then S.agg_batch.app_day[key] = nil end
	end

	for key, row in pairs(S.agg_batch.app_time) do
		local cat = Export.get_native_app_category(row.app)
		local ok = exec(Queries.render("agg.app_day", "native", {
			device_id = tostring(S.device_id), date = tostring(row.date), app = tostring(row.app),
			chars = 0, pauses = 0, time_ms = 0, think_time_ms = 0, hs_chars = 0, llm_chars = 0,
			hs_triggers = 0, llm_triggers = 0, hs_suggested = 0, llm_suggested = 0,
			hs_input_chars = 0, llm_input_chars = 0, app_time_ms = i(row.ms), category = cat,
		}))
		if ok then S.agg_batch.app_time[key] = nil end
	end

	for key, row in pairs(S.agg_batch.app_buckets) do
		local ok = exec(Queries.render("agg.buckets", "native", {
			device_id = tostring(S.device_id), date = tostring(row.date), app = tostring(row.app),
			bucket_ms = i(row.bucket_ms), time_sum = i(row.time_sum), credited = i(row.credited),
			hs_input_time_sum = i(row.hs_in_t), hs_input_credited = i(row.hs_in_c),
			llm_input_time_sum = i(row.llm_in_t), llm_input_credited = i(row.llm_in_c),
		}))
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
			local ok = exec(Queries.render("agg.ngram", "native", {
				table = tbl_name, device_id = tostring(S.device_id), date = date_str, app = app, token = token,
				c = i(item.c), td = i(item.td), cd = i(item.cd), e = i(item.e),
				esrc_json = json_text(item.esrc),
			}))
			if ok then tbl[key] = nil end
		end
	end

	-- These unpositioned keys stay outside numeric heatmap/typing aggregates.
	require("keystats.media_store").flush(S.agg_batch, S.device_id, exec)

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
		local ok = exec(Queries.render("agg.kc_hold", "native", {
			device_id = tostring(S.device_id), date = tostring(row.date), app = tostring(row.app),
			keycode = i(row.keycode), sum_ms = i(row.sum_ms), count = i(row.count), max_ms = i(row.max_ms),
			tap_count = i(row.tap_count), hold_count = i(row.hold_count),
		}))
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
		title_cleanup_ok[ad_key] = exec(Queries.render("agg.title_prune", "native", {
			device_id = tostring(S.device_id), date = ad.date, app = ad.app,
			cap = C.TITLE_CAP_PER_APP_DAY,
		}))
	end
	for key, row in pairs(S.agg_batch.titles) do
		local ok = exec(Queries.render("agg.title", "native", {
			device_id = tostring(S.device_id), date = tostring(row.date), app = tostring(row.app),
			title = tostring(row.title), c = i(row.c), ms = i(row.ms),
		}))
		-- Only drop the row once BOTH the insert and this app-day's cleanup
		-- DELETE succeeded — otherwise a failed cleanup would silently stop
		-- enforcing the per-app-day title cap for this row's app-day forever.
		local ad_key = row.date .. "\1" .. row.app
		if ok and title_cleanup_ok[ad_key] then
			S.agg_batch.titles[key] = nil
		end
	end

	for key, row in pairs(S.agg_batch.hourly) do
		local ok = exec(Queries.render("agg.hourly", "native", {
			device_id = tostring(S.device_id), date = tostring(row.date), app = tostring(row.app),
			hour = tostring(row.hour), c = i(row.c), e = i(row.e), em = i(row.em), es = i(row.es),
			e_buckets_json = json_text(row.e_buckets),
		}))
		if ok then S.agg_batch.hourly[key] = nil end
	end

	for key, row in pairs(S.agg_batch.hourly_min5) do
		local ok = exec(Queries.render("agg.hourly_min5", "native", {
			device_id = tostring(S.device_id), date = tostring(row.date), app = tostring(row.app),
			slot = tostring(row.slot), c = i(row.c), e = i(row.e), es = i(row.es),
			e_buckets_json = json_text(row.e_buckets),
		}))
		if ok then S.agg_batch.hourly_min5[key] = nil end
	end

	for key, row in pairs(S.agg_batch.layouts) do
		local ok = exec(Queries.render("agg.layouts", "native", {
			device_id = tostring(S.device_id), date = tostring(row.date), app = tostring(row.app),
			layout = tostring(row.layout), count = i(row.count),
		}))
		if ok then S.agg_batch.layouts[key] = nil end
	end

	for key, row in pairs(S.agg_batch.chars_class) do
		local ok = exec(Queries.render("agg.chars_class", "native", {
			device_id = tostring(S.device_id), date = tostring(row.date), app = tostring(row.app),
			letter = i(row.letter), digit = i(row.digit), punct = i(row.punct), space = i(row.space),
			other = i(row.other),
			first_typed_min = row.first_typed_min and tostring(row.first_typed_min) or nil,
			last_typed_min = row.last_typed_min and tostring(row.last_typed_min) or nil,
		}))
		if ok then S.agg_batch.chars_class[key] = nil end
	end

	for key, row in pairs(S.agg_batch.errors) do
		local ok = exec(Queries.render("agg.errors", "native", {
			device_id = tostring(S.device_id), date = tostring(row.date), app = tostring(row.app),
			bs_total = i(row.bs_total), cascade_count = i(row.cascade_count),
			cascade_max_len = i(row.cascade_max_len), recovery_sum_ms = i(row.recovery_sum_ms),
			recovery_count = i(row.recovery_count),
		}))
		if ok then S.agg_batch.errors[key] = nil end
	end

	for key, row in pairs(S.agg_batch.ergo) do
		local ok = exec(Queries.render("agg.ergo", "native", {
			device_id = tostring(S.device_id), date = tostring(row.date), app = tostring(row.app),
			same_finger_streak_max = i(row.same_finger_streak_max),
			same_hand_streak_max = i(row.same_hand_streak_max), auto_repeat_count = i(row.auto_repeat_count),
			focus_to_first_key_sum_ms = i(row.focus_to_first_key_sum_ms),
			focus_to_first_key_count = i(row.focus_to_first_key_count),
		}))
		if ok then S.agg_batch.ergo[key] = nil end
	end

	for key, row in pairs(S.agg_batch.bursts) do
		local ok = exec(Queries.render("agg.burst", "native", {
			device_id = tostring(S.device_id), date = tostring(row.date), app = tostring(row.app),
			count_total = i(row.count_total), max_cpm = tonumber(row.max_cpm) or 0, max_chars = i(row.max_chars),
			length_buckets_json = json_text(row.length_buckets), inter_delay_count = i(row.inter_count),
			inter_delay_sum = i(row.inter_sum), inter_delay_sumsq = i(row.inter_sumsq),
		}))
		if ok then S.agg_batch.bursts[key] = nil end
	end

	for key, row in pairs(S.agg_batch.sessions) do
		local ok = exec(Queries.render("agg.session", "native", {
			device_id = tostring(S.device_id), date = tostring(row.date), app = tostring(row.app),
			count_total = i(row.count_total), longest_ms = i(row.longest_ms),
			longest_chars = i(row.longest_chars), total_active_ms = i(row.total_active_ms),
			durations_json = json_text(row.durations), duration_cap = AggHelper.SESSION_DURATIONS_CAP,
		}))
		if ok then S.agg_batch.sessions[key] = nil end
	end

	for key, row in pairs(S.agg_batch.switches_to) do
		local ok = exec(Queries.render("agg.switches_to", "native", {
			device_id = tostring(S.device_id), date = tostring(row.date),
			app_from = tostring(row.app_from), app_to = tostring(row.app_to), count = i(row.count),
		}))
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
