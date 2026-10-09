--- modules/keylogger/sqlite_reader.lua

--- ==============================================================================
--- MODULE: Keylogger SQLite Reader
--- DESCRIPTION:
--- Read-only projection layer that translates the new schema (agg_app_day,
--- agg_app_day_*, ngram_*) into the JSON shape historically consumed by the
--- metrics_apps and metrics_typing webview frontends. Lets the existing JS
--- code keep working while the storage backend has changed completely.
---
--- FEATURES & RATIONALE:
--- 1. Cross-device aggregation: rows from every `devices` row are summed by
---    (date, app) so the user sees a single global stat regardless of the
---    machine that produced it.
--- 2. View-cache aware: results computed for the "all-time → today" common
---    range are stored in `view_cache` so subsequent opens are instantaneous.
---    The cache is invalidated on every `meta.rev` bump (handled by the
---    ingest tick).
--- 3. Format-stable: emits dictionaries shaped like the legacy `manifest`
---    and `today_idx` so the metrics_apps / metrics_typing webview JS does
---    not need to be rewritten in this iteration.
--- 4. Paced mode: every projection accepts an optional `infra.paced_job`
---    pacer. Each statement is then drained and finalized before its rows are
---    handled with pauses, and the all-time n-gram projection is read one day
---    at a time, so no step blocks the run loop for long and no SQLite read
---    lock is held across a pause (the rollback-journal ingest would fail its
---    COMMIT with SQLITE_BUSY). Both modes share the SQL and row handlers.
---
--- DEPENDENCIES:
--- - hs.sqlite3, hs.json.
--- ==============================================================================

local M = {}

local hs      = hs
local json    = require("hs.json")
local sqlite3 = require("hs.sqlite3")

local Logger = require("infra.logger")
local LOG    = "keylogger.sqlite_reader"





-- ==========================
-- ==========================
-- ======= 1/ Helpers =======
-- ==========================
-- ==========================

--- Open the canonical db.sqlite cache. Returns a sqlite3 handle or nil.
--- @param sqlite_path string Absolute path to db.sqlite.
local function _open(sqlite_path)
	local db, err = sqlite3.open(sqlite_path)
	if not db then
		Logger.error(LOG, "Cannot open SQLite at %s: %s.", sqlite_path, tostring(err))
		return nil
	end
	db:exec("PRAGMA query_only = 1;")
	return db
end

--- Quote a string for safe SQL embedding.
local function _q(s) return "'" .. tostring(s):gsub("'", "''") .. "'" end

--- Runs a db:nrows() query loop under pcall so a schema mismatch or corrupt-db
--- exception never propagates out of the reader into the metrics-dashboard
--- timer callbacks that call it (F-MED-28). _open() already guards the initial
--- connect, but nothing downstream guarded the 15+ query loops that follow —
--- an exception raised while stepping through `nrows()` (mid-iteration, not
--- just at prepare time) used to escape all the way to the HS Console.
--- @param label string Short description of the query, for the error log.
--- @param fn function Zero-argument function that runs the `for r in
--- db:nrows(...) do ... end` loop body. Its side effects (writes into the
--- caller's result table) are safe to leave partially applied on failure —
--- an aborted projection pass still returns whatever prior passes populated.
--- @param pacer table|nil Pacer from `infra.paced_job`; pauses after the query.
local function _safe_query(label, fn, pacer)
	local ok, err = pcall(fn)
	if not ok then
		Logger.error(LOG, "Query failed (%s): %s.", label, tostring(err))
	end
	if pacer then pacer.pause() end
end

--- Rows handled between two pause checks in paced mode.
local PACED_ROWS_PER_PAUSE = 256

--- Iterates one query's rows. Without a pacer this is `db:nrows(sql)`. With a
--- pacer the statement is drained and finalized first, then its rows are
--- handed out with pauses, so a yield never keeps a read lock on db.sqlite.
--- @param db userdata Open handle.
--- @param sql string Statement.
--- @param pacer table|nil Pacer from `infra.paced_job`.
--- @return function iterator Yields one row table per call.
local function _rows(db, sql, pacer)
	if not pacer then return db:nrows(sql) end
	local rows = {}
	for r in db:nrows(sql) do rows[#rows + 1] = r end
	local index = 0
	return function()
		index = index + 1
		if index % PACED_ROWS_PER_PAUSE == 0 then pacer.pause() end
		return rows[index]
	end
end

--- Returns the calendar day after `date_str` (YYYY-MM-DD). Noon avoids DST
--- transitions shifting the result by a day.
--- @param date_str string Day.
--- @return string next_day
function M.next_day(date_str)
	local y, m, d = tostring(date_str):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	if not y then error("sqlite_reader: invalid date " .. tostring(date_str), 2) end
	return os.date("%Y-%m-%d", os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d) + 1, hour = 12 }))
end

--- Reset a per-app manifest entry with all numeric counters at 0.
local function _new_app_entry()
	return {
		chars = 0, pauses = 0, time = 0, think_time = 0,
		hs_chars = 0, llm_chars = 0,
		hs_triggers = 0, llm_triggers = 0,
		hs_suggested = 0, llm_suggested = 0,
		hs_input_chars = 0, llm_input_chars = 0,
		app_time_ms = 0,
		category = nil,
		-- Sub-aggregates populated lazily by the projection passes.
		burst_count_total           = 0,
		burst_max_cpm               = 0,
		burst_max_chars             = 0,
		burst_length_buckets        = {},
		burst_inter_delay_count     = 0,
		burst_inter_delay_sum       = 0,
		burst_inter_delay_sumsq     = 0,
		session_count_total         = 0,
		session_longest_ms          = 0,
		session_longest_chars       = 0,
		session_total_active_ms     = 0,
		session_durations           = {},
		bs_total                    = 0,
		cascade_count_total         = 0,
		cascade_max_len             = 0,
		recovery_time_sum_ms        = 0,
		recovery_time_count         = 0,
		same_finger_streak_max      = 0,
		same_hand_streak_max        = 0,
		auto_repeat_count           = 0,
		char_letter = 0, char_digit = 0, char_punct = 0,
		char_space  = 0, char_other = 0,
		first_typed_min = nil, last_typed_min = nil,
		layouts_seen = {},
		kc_hold      = {},
		win_titles   = {},
		hourly       = {},
		hourly_min5  = {},
		time_buckets = {}, credited_buckets = {},
		hs_input_time_buckets = {}, hs_input_credited_buckets = {},
		llm_input_time_buckets = {}, llm_input_credited_buckets = {},
	}
end

--- Get-or-create a (date, app) cell in `manifest`.
local function _get(manifest, date_str, app)
	local d = manifest[date_str]
	if not d then d = {}; manifest[date_str] = d end
	local a = d[app]
	if not a then a = _new_app_entry(); d[app] = a end
	return a
end





-- ======================================
-- ======================================
-- ======= 2/ Manifest projection =======
-- ======================================
-- ======================================

--- Adds one date window of every manifest table into `manifest`.
--- @param db userdata Open handle.
--- @param manifest table Dict being accumulated.
--- @param start_date string|nil Inclusive lower bound (YYYY-MM-DD), or nil.
--- @param end_date   string|nil Inclusive upper bound (YYYY-MM-DD), or nil.
--- @param pacer      table|nil Pacer from `infra.paced_job`.
local function _accumulate_manifest(db, manifest, start_date, end_date, pacer)
	local function date_filter()
		local clauses = {}
		if start_date and start_date ~= "" then
			table.insert(clauses, "date >= " .. _q(start_date))
		end
		if end_date and end_date ~= "" then
			table.insert(clauses, "date <= " .. _q(end_date))
		end
		return (#clauses > 0) and (" WHERE " .. table.concat(clauses, " AND ")) or ""
	end

	-- Core agg_app_day: sum across devices.
	_safe_query("agg_app_day", function()
		for r in _rows(db, string.format([[
			SELECT date, app,
			       SUM(chars)            AS chars,
			       SUM(pauses)           AS pauses,
			       SUM(time_ms)          AS time_ms,
			       SUM(think_time_ms)    AS think_time_ms,
			       SUM(hs_chars)         AS hs_chars,
			       SUM(llm_chars)        AS llm_chars,
			       SUM(hs_triggers)      AS hs_triggers,
			       SUM(llm_triggers)     AS llm_triggers,
			       SUM(hs_suggested)     AS hs_suggested,
			       SUM(llm_suggested)    AS llm_suggested,
			       SUM(hs_input_chars)   AS hs_input_chars,
			       SUM(llm_input_chars)  AS llm_input_chars,
			       SUM(app_time_ms)      AS app_time_ms,
			       MAX(category)         AS category
			FROM agg_app_day %s
			GROUP BY date, app
		]], date_filter()), pacer) do
			local a = _get(manifest, r.date, r.app)
			a.chars            = r.chars or 0
			a.pauses           = r.pauses or 0
			a.time             = r.time_ms or 0
			a.think_time       = r.think_time_ms or 0
			a.hs_chars         = r.hs_chars or 0
			a.llm_chars        = r.llm_chars or 0
			a.hs_triggers      = r.hs_triggers or 0
			a.llm_triggers     = r.llm_triggers or 0
			a.hs_suggested     = r.hs_suggested or 0
			a.llm_suggested    = r.llm_suggested or 0
			a.hs_input_chars   = r.hs_input_chars or 0
			a.llm_input_chars  = r.llm_input_chars or 0
			a.app_time_ms      = r.app_time_ms or 0
			a.category         = r.category
		end
	end, pacer)

	-- agg_app_day_buckets → time/credited/hs_input/llm_input bucket maps.
	_safe_query("agg_app_day_buckets", function()
		for r in _rows(db, string.format([[
			SELECT date, app, bucket_ms,
			       SUM(time_sum)           AS time_sum,
			       SUM(credited)           AS credited,
			       SUM(hs_input_time_sum)  AS hs_in_t,
			       SUM(hs_input_credited)  AS hs_in_c,
			       SUM(llm_input_time_sum) AS llm_in_t,
			       SUM(llm_input_credited) AS llm_in_c
			FROM agg_app_day_buckets %s
			GROUP BY date, app, bucket_ms
		]], date_filter()), pacer) do
			local a = _get(manifest, r.date, r.app)
			local k = tostring(r.bucket_ms)
			a.time_buckets[k]               = (a.time_buckets[k]               or 0) + (r.time_sum  or 0)
			a.credited_buckets[k]           = (a.credited_buckets[k]           or 0) + (r.credited  or 0)
			a.hs_input_time_buckets[k]      = (a.hs_input_time_buckets[k]      or 0) + (r.hs_in_t   or 0)
			a.hs_input_credited_buckets[k]  = (a.hs_input_credited_buckets[k]  or 0) + (r.hs_in_c   or 0)
			a.llm_input_time_buckets[k]     = (a.llm_input_time_buckets[k]     or 0) + (r.llm_in_t  or 0)
			a.llm_input_credited_buckets[k] = (a.llm_input_credited_buckets[k] or 0) + (r.llm_in_c  or 0)
		end
	end, pacer)

	-- agg_app_day_burst.
	-- GROUP BY date, app, length_buckets_json — accumulate scalars and merge
	-- histogram buckets in Lua to avoid MIN(length_buckets_json) losing data
	-- when multiple devices contribute rows for the same (date, app). Retain
	-- source multiplicity so byte-identical blobs contribute once per device.
	_safe_query("agg_app_day_burst", function()
		for r in _rows(db, string.format([[
			SELECT date, app,
			       SUM(count_total)        AS count_total,
			       MAX(max_cpm)            AS max_cpm,
			       MAX(max_chars)          AS max_chars,
			       SUM(inter_delay_count)  AS inter_count,
			       SUM(inter_delay_sum)    AS inter_sum,
			       SUM(inter_delay_sumsq)  AS inter_sumsq,
			       length_buckets_json, COUNT(*) AS source_rows
			FROM agg_app_day_burst %s
			GROUP BY date, app, length_buckets_json
		]], date_filter()), pacer) do
			local a = _get(manifest, r.date, r.app)
			a.burst_count_total       = (a.burst_count_total       or 0) + (r.count_total or 0)
			a.burst_max_cpm           = math.max(a.burst_max_cpm   or 0,   r.max_cpm   or 0)
			a.burst_max_chars         = math.max(a.burst_max_chars or 0,   r.max_chars or 0)
			a.burst_inter_delay_count = (a.burst_inter_delay_count or 0) + (r.inter_count or 0)
			a.burst_inter_delay_sum   = (a.burst_inter_delay_sum   or 0) + (r.inter_sum   or 0)
			a.burst_inter_delay_sumsq = (a.burst_inter_delay_sumsq or 0) + (r.inter_sumsq or 0)
			local ok, lb = pcall(json.decode, r.length_buckets_json or "{}")
			if ok and type(lb) == "table" then
				if not a.burst_length_buckets then a.burst_length_buckets = {} end
				for k, v in pairs(lb) do
					a.burst_length_buckets[k] = (a.burst_length_buckets[k] or 0) + (v or 0) * r.source_rows
				end
			end
		end
	end, pacer)

	-- agg_app_day_session.
	_safe_query("agg_app_day_session", function()
		for r in _rows(db, string.format([[
			SELECT date, app, count_total, longest_ms, longest_chars, total_active_ms, durations_json
			FROM agg_app_day_session %s
		]], date_filter()), pacer) do
			local a = _get(manifest, r.date, r.app)
			a.session_count_total      = (a.session_count_total      or 0) + (r.count_total or 0)
			if (r.longest_ms or 0)    > (a.session_longest_ms or 0)    then a.session_longest_ms    = r.longest_ms end
			if (r.longest_chars or 0) > (a.session_longest_chars or 0) then a.session_longest_chars = r.longest_chars end
			a.session_total_active_ms  = (a.session_total_active_ms or 0) + (r.total_active_ms or 0)
			local ok, durs = pcall(json.decode, r.durations_json or "[]")
			if ok and type(durs) == "table" then
				for _, d in ipairs(durs) do table.insert(a.session_durations, d) end
			end
		end
	end, pacer)

	-- agg_app_day_chars_class.
	_safe_query("agg_app_day_chars_class", function()
		for r in _rows(db, string.format([[
			SELECT date, app,
			       SUM(letter) AS letter, SUM(digit) AS digit, SUM(punct) AS punct,
			       SUM(space)  AS space,  SUM(other) AS other,
			       MIN(first_typed_min) AS first_min, MAX(last_typed_min) AS last_min
			FROM agg_app_day_chars_class %s
			GROUP BY date, app
		]], date_filter()), pacer) do
			local a = _get(manifest, r.date, r.app)
			a.char_letter = r.letter or 0
			a.char_digit  = r.digit  or 0
			a.char_punct  = r.punct  or 0
			a.char_space  = r.space  or 0
			a.char_other  = r.other  or 0
			a.first_typed_min = r.first_min
			a.last_typed_min  = r.last_min
		end
	end, pacer)

	-- agg_app_day_errors.
	_safe_query("agg_app_day_errors", function()
		for r in _rows(db, string.format([[
			SELECT date, app,
			       SUM(bs_total)        AS bs_total,
			       SUM(cascade_count)   AS cascade_count,
			       MAX(cascade_max_len) AS cascade_max_len,
			       SUM(recovery_sum_ms) AS recovery_sum,
			       SUM(recovery_count)  AS recovery_count
			FROM agg_app_day_errors %s
			GROUP BY date, app
		]], date_filter()), pacer) do
			local a = _get(manifest, r.date, r.app)
			a.bs_total              = r.bs_total or 0
			a.cascade_count_total   = r.cascade_count or 0
			a.cascade_max_len       = r.cascade_max_len or 0
			a.recovery_time_sum_ms  = r.recovery_sum or 0
			a.recovery_time_count   = r.recovery_count or 0
		end
	end, pacer)

	-- agg_app_day_ergo.
	_safe_query("agg_app_day_ergo", function()
		for r in _rows(db, string.format([[
			SELECT date, app,
			       MAX(same_finger_streak_max) AS f_max,
			       MAX(same_hand_streak_max)   AS h_max,
			       SUM(auto_repeat_count)      AS ar_count
			FROM agg_app_day_ergo %s
			GROUP BY date, app
		]], date_filter()), pacer) do
			local a = _get(manifest, r.date, r.app)
			a.same_finger_streak_max = r.f_max or 0
			a.same_hand_streak_max   = r.h_max or 0
			a.auto_repeat_count      = r.ar_count or 0
		end
	end, pacer)

	-- agg_app_day_layouts.
	_safe_query("agg_app_day_layouts", function()
		for r in _rows(db, string.format([[
			SELECT date, app, layout, SUM(count) AS count
			FROM agg_app_day_layouts %s
			GROUP BY date, app, layout
		]], date_filter()), pacer) do
			local a = _get(manifest, r.date, r.app)
			a.layouts_seen[r.layout] = (a.layouts_seen[r.layout] or 0) + (r.count or 0)
		end
	end, pacer)

	-- agg_app_day_kc_hold.
	_safe_query("agg_app_day_kc_hold", function()
		for r in _rows(db, string.format([[
			SELECT date, app, keycode,
			       SUM(sum_ms) AS s, SUM(count) AS c, MAX(max_ms) AS mx,
			       SUM(tap_count) AS t, SUM(hold_count) AS h
			FROM agg_app_day_kc_hold %s
			GROUP BY date, app, keycode
		]], date_filter()), pacer) do
			local a = _get(manifest, r.date, r.app)
			a.kc_hold[tostring(r.keycode)] = {
				sum = r.s or 0, count = r.c or 0, max = r.mx or 0,
				tap = r.t or 0, hold = r.h or 0,
			}
		end
	end, pacer)

	-- agg_app_day_titles.
	_safe_query("agg_app_day_titles", function()
		for r in _rows(db, string.format([[
			SELECT date, app, title, SUM(c) AS c, SUM(ms) AS ms
			FROM agg_app_day_titles %s
			GROUP BY date, app, title
		]], date_filter()), pacer) do
			local a = _get(manifest, r.date, r.app)
			a.win_titles[r.title] = { c = r.c or 0, ms = r.ms or 0 }
		end
	end, pacer)

	-- agg_app_day_hourly.
	-- GROUP BY date, app, hour, e_buckets_json to avoid MIN(e_buckets_json) loss
	-- on multi-device installs; accumulate scalars and merge buckets in Lua.
	_safe_query("agg_app_day_hourly", function()
		for r in _rows(db, string.format([[
			SELECT date, app, hour,
			       SUM(c) AS c, SUM(e) AS e, SUM(em) AS em, SUM(es) AS es,
			       e_buckets_json, COUNT(*) AS source_rows
			FROM agg_app_day_hourly %s
			GROUP BY date, app, hour, e_buckets_json
		]], date_filter()), pacer) do
			local a = _get(manifest, r.date, r.app)
			local h = a.hourly[r.hour]
			if not h then
				h = { c = 0, e = 0, em = 0, es = 0, e_buckets = {} }
				a.hourly[r.hour] = h
			end
			h.c  = h.c  + (r.c  or 0)
			h.e  = h.e  + (r.e  or 0)
			h.em = h.em + (r.em or 0)
			h.es = h.es + (r.es or 0)
			local ok, buckets = pcall(json.decode, r.e_buckets_json or "{}")
			if ok and type(buckets) == "table" then
				for k, v in pairs(buckets) do
					h.e_buckets[k] = (h.e_buckets[k] or 0) + (v or 0) * r.source_rows
				end
			end
		end
	end, pacer)

	-- agg_app_day_hourly_min5.
	-- Same multi-device fix: GROUP BY slot, e_buckets_json; accumulate in Lua.
	_safe_query("agg_app_day_hourly_min5", function()
		for r in _rows(db, string.format([[
			SELECT date, app, slot,
			       SUM(c) AS c, SUM(e) AS e, SUM(es) AS es,
			       e_buckets_json, COUNT(*) AS source_rows
			FROM agg_app_day_hourly_min5 %s
			GROUP BY date, app, slot, e_buckets_json
		]], date_filter()), pacer) do
			local a = _get(manifest, r.date, r.app)
			local h = a.hourly_min5[r.slot]
			if not h then
				h = { c = 0, e = 0, es = 0, e_buckets = {} }
				a.hourly_min5[r.slot] = h
			end
			h.c  = h.c  + (r.c  or 0)
			h.e  = h.e  + (r.e  or 0)
			h.es = h.es + (r.es or 0)
			local ok, buckets = pcall(json.decode, r.e_buckets_json or "{}")
			if ok and type(buckets) == "table" then
				for k, v in pairs(buckets) do
					h.e_buckets[k] = (h.e_buckets[k] or 0) + (v or 0) * r.source_rows
				end
			end
		end
	end, pacer)

end

--- Manifest source tables whose MIN/MAX(date) bound a paced manifest read.
local MANIFEST_TABLES = {
	"agg_app_day", "agg_app_day_buckets", "agg_app_day_burst", "agg_app_day_session",
	"agg_app_day_chars_class", "agg_app_day_errors", "agg_app_day_ergo", "agg_app_day_layouts",
	"agg_app_day_kc_hold", "agg_app_day_titles", "agg_app_day_hourly", "agg_app_day_hourly_min5",
}

--- Days per paced manifest window. The largest per-(date, app) tables return
--- tens of thousands of rows for all time; a month keeps each drained
--- statement to a fraction of that.
local MANIFEST_WINDOW_DAYS = 30

--- Returns the inclusive windows a paced manifest read visits.
--- @param db userdata Open handle.
--- @param start_date string|nil Inclusive lower bound.
--- @param end_date string|nil Inclusive upper bound.
--- @return table windows Array of { lo, hi } day pairs.
local function _manifest_windows(db, start_date, end_date)
	local lo, hi = nil, nil
	for _, tbl in ipairs(MANIFEST_TABLES) do
		_safe_query(tbl .. "(bounds)", function()
			for r in db:nrows(string.format(
				"SELECT (SELECT MIN(date) FROM %s) AS lo, (SELECT MAX(date) FROM %s) AS hi", tbl, tbl)) do
				if r.lo and (not lo or r.lo < lo) then lo = r.lo end
				if r.hi and (not hi or r.hi > hi) then hi = r.hi end
			end
		end)
	end
	if start_date and start_date ~= "" and (not lo or start_date > lo) then lo = start_date end
	if end_date and end_date ~= "" and (not hi or end_date < hi) then hi = end_date end
	local windows = {}
	if not lo or not hi or lo > hi then return windows end
	local window_lo = lo
	while window_lo <= hi do
		local window_hi = window_lo
		for _ = 2, MANIFEST_WINDOW_DAYS do
			local following = M.next_day(window_hi)
			if following > hi then break end
			window_hi = following
		end
		windows[#windows + 1] = { window_lo, window_hi }
		window_lo = M.next_day(window_hi)
	end
	return windows
end

--- Build a manifest dict matching the legacy shape: `manifest[date][app] =
--- { chars, time, think_time, … }` summed across every device.
--- @param sqlite_path string Path to db.sqlite.
--- @param start_date  string|nil Inclusive lower bound (YYYY-MM-DD), or nil.
--- @param end_date    string|nil Inclusive upper bound (YYYY-MM-DD), or nil.
--- @param pacer       table|nil Pacer from `infra.paced_job`; reads month windows.
--- @return table The manifest dict.
function M.read_manifest(sqlite_path, start_date, end_date, pacer)
	local manifest = {}
	local db = _open(sqlite_path)
	if not db then return manifest end
	if pacer then
		-- Every manifest cell belongs to exactly one day, so disjoint windows
		-- partition the rows without changing any cell.
		for _, window in ipairs(_manifest_windows(db, start_date, end_date)) do
			_accumulate_manifest(db, manifest, window[1], window[2], pacer)
		end
	else
		_accumulate_manifest(db, manifest, start_date, end_date, nil)
	end
	db:close()
	return manifest
end





-- ====================================
-- ====================================
-- ======= 3/ N-gram projection =======
-- ====================================
-- ====================================

--- Map "type code" used by legacy today_idx to the underlying SQLite table.
local NGRAM_TYPE_TABLE = {
	c     = "ngram_chars",
	bg    = "ngram_bigrams",
	tg    = "ngram_trigrams",
	qg    = "ngram_quadgrams",
	pg    = "ngram_pentagrams",
	hx    = "ngram_hexagrams",
	hp    = "ngram_heptagrams",
	w     = "ngram_words",
	w_bg  = "ngram_word_bigrams",
}

--- Tables whose MIN/MAX(date) bound the days a paced n-gram read visits.
local NGRAM_STANDALONE_TABLES = { "ngram_shortcuts", "ngram_shortcut_bigrams", "ngram_keycodes" }

--- Returns an empty n-gram dict in the legacy `today_idx[app]` shape.
--- @return table
local function _new_ngram_dict()
	return { c = {}, bg = {}, tg = {}, qg = {}, pg = {}, hx = {}, hp = {}, w = {}, sc = {}, sc_bg = {}, w_bg = {}, kc = {} }
end


--- Lists the days a paced read must visit: the requested bounds clamped to the
--- first and last day any n-gram table holds.
--- @param db userdata Open handle.
--- @param start_date string|nil Inclusive lower bound.
--- @param end_date string|nil Inclusive upper bound.
--- @return table days Ascending YYYY-MM-DD strings.
local function _ngram_days(db, start_date, end_date)
	local lo, hi = nil, nil
	local tables = { table.unpack(NGRAM_STANDALONE_TABLES) }
	for _, tbl in pairs(NGRAM_TYPE_TABLE) do tables[#tables + 1] = tbl end
	for _, tbl in ipairs(tables) do
		_safe_query(tbl .. "(bounds)", function()
			-- Two scalar subqueries keep SQLite's single-MIN/MAX index shortcut
			for r in db:nrows(string.format(
				"SELECT (SELECT MIN(date) FROM %s) AS lo, (SELECT MAX(date) FROM %s) AS hi", tbl, tbl)) do
				if r.lo and (not lo or r.lo < lo) then lo = r.lo end
				if r.hi and (not hi or r.hi > hi) then hi = r.hi end
			end
		end)
	end
	if start_date and start_date ~= "" and (not lo or start_date > lo) then lo = start_date end
	if end_date and end_date ~= "" and (not hi or end_date < hi) then hi = end_date end
	local days = {}
	if not lo or not hi then return days end
	local day = lo
	while day <= hi do
		days[#days + 1] = day
		day = M.next_day(day)
	end
	return days
end

--- Adds one date window of every n-gram table into `out`. The row handlers are
--- additive, so reading a range in one window or day by day gives the same dict.
--- @param db userdata Open handle.
--- @param out table Dict being accumulated.
--- @param start_date string|nil Inclusive lower bound.
--- @param end_date string|nil Inclusive upper bound.
--- @param selected_apps table|nil Array of allowed apps (nil = all).
--- @param pacer table|nil Pacer from `infra.paced_job`.
local function _accumulate_ngrams(db, out, start_date, end_date, selected_apps, pacer)
	local function build_filter(extra_app)
		local clauses = {}
		if start_date and start_date ~= "" then
			table.insert(clauses, "date >= " .. _q(start_date))
		end
		if end_date and end_date ~= "" then
			table.insert(clauses, "date <= " .. _q(end_date))
		end
		if extra_app and #extra_app > 0 then
			local quoted = {}
			for _, a in ipairs(extra_app) do table.insert(quoted, _q(a)) end
			table.insert(clauses, "app IN (" .. table.concat(quoted, ",") .. ")")
		end
		return (#clauses > 0) and (" WHERE " .. table.concat(clauses, " AND ")) or ""
	end

	local app_filter = (selected_apps and #selected_apps > 0) and selected_apps or nil
	local where = build_filter(app_filter)

	-- GROUP BY token, esrc_json so multi-device rows are not collapsed via
	-- MIN(esrc_json) — each distinct blob gets its own row and is merged in Lua.
	-- Wrapped per-table: a schema mismatch on one ngram table must not abort
	-- the projection for the other eight (F-MED-28).
	for code, tbl in pairs(NGRAM_TYPE_TABLE) do
		_safe_query(tbl, function()
			for r in _rows(db, string.format([[
				SELECT token,
				       SUM(c)  AS c,
				       SUM(td) AS t,
				       SUM(e)  AS e,
				       esrc_json, COUNT(*) AS source_rows
				FROM %s %s
				GROUP BY token, esrc_json
			]], tbl, where), pacer) do
				local item = out[code][r.token]
				if not item then
					item = { c = 0, t = 0, e = 0, hs = 0, llm = 0, o = 0 }
					out[code][r.token] = item
				end
				item.c = item.c + (r.c or 0)
				item.t = item.t + (r.t or 0)
				item.e = item.e + (r.e or 0)
				-- An empty source map contributes nothing; skipping its decode is exact
				local raw = r.esrc_json or "{}"
				local ok, src = true, nil
				if raw ~= "{}" then ok, src = pcall(json.decode, raw) end
				if ok and type(src) == "table" then
					item.hs  = item.hs  + (src.hotstring or 0) * r.source_rows
					item.llm = item.llm + (src.llm       or 0) * r.source_rows
					for k, v in pairs(src) do
						if k ~= "hotstring" and k ~= "llm" and k ~= "none" then
							item.o = item.o + (v or 0) * r.source_rows
						end
					end
				end
			end
		end, pacer)
	end

	-- Counts only. Accumulated rather than assigned so day windows add up.
	local function add_count(bucket, key, count)
		local item = bucket[key]
		if not item then
			item = { c = 0, t = 0, e = 0, hs = 0, llm = 0, o = 0 }
			bucket[key] = item
		end
		item.c = item.c + (count or 0)
	end

	-- Shortcuts (counts only).
	_safe_query("ngram_shortcuts", function()
		for r in _rows(db, string.format([[
			SELECT token, SUM(c) AS c FROM ngram_shortcuts %s GROUP BY token
		]], where), pacer) do
			add_count(out.sc, r.token, r.c)
		end
	end, pacer)
	_safe_query("ngram_shortcut_bigrams", function()
		for r in _rows(db, string.format([[
			SELECT token, SUM(c) AS c FROM ngram_shortcut_bigrams %s GROUP BY token
		]], where), pacer) do
			add_count(out.sc_bg, r.token, r.c)
		end
	end, pacer)
	-- Keycodes.
	_safe_query("ngram_keycodes", function()
		for r in _rows(db, string.format([[
			SELECT keycode, SUM(c) AS c FROM ngram_keycodes %s GROUP BY keycode
		]], where), pacer) do
			add_count(out.kc, tostring(r.keycode), r.c)
		end
	end, pacer)
end

--- Build a {c, bg, tg, …} dict matching the legacy `today_idx[app]` shape,
--- merged across every device for the requested date range and (optional)
--- app filter.
--- @param sqlite_path  string Path to db.sqlite.
--- @param start_date   string|nil Inclusive lower bound.
--- @param end_date     string|nil Inclusive upper bound.
--- @param selected_apps table|nil Array of allowed apps (nil = all).
--- @param pacer table|nil Pacer from `infra.paced_job`; reads one day per window.
--- @return table { c={tok→{c,t,e,hs,llm,o}}, bg=…, … }.
function M.read_ngrams(sqlite_path, start_date, end_date, selected_apps, pacer)
	local out = _new_ngram_dict()
	local db = _open(sqlite_path)
	if not db then return out end
	if pacer then
		-- One all-time GROUP BY sorts every row in its first step; a day keeps each
		-- statement short enough to sit between two pauses.
		for _, day in ipairs(_ngram_days(db, start_date, end_date)) do
			_accumulate_ngrams(db, out, day, day, selected_apps, pacer)
		end
	else
		_accumulate_ngrams(db, out, start_date, end_date, selected_apps, nil)
	end
	db:close()
	return out
end

--- Adds every entry of `from` into `into`, using the same additive fields as
--- the row handlers. Used to extend a cached historical dict by new days.
--- @param into table Dict from read_ngrams, mutated.
--- @param from table Dict from read_ngrams.
--- @return table into
function M.merge_ngrams(into, from)
	for code, tokens in pairs(from) do
		local bucket = into[code]
		if not bucket then bucket = {}; into[code] = bucket end
		for token, item in pairs(tokens) do
			local target = bucket[token]
			if not target then
				target = { c = 0, t = 0, e = 0, hs = 0, llm = 0, o = 0 }
				bucket[token] = target
			end
			target.c   = target.c   + item.c
			target.t   = target.t   + item.t
			target.e   = target.e   + item.e
			target.hs  = target.hs  + item.hs
			target.llm = target.llm + item.llm
			target.o   = target.o   + item.o
		end
	end
	return into
end

--- Splits a range request at today, the boundary between the historical
--- dict and the live per-app slice.
--- @param start_date string|nil Inclusive lower bound.
--- @param end_date   string|nil Inclusive upper bound.
--- @param today_str  string Current day (YYYY-MM-DD).
--- @return table { includes_today = boolean, historical_end = string }
function M.split_bounds(start_date, end_date, today_str)
	-- `today` is a separate per-app projection for the live dashboard.  It must
	-- only participate when the requested inclusive range actually covers today;
	-- otherwise changing the date filter to a historical day leaks current keys
	-- into the displayed totals.
	local includes_today = (not start_date or start_date == "" or start_date <= today_str)
		and (not end_date or end_date == "" or end_date >= today_str)
	-- Historical: anything strictly before today. Calendar arithmetic on the
	-- date string avoids invalid days (2026-01-00) and DST-length days.
	local y, m, d = tostring(today_str):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	if not y then error("sqlite_reader: invalid today " .. tostring(today_str), 2) end
	local yesterday_str = os.date("%Y-%m-%d",
		os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d) - 1, hour = 12 }))
	local historical_end = yesterday_str
	if end_date and end_date ~= "" and end_date < today_str then historical_end = end_date end
	return { includes_today = includes_today, historical_end = historical_end }
end

--- Builds today's per-app n-gram slice of a range request, shaped like the
--- legacy `today_idx[app] = {c, bg, …}`, empty when the range excludes today.
--- @param sqlite_path  string Path to db.sqlite.
--- @param start_date   string|nil
--- @param end_date     string|nil
--- @param selected_apps table|nil
--- @param pacer table|nil Pacer from `infra.paced_job`.
--- @param today_str string|nil Current day; defaults to the local date.
--- @return table today_idx {app→{c=,…}}.
function M.read_today_split(sqlite_path, start_date, end_date, selected_apps, pacer, today_str)
	today_str = today_str or os.date("%Y-%m-%d")
	local includes_today = M.split_bounds(start_date, end_date, today_str).includes_today
	-- Today: per-app ngram dict for each selected app, but never outside the
	-- caller's requested date interval.
	local today_idx = {}
	local db = includes_today and _open(sqlite_path) or nil
	if db then
		local app_clause = ""
		if selected_apps and #selected_apps > 0 then
			local quoted = {}
			for _, a in ipairs(selected_apps) do table.insert(quoted, _q(a)) end
			app_clause = " AND app IN (" .. table.concat(quoted, ",") .. ")"
		end
		-- GROUP BY app, token, esrc_json so multi-device rows produce separate
		-- rows per distinct blob — accumulated in Lua to avoid MIN(esrc_json) collapse.
		-- Wrapped per-table: a schema mismatch on one ngram table must not abort
		-- the projection for the other eight (F-MED-28).
		for code, tbl in pairs(NGRAM_TYPE_TABLE) do
			_safe_query(tbl, function()
				for r in _rows(db, string.format([[
					SELECT app, token,
					       SUM(c) AS c, SUM(td) AS t, SUM(e) AS e,
					       esrc_json, COUNT(*) AS source_rows
					FROM %s
					WHERE date = %s %s
					GROUP BY app, token, esrc_json
				]], tbl, _q(today_str), app_clause), pacer) do
					if not today_idx[r.app] then
						today_idx[r.app] = { c={},bg={},tg={},qg={},pg={},hx={},hp={},w={},sc={},sc_bg={},w_bg={},kc={} }
					end
					local item = today_idx[r.app][code] and today_idx[r.app][code][r.token]
					if not item then
						item = { c = 0, t = 0, e = 0, hs = 0, llm = 0, o = 0 }
						if not today_idx[r.app][code] then today_idx[r.app][code] = {} end
						today_idx[r.app][code][r.token] = item
					end
					item.c = item.c + (r.c or 0)
					item.t = item.t + (r.t or 0)
					item.e = item.e + (r.e or 0)
					local raw = r.esrc_json or "{}"
					local ok, src = true, nil
					if raw ~= "{}" then ok, src = pcall(json.decode, raw) end
					if ok and type(src) == "table" then
						item.hs  = item.hs  + (src.hotstring or 0) * r.source_rows
						item.llm = item.llm + (src.llm       or 0) * r.source_rows
						for k, v in pairs(src) do
							if k ~= "hotstring" and k ~= "llm" and k ~= "none" then
								item.o = item.o + (v or 0) * r.source_rows
							end
						end
					end
					today_idx[r.app][code][r.token] = item
				end
			end, pacer)
		end

		-- Physical keycodes and shortcuts live OUTSIDE NGRAM_TYPE_TABLE, so the loop
		-- above never touched them — but the keycode heatmap and both shortcut tabs
		-- read today's slice from here. Without these three passes those views showed
		-- only historical data and never moved while the user typed, which reads as
		-- "the heatmap is broken" rather than as missing data. The historical branch
		-- already covers all three; this is the today projection catching up (parity
		-- with the Windows reader).
		local function _today_bucket(app)
			if not today_idx[app] then
				today_idx[app] = { c={},bg={},tg={},qg={},pg={},hx={},hp={},w={},sc={},sc_bg={},w_bg={},kc={} }
			end
			return today_idx[app]
		end

		_safe_query("ngram_keycodes(today)", function()
			for r in _rows(db, string.format([[
				SELECT app, keycode, SUM(c) AS c FROM ngram_keycodes
				WHERE date = %s %s GROUP BY app, keycode
			]], _q(today_str), app_clause), pacer) do
				_today_bucket(r.app).kc[tostring(r.keycode)] =
					{ c = r.c or 0, t = 0, e = 0, hs = 0, llm = 0, o = 0 }
			end
		end, pacer)

		_safe_query("ngram_shortcuts(today)", function()
			for r in _rows(db, string.format([[
				SELECT app, token, SUM(c) AS c FROM ngram_shortcuts
				WHERE date = %s %s GROUP BY app, token
			]], _q(today_str), app_clause), pacer) do
				_today_bucket(r.app).sc[r.token] =
					{ c = r.c or 0, t = 0, e = 0, hs = 0, llm = 0, o = 0 }
			end
		end, pacer)

		_safe_query("ngram_shortcut_bigrams(today)", function()
			for r in _rows(db, string.format([[
				SELECT app, token, SUM(c) AS c FROM ngram_shortcut_bigrams
				WHERE date = %s %s GROUP BY app, token
			]], _q(today_str), app_clause), pacer) do
				_today_bucket(r.app).sc_bg[r.token] =
					{ c = r.c or 0, t = 0, e = 0, hs = 0, llm = 0, o = 0 }
			end
		end, pacer)

		db:close()
	end

	return today_idx
end

--- Convenience wrapper: returns { historical = …, today = today_app_idx }
--- so the legacy metrics_typing JS can keep its split. `today_app_idx` is
--- shaped like `today_idx[app] = {c, bg, …}` for compatibility.
--- @param sqlite_path  string Path to db.sqlite.
--- @param start_date   string|nil
--- @param end_date     string|nil
--- @param selected_apps table|nil
--- @param pacer table|nil Pacer from `infra.paced_job`.
--- @return table { historical = {c=,…}, today = {app→{c=,…}} }.
function M.read_range_split_today(sqlite_path, start_date, end_date, selected_apps, pacer)
	local today_str = os.date("%Y-%m-%d")
	local bounds = M.split_bounds(start_date, end_date, today_str)
	local historical = M.read_ngrams(sqlite_path, start_date, bounds.historical_end,
		selected_apps, pacer)
	local today_idx = M.read_today_split(sqlite_path, start_date, end_date, selected_apps,
		pacer, today_str)
	return { historical = historical, today = today_idx }
end






-- ========================================
-- ========================================
-- ======= 4/ Past-data fingerprint =======
-- ========================================
-- ========================================

--- Tables and numeric expressions summed by the past-data fingerprint. Every
--- manifest source is covered directly. The bigram to heptagram tables are
--- covered through `ngram_chars`: the walker credits an n-gram only for the
--- character that ends it, and that character increments `ngram_chars` on the
--- same day in the same flush, so no n-gram row of a past day changes without
--- the chars witness changing too. Word n-grams and physical-key tables have
--- their own triggers (word boundaries, shortcuts, keycodes) and are listed.
local FINGERPRINT_SOURCES = {
	{ "ngram_chars",             "c", "td", "e", "length(esrc_json)" },
	{ "ngram_words",             "c" },
	{ "ngram_word_bigrams",      "c" },
	{ "ngram_keycodes",          "c" },
	{ "ngram_shortcuts",         "c" },
	{ "ngram_shortcut_bigrams",  "c" },
	{ "agg_app_day",             "chars", "time_ms", "think_time_ms", "app_time_ms", "hs_triggers", "llm_triggers" },
	{ "agg_app_day_buckets",     "time_sum", "credited", "hs_input_time_sum", "llm_input_time_sum" },
	{ "agg_app_day_burst",       "count_total", "inter_delay_sum", "length(length_buckets_json)" },
	{ "agg_app_day_session",     "count_total", "total_active_ms", "length(durations_json)" },
	{ "agg_app_day_chars_class", "letter", "digit", "punct", "space", "other" },
	{ "agg_app_day_errors",      "bs_total", "cascade_count", "recovery_sum_ms" },
	{ "agg_app_day_ergo",        "auto_repeat_count", "same_finger_streak_max", "same_hand_streak_max" },
	{ "agg_app_day_layouts",     "count" },
	{ "agg_app_day_kc_hold",     "count", "sum_ms", "hold_count" },
	{ "agg_app_day_titles",      "c", "ms" },
	{ "agg_app_day_hourly",      "c", "e", "es", "length(e_buckets_json)" },
	{ "agg_app_day_hourly_min5", "c", "e", "es", "length(e_buckets_json)" },
}

--- Summarizes every row the dashboards read for days up to `through_date`,
--- so a cached projection of those days can prove it is still current. Each
--- statement is one small aggregate scan and runs to completion before the
--- pacer may pause.
--- @param sqlite_path string Path to db.sqlite.
--- @param through_date string Inclusive last day (YYYY-MM-DD).
--- @param pacer table|nil Pacer from `infra.paced_job`.
--- @return string|nil fingerprint Nil when any source could not be read.
--- @return string|nil err Failure detail.
function M.fingerprint(sqlite_path, through_date, pacer)
	local db = _open(sqlite_path)
	if not db then return nil, "db.sqlite could not be opened" end
	local parts = {}
	local failure = nil
	for _, source in ipairs(FINGERPRINT_SOURCES) do
		local columns = { "COUNT(*) AS n" }
		for i = 2, #source do columns[#columns + 1] = string.format("TOTAL(%s) AS s%d", source[i], i) end
		local sql = string.format("SELECT %s FROM %s WHERE date <= %s",
			table.concat(columns, ", "), source[1], _q(through_date))
		local ok, err = pcall(function()
			for r in db:nrows(sql) do
				local values = { tostring(r.n) }
				for i = 2, #source do values[#values + 1] = string.format("%.17g", r["s" .. i] or 0) end
				parts[#parts + 1] = source[1] .. "=" .. table.concat(values, ":")
			end
		end)
		if not ok then
			failure = failure or string.format("%s: %s", source[1], tostring(err))
		end
		if pacer then pacer.pause() end
	end
	db:close()
	if failure then return nil, failure end
	return table.concat(parts, "|")
end


return M
