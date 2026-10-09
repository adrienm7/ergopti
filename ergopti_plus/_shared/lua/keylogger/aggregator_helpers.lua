--- _shared/lua/keylogger/aggregator_helpers.lua
---
--- Pure, driver-agnostic aggregator walk functions extracted from the macOS
--- aggregator (modules/keylogger/aggregator/core.lua). Every function that
--- previously mutated shared state via the S singleton now takes the mutable
--- tables as explicit parameters. This module has ZERO driver dependencies.
---
--- Shared by macOS (Hammerspoon), Linux (LuaJIT), and any future driver.

local M = {}

local Utils = require("keylogger.utils")

-- ============================================================================
-- 1. Constants (shared across all drivers)
-- ============================================================================

--- Bucket thresholds (ms) for the "ignore pauses longer than…" UI dropdown.
M.UI_PAUSE_BUCKETS_MS = { 1000, 2000, 3000, 5000, 10000, 20000, 30000, 60000 }

--- Burst length histogram boundaries. Last bucket is open-ended ("500+").
M.BURST_LENGTH_BUCKETS = { 1, 5, 10, 20, 50, 100, 200, 500 }

--- Minimum chars in a burst to count toward the max-CPM record.
M.MIN_BURST_FOR_CPM = 10

--- Maximum session durations stored per (device,date,app).
M.SESSION_DURATIONS_CAP = 100

--- Window-titles cap per (device,date,app).
M.TITLE_CAP_PER_APP_DAY = 100

--- A run of ≥ N consecutive manual backspaces counts as one cascade.
M.CASCADE_MIN_BS = 3

--- Lookback ring buffer length for HS / LLM trigger-time reclassification.
M.TRIGGER_LOOKBACK_LEN = 50

--- Keycodes counted as "content" for same-finger/same-hand streak tracking.
M.CONTENT_KCS = {
	0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11,
	12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,
	25, 26, 28, 29, 31, 32, 34, 35, 37, 38, 40, 41, 43, 44, 45, 46, 47,
}

-- ============================================================================
-- 2. Batch factory
-- ============================================================================

--- Creates a fresh, empty per-tick accumulator batch table.
--- Each driver calls this on init and on day rollover.
--- @return table A new batch table with all sub-tables pre-initialised.
function M.new_batch()
	return {
		app_day      = {},
		ngram        = {
			ngram_chars        = {},
			ngram_bigrams      = {},
			ngram_trigrams     = {},
			ngram_quadgrams    = {},
			ngram_pentagrams   = {},
			ngram_hexagrams    = {},
			ngram_heptagrams   = {},
			ngram_words        = {},
			ngram_word_bigrams = {},
		},
		kc_ngram     = {},
		sc_ngram     = { ngram_shortcuts = {}, ngram_shortcut_bigrams = {} },
		kc_hold      = {},
		titles       = {},
		hourly       = {},
		hourly_min5  = {},
		layouts      = {},
		chars_class  = {},
		errors       = {},
		ergo         = {},
		bursts       = {},
		sessions     = {},
		app_buckets  = {},
		system_day   = {},
		app_time     = {},
		switches_to  = {},
	}
end

-- ============================================================================
-- 3. Table helpers
-- ============================================================================

--- Get-or-create a sub-table at `tbl[k]`, delegating to the shared utils module.
--- @param tbl     table   Parent table.
--- @param k       any     Key to look up.
--- @param default table|nil  Default value if absent.
--- @return table  The existing or freshly-inserted sub-table.
function M.gc(tbl, k, default)
	return Utils.gc(tbl, k, default)
end

-- ============================================================================
-- 4. Bucket accumulator
-- ============================================================================

--- Cumulative bucket accumulator — adds `value` to every bucket ≥ `delay`.
--- @param target_map table Map of bucket_ms-string → count.
--- @param delay      number Inter-keystroke delay in ms.
--- @param value      number Amount to add.
--- @param buckets    table|nil  Bucket thresholds (defaults to M.UI_PAUSE_BUCKETS_MS).
function M.bucket_add(target_map, delay, value, buckets)
	buckets = buckets or M.UI_PAUSE_BUCKETS_MS
	for _, t in ipairs(buckets) do
		if delay <= t then
			local k = tostring(t)
			target_map[k] = (target_map[k] or 0) + value
		end
	end
end

-- ============================================================================
-- 5. Burst helpers
-- ============================================================================

--- Burst length bucket label.
--- @param n       number Burst character count.
--- @param buckets table|nil  Bucket boundaries (defaults to M.BURST_LENGTH_BUCKETS).
--- @return string Bucket boundary as a string, or "500+".
function M.burst_length_bucket(n, buckets)
	buckets = buckets or M.BURST_LENGTH_BUCKETS
	for _, b in ipairs(buckets) do
		if n <= b then return tostring(b) end
	end
	if buckets and #buckets > 0 then
		return tostring(buckets[#buckets]) .. "+"
	end
	return "500+"
end

--- Finalise a burst object and merge it into the batch.
--- @param agg_batch    table  The mutable batch table (S.agg_batch).
--- @param date_str     string "YYYY-MM-DD".
--- @param app          string Application name.
--- @param burst_cursor table|nil Burst cursor, or nil if no burst was open.
--- @param min_burst_for_cpm number|nil Minimum chars for CPM record (default M.MIN_BURST_FOR_CPM).
function M.finalize_burst(agg_batch, date_str, app, burst_cursor, min_burst_for_cpm)
	if not burst_cursor or burst_cursor.char_count <= 0 then return end
	local min_cpm = min_burst_for_cpm or M.MIN_BURST_FOR_CPM
	local key = date_str .. "\1" .. app
	local r = M.gc(agg_batch.bursts, key, {
		date = date_str, app = app,
		count_total = 0, max_cpm = 0, max_chars = 0,
		length_buckets = {}, inter_count = 0, inter_sum = 0, inter_sumsq = 0,
	})
	r.count_total = r.count_total + 1
	if burst_cursor.char_count > r.max_chars then
		r.max_chars = burst_cursor.char_count
	end
	if burst_cursor.char_count >= min_cpm and burst_cursor.sum_delays > 0 then
		local cpm = burst_cursor.char_count * 60000 / burst_cursor.sum_delays
		if cpm > r.max_cpm then r.max_cpm = cpm end
	end
	local k = M.burst_length_bucket(burst_cursor.char_count)
	r.length_buckets[k] = (r.length_buckets[k] or 0) + 1
	r.inter_count = r.inter_count + math.max(0, burst_cursor.char_count - 1)
	r.inter_sum   = r.inter_sum   + burst_cursor.sum_delays
	r.inter_sumsq = r.inter_sumsq + burst_cursor.sum_delays_sq
end

-- ============================================================================
-- 6. Session helpers
-- ============================================================================

--- Finalise a session object and merge it into the batch.
--- @param agg_batch    table  The mutable batch table (S.agg_batch).
--- @param date_str     string "YYYY-MM-DD".
--- @param app          string Application name.
--- @param session_cursor table|nil Session cursor, or nil if no session was open.
--- @param durations_cap number|nil Max durations stored (default M.SESSION_DURATIONS_CAP).
function M.finalize_session(agg_batch, date_str, app, session_cursor, durations_cap)
	if not session_cursor or session_cursor.char_count <= 0 then return end
	local cap = durations_cap or M.SESSION_DURATIONS_CAP
	local key = date_str .. "\1" .. app
	local r = M.gc(agg_batch.sessions, key, {
		date = date_str, app = app,
		count_total = 0, longest_ms = 0, longest_chars = 0, total_active_ms = 0,
		durations = {},
	})
	r.count_total = r.count_total + 1
	if session_cursor.total_ms   > r.longest_ms    then r.longest_ms    = session_cursor.total_ms   end
	if session_cursor.char_count > r.longest_chars then r.longest_chars = session_cursor.char_count end
	r.total_active_ms = r.total_active_ms + session_cursor.total_ms
	if #r.durations < cap then
		table.insert(r.durations, session_cursor.total_ms)
	end
end

-- ============================================================================
-- 7. N-gram helpers
-- ============================================================================

--- Bump a metric in the batch ngram dict.
--- @param agg_batch   table  The mutable batch table.
--- @param table_name  string Key in agg_batch.ngram.
--- @param key         string Compound row key (date·app·token).
--- @param delay       number Inter-keystroke delay in ms.
--- @param is_error    boolean True if this is an error event.
--- @param synth_type  string Synthetic type tag ("hotstring", "llm", "none", …).
function M.add_ngram_metric(agg_batch, table_name, key, delay, is_error, synth_type)
	local tbl = agg_batch.ngram[table_name]
	if not tbl then return end
	local item = tbl[key]
	if not item then
		item = { c = 0, td = 0, cd = 0, e = 0, esrc = {} }
		tbl[key] = item
	end
	if is_error then
		item.e = item.e + 1
		if synth_type and synth_type ~= "none" then
			item.esrc[synth_type] = (item.esrc[synth_type] or 0) + 1
		end
	else
		item.c = item.c + 1
		if synth_type == "hotstring" or synth_type == "llm" or (synth_type and synth_type ~= "none") then
			item.esrc[synth_type] = (item.esrc[synth_type] or 0) + 1
		elseif delay > 0 then
			item.td = item.td + delay
			item.cd = item.cd + 1
		end
	end
end

--- Store an n-gram tuple keyed by (date,app,token).
--- @param agg_batch   table  The mutable batch table.
--- @param table_name  string Key in agg_batch.ngram.
--- @param date_str    string "YYYY-MM-DD".
--- @param app         string Application name.
--- @param token       string The n-gram token.
--- @param delay       number Inter-keystroke delay in ms.
--- @param is_error    boolean True if this is an error event.
--- @param synth_type  string Synthetic type tag.
function M.push_ngram(agg_batch, table_name, date_str, app, token, delay, is_error, synth_type)
	local key = date_str .. "\1" .. app .. "\1" .. token
	M.add_ngram_metric(agg_batch, table_name, key, delay, is_error, synth_type)
end

-- ============================================================================
-- 8. App-day helpers
-- ============================================================================

--- Bump a per-app-day numeric counter on agg_batch.app_day.
--- @param agg_batch table  The mutable batch table.
--- @param date_str  string "YYYY-MM-DD".
--- @param app       string Application name.
--- @param field     string Field name to increment.
--- @param value     number Amount to add.
function M.bump_app_day(agg_batch, date_str, app, field, value)
	local key = date_str .. "\1" .. app
	local row = M.gc(agg_batch.app_day, key, { date = date_str, app = app })
	row[field] = (row[field] or 0) + value
end

-- ============================================================================
-- 9. Per-app context
-- ============================================================================

--- Get-or-create the n-gram context entry for an app.
--- @param ngram_ctx table  The mutable ngram context table (S.ngram_ctx).
--- @param app       string Application name.
--- @return table Per-app context (n-gram state, burst/session cursors, etc.).
function M.get_app_ctx(ngram_ctx, app)
	if not ngram_ctx then return {} end
	local c = ngram_ctx[app]
	if not c then
		c = {
			p1 = nil, p2 = nil, p3 = nil, p4 = nil, p5 = nil, p6 = nil,
			cur_word = "", word_err = false, hist = {},
			prev_word = nil, prev_sc = nil,
			recent_typing = {},
			current_burst = nil, current_session = nil,
			bs_run_len = 0, last_was_bs = false,
			last_finger = nil, same_finger_run = 0, same_hand_run = 0,
			last_char = nil,
		}
		ngram_ctx[app] = c
	end
	return c
end

return M
