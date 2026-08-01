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
local function _safe_query(label, fn)
	local ok, err = pcall(fn)
	if not ok then
		Logger.error(LOG, "Query failed (%s): %s.", label, tostring(err))
	end
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

--- Build a manifest dict matching the legacy shape: `manifest[date][app] =
--- { chars, time, think_time, … }` summed across every device.
--- @param sqlite_path string Path to db.sqlite.
--- @param start_date  string|nil Inclusive lower bound (YYYY-MM-DD), or nil.
--- @param end_date    string|nil Inclusive upper bound (YYYY-MM-DD), or nil.
--- @return table The manifest dict.
function M.read_manifest(sqlite_path, start_date, end_date)
	local manifest = {}
	local db = _open(sqlite_path)
	if not db then return manifest end

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
		for r in db:nrows(string.format([[
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
		]], date_filter())) do
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
	end)

	-- agg_app_day_buckets → time/credited/hs_input/llm_input bucket maps.
	_safe_query("agg_app_day_buckets", function()
		for r in db:nrows(string.format([[
			SELECT date, app, bucket_ms,
			       SUM(time_sum)           AS time_sum,
			       SUM(credited)           AS credited,
			       SUM(hs_input_time_sum)  AS hs_in_t,
			       SUM(hs_input_credited)  AS hs_in_c,
			       SUM(llm_input_time_sum) AS llm_in_t,
			       SUM(llm_input_credited) AS llm_in_c
			FROM agg_app_day_buckets %s
			GROUP BY date, app, bucket_ms
		]], date_filter())) do
			local a = _get(manifest, r.date, r.app)
			local k = tostring(r.bucket_ms)
			a.time_buckets[k]               = (a.time_buckets[k]               or 0) + (r.time_sum  or 0)
			a.credited_buckets[k]           = (a.credited_buckets[k]           or 0) + (r.credited  or 0)
			a.hs_input_time_buckets[k]      = (a.hs_input_time_buckets[k]      or 0) + (r.hs_in_t   or 0)
			a.hs_input_credited_buckets[k]  = (a.hs_input_credited_buckets[k]  or 0) + (r.hs_in_c   or 0)
			a.llm_input_time_buckets[k]     = (a.llm_input_time_buckets[k]     or 0) + (r.llm_in_t  or 0)
			a.llm_input_credited_buckets[k] = (a.llm_input_credited_buckets[k] or 0) + (r.llm_in_c  or 0)
		end
	end)

	-- agg_app_day_burst.
	-- GROUP BY date, app, length_buckets_json — accumulate scalars and merge
	-- histogram buckets in Lua to avoid MIN(length_buckets_json) losing data
	-- when multiple devices contribute rows for the same (date, app).
	_safe_query("agg_app_day_burst", function()
		for r in db:nrows(string.format([[
			SELECT date, app,
			       SUM(count_total)        AS count_total,
			       MAX(max_cpm)            AS max_cpm,
			       MAX(max_chars)          AS max_chars,
			       SUM(inter_delay_count)  AS inter_count,
			       SUM(inter_delay_sum)    AS inter_sum,
			       SUM(inter_delay_sumsq)  AS inter_sumsq,
			       length_buckets_json
			FROM agg_app_day_burst %s
			GROUP BY date, app, length_buckets_json
		]], date_filter())) do
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
					a.burst_length_buckets[k] = (a.burst_length_buckets[k] or 0) + (v or 0)
				end
			end
		end
	end)

	-- agg_app_day_session.
	_safe_query("agg_app_day_session", function()
		for r in db:nrows(string.format([[
			SELECT date, app, count_total, longest_ms, longest_chars, total_active_ms, durations_json
			FROM agg_app_day_session %s
		]], date_filter())) do
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
	end)

	-- agg_app_day_chars_class.
	_safe_query("agg_app_day_chars_class", function()
		for r in db:nrows(string.format([[
			SELECT date, app,
			       SUM(letter) AS letter, SUM(digit) AS digit, SUM(punct) AS punct,
			       SUM(space)  AS space,  SUM(other) AS other,
			       MIN(first_typed_min) AS first_min, MAX(last_typed_min) AS last_min
			FROM agg_app_day_chars_class %s
			GROUP BY date, app
		]], date_filter())) do
			local a = _get(manifest, r.date, r.app)
			a.char_letter = r.letter or 0
			a.char_digit  = r.digit  or 0
			a.char_punct  = r.punct  or 0
			a.char_space  = r.space  or 0
			a.char_other  = r.other  or 0
			a.first_typed_min = r.first_min
			a.last_typed_min  = r.last_min
		end
	end)

	-- agg_app_day_errors.
	_safe_query("agg_app_day_errors", function()
		for r in db:nrows(string.format([[
			SELECT date, app,
			       SUM(bs_total)        AS bs_total,
			       SUM(cascade_count)   AS cascade_count,
			       MAX(cascade_max_len) AS cascade_max_len,
			       SUM(recovery_sum_ms) AS recovery_sum,
			       SUM(recovery_count)  AS recovery_count
			FROM agg_app_day_errors %s
			GROUP BY date, app
		]], date_filter())) do
			local a = _get(manifest, r.date, r.app)
			a.bs_total              = r.bs_total or 0
			a.cascade_count_total   = r.cascade_count or 0
			a.cascade_max_len       = r.cascade_max_len or 0
			a.recovery_time_sum_ms  = r.recovery_sum or 0
			a.recovery_time_count   = r.recovery_count or 0
		end
	end)

	-- agg_app_day_ergo.
	_safe_query("agg_app_day_ergo", function()
		for r in db:nrows(string.format([[
			SELECT date, app,
			       MAX(same_finger_streak_max) AS f_max,
			       MAX(same_hand_streak_max)   AS h_max,
			       SUM(auto_repeat_count)      AS ar_count
			FROM agg_app_day_ergo %s
			GROUP BY date, app
		]], date_filter())) do
			local a = _get(manifest, r.date, r.app)
			a.same_finger_streak_max = r.f_max or 0
			a.same_hand_streak_max   = r.h_max or 0
			a.auto_repeat_count      = r.ar_count or 0
		end
	end)

	-- agg_app_day_layouts.
	_safe_query("agg_app_day_layouts", function()
		for r in db:nrows(string.format([[
			SELECT date, app, layout, SUM(count) AS count
			FROM agg_app_day_layouts %s
			GROUP BY date, app, layout
		]], date_filter())) do
			local a = _get(manifest, r.date, r.app)
			a.layouts_seen[r.layout] = (a.layouts_seen[r.layout] or 0) + (r.count or 0)
		end
	end)

	-- agg_app_day_kc_hold.
	_safe_query("agg_app_day_kc_hold", function()
		for r in db:nrows(string.format([[
			SELECT date, app, keycode,
			       SUM(sum_ms) AS s, SUM(count) AS c, MAX(max_ms) AS mx,
			       SUM(tap_count) AS t, SUM(hold_count) AS h
			FROM agg_app_day_kc_hold %s
			GROUP BY date, app, keycode
		]], date_filter())) do
			local a = _get(manifest, r.date, r.app)
			a.kc_hold[tostring(r.keycode)] = {
				sum = r.s or 0, count = r.c or 0, max = r.mx or 0,
				tap = r.t or 0, hold = r.h or 0,
			}
		end
	end)

	-- agg_app_day_titles.
	_safe_query("agg_app_day_titles", function()
		for r in db:nrows(string.format([[
			SELECT date, app, title, SUM(c) AS c, SUM(ms) AS ms
			FROM agg_app_day_titles %s
			GROUP BY date, app, title
		]], date_filter())) do
			local a = _get(manifest, r.date, r.app)
			a.win_titles[r.title] = { c = r.c or 0, ms = r.ms or 0 }
		end
	end)

	-- agg_app_day_hourly.
	-- GROUP BY date, app, hour, e_buckets_json to avoid MIN(e_buckets_json) loss
	-- on multi-device installs; accumulate scalars and merge buckets in Lua.
	_safe_query("agg_app_day_hourly", function()
		for r in db:nrows(string.format([[
			SELECT date, app, hour,
			       SUM(c) AS c, SUM(e) AS e, SUM(em) AS em, SUM(es) AS es,
			       e_buckets_json
			FROM agg_app_day_hourly %s
			GROUP BY date, app, hour, e_buckets_json
		]], date_filter())) do
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
					h.e_buckets[k] = (h.e_buckets[k] or 0) + (v or 0)
				end
			end
		end
	end)

	-- agg_app_day_hourly_min5.
	-- Same multi-device fix: GROUP BY slot, e_buckets_json; accumulate in Lua.
	_safe_query("agg_app_day_hourly_min5", function()
		for r in db:nrows(string.format([[
			SELECT date, app, slot,
			       SUM(c) AS c, SUM(e) AS e, SUM(es) AS es,
			       e_buckets_json
			FROM agg_app_day_hourly_min5 %s
			GROUP BY date, app, slot, e_buckets_json
		]], date_filter())) do
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
					h.e_buckets[k] = (h.e_buckets[k] or 0) + (v or 0)
				end
			end
		end
	end)

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

--- Build a {c, bg, tg, …} dict matching the legacy `today_idx[app]` shape,
--- merged across every device for the requested date range and (optional)
--- app filter.
--- @param sqlite_path  string Path to db.sqlite.
--- @param start_date   string|nil Inclusive lower bound.
--- @param end_date     string|nil Inclusive upper bound.
--- @param selected_apps table|nil Array of allowed apps (nil = all).
--- @return table { c={tok→{c,t,e,hs,llm,o}}, bg=…, … }.
function M.read_ngrams(sqlite_path, start_date, end_date, selected_apps)
	local out = { c = {}, bg = {}, tg = {}, qg = {}, pg = {}, hx = {}, hp = {}, w = {}, sc = {}, sc_bg = {}, w_bg = {}, kc = {} }
	local db = _open(sqlite_path)
	if not db then return out end

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
			for r in db:nrows(string.format([[
				SELECT token,
				       SUM(c)  AS c,
				       SUM(td) AS t,
				       SUM(e)  AS e,
				       esrc_json
				FROM %s %s
				GROUP BY token, esrc_json
			]], tbl, where)) do
				local item = out[code][r.token]
				if not item then
					item = { c = 0, t = 0, e = 0, hs = 0, llm = 0, o = 0 }
					out[code][r.token] = item
				end
				item.c = item.c + (r.c or 0)
				item.t = item.t + (r.t or 0)
				item.e = item.e + (r.e or 0)
				local ok, src = pcall(json.decode, r.esrc_json or "{}")
				if ok and type(src) == "table" then
					item.hs  = item.hs  + (src.hotstring or 0)
					item.llm = item.llm + (src.llm       or 0)
					for k, v in pairs(src) do
						if k ~= "hotstring" and k ~= "llm" and k ~= "none" then
							item.o = item.o + (v or 0)
						end
					end
				end
			end
		end)
	end

	-- Shortcuts (counts only).
	_safe_query("ngram_shortcuts", function()
		for r in db:nrows(string.format([[
			SELECT token, SUM(c) AS c FROM ngram_shortcuts %s GROUP BY token
		]], where)) do
			out.sc[r.token] = { c = r.c or 0, t = 0, e = 0, hs = 0, llm = 0, o = 0 }
		end
	end)
	_safe_query("ngram_shortcut_bigrams", function()
		for r in db:nrows(string.format([[
			SELECT token, SUM(c) AS c FROM ngram_shortcut_bigrams %s GROUP BY token
		]], where)) do
			out.sc_bg[r.token] = { c = r.c or 0, t = 0, e = 0, hs = 0, llm = 0, o = 0 }
		end
	end)
	-- Keycodes.
	_safe_query("ngram_keycodes", function()
		for r in db:nrows(string.format([[
			SELECT keycode, SUM(c) AS c FROM ngram_keycodes %s GROUP BY keycode
		]], where)) do
			out.kc[tostring(r.keycode)] = { c = r.c or 0, t = 0, e = 0, hs = 0, llm = 0, o = 0 }
		end
	end)

	db:close()
	return out
end

--- Convenience wrapper: returns { historical = …, today = today_app_idx }
--- so the legacy metrics_typing JS can keep its split. `today_app_idx` is
--- shaped like `today_idx[app] = {c, bg, …}` for compatibility.
--- @param sqlite_path  string Path to db.sqlite.
--- @param start_date   string|nil
--- @param end_date     string|nil
--- @param selected_apps table|nil
--- @return table { historical = {c=,…}, today = {app→{c=,…}} }.
function M.read_range_split_today(sqlite_path, start_date, end_date, selected_apps)
	local today_str = os.date("%Y-%m-%d")
	-- `today` is a separate per-app projection for the live dashboard.  It must
	-- only participate when the requested inclusive range actually covers today;
	-- otherwise changing the date filter to a historical day leaks current keys
	-- into the displayed totals.
	local includes_today = (not start_date or start_date == "" or start_date <= today_str)
		and (not end_date or end_date == "" or end_date >= today_str)
	local hist_end  = end_date
	if hist_end == nil or hist_end == "" or hist_end >= today_str then
		hist_end = nil  -- caller wants "up to today"; we still split
	end

	-- Historical: anything strictly before today.
	-- Compute yesterday via os.time subtraction to avoid manual day arithmetic that
	-- produces invalid dates on the 1st of a month (2026-01-00, 2026-03-00, …).
	local yesterday_str = os.date("%Y-%m-%d", os.time() - 86400)
	local historical = M.read_ngrams(sqlite_path, start_date,
		(hist_end and hist_end < today_str) and hist_end or yesterday_str,
		selected_apps)

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
				for r in db:nrows(string.format([[
					SELECT app, token,
					       SUM(c) AS c, SUM(td) AS t, SUM(e) AS e,
					       esrc_json
					FROM %s
					WHERE date = %s %s
					GROUP BY app, token, esrc_json
				]], tbl, _q(today_str), app_clause)) do
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
					local ok, src = pcall(json.decode, r.esrc_json or "{}")
					if ok and type(src) == "table" then
						item.hs  = item.hs  + (src.hotstring or 0)
						item.llm = item.llm + (src.llm       or 0)
						for k, v in pairs(src) do
							if k ~= "hotstring" and k ~= "llm" and k ~= "none" then
								item.o = item.o + (v or 0)
							end
						end
					end
					today_idx[r.app][code][r.token] = item
				end
			end)
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
			for r in db:nrows(string.format([[
				SELECT app, keycode, SUM(c) AS c FROM ngram_keycodes
				WHERE date = %s %s GROUP BY app, keycode
			]], _q(today_str), app_clause)) do
				_today_bucket(r.app).kc[tostring(r.keycode)] =
					{ c = r.c or 0, t = 0, e = 0, hs = 0, llm = 0, o = 0 }
			end
		end)

		_safe_query("ngram_shortcuts(today)", function()
			for r in db:nrows(string.format([[
				SELECT app, token, SUM(c) AS c FROM ngram_shortcuts
				WHERE date = %s %s GROUP BY app, token
			]], _q(today_str), app_clause)) do
				_today_bucket(r.app).sc[r.token] =
					{ c = r.c or 0, t = 0, e = 0, hs = 0, llm = 0, o = 0 }
			end
		end)

		_safe_query("ngram_shortcut_bigrams(today)", function()
			for r in db:nrows(string.format([[
				SELECT app, token, SUM(c) AS c FROM ngram_shortcut_bigrams
				WHERE date = %s %s GROUP BY app, token
			]], _q(today_str), app_clause)) do
				_today_bucket(r.app).sc_bg[r.token] =
					{ c = r.c or 0, t = 0, e = 0, hs = 0, llm = 0, o = 0 }
			end
		end)

		db:close()
	end

	return { historical = historical, today = today_idx }
end


return M
