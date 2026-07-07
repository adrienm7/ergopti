--- modules/keylogger/aggregator/core.lua

--- ==============================================================================
--- MODULE: Aggregator Core — Constants, Helpers, Batch Management
--- DESCRIPTION:
--- Exports all timing constants, pure helper utilities, per-tick batch
--- management, and the N-gram context accessors used by the aggregator
--- sub-modules. This module owns the mutable state singleton via
--- aggregator/state.lua (Lua module cache guarantees a single shared table).
---
--- MIRRORS: windows/modules/keylogger/keylogger_walker_core.ahk
--- ==============================================================================

local M = {}

local hs      = hs
local utf8    = utf8
local Logger  = require("lib.logger")
local Paths   = require("lib.paths")
local Timings = require("lib.timings")
local KUtils  = require("keylogger.utils")
local LOG     = "keylogger.aggregator"

local S = require("modules.keylogger.aggregator.state")





-- ==============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ==============================

-- The keystroke-timing thresholds below come from the shared cross-driver
-- registry ([keylogger]) so the AHK and macOS keyloggers classify identically.
--- Threshold separating "active typing" from "thinking pauses".
local THINK_PAUSE_THRESHOLD_MS = Timings.ms("keylogger", "think_pause_ms")

--- A pause longer than this between keystrokes breaks N-gram continuity.
local MAX_KEYSTROKE_DELAY_MS = Timings.ms("keylogger", "max_keystroke_delay_ms")

--- Bucket thresholds (ms) for the "ignore pauses longer than…" UI dropdown.
local UI_PAUSE_BUCKETS_MS = { 1000, 2000, 3000, 5000, 10000, 20000, 30000, 60000 }

--- Lookback ring buffer length for HS / LLM trigger-time reclassification.
local TRIGGER_LOOKBACK_LEN = 50

--- A "burst" closes when the inter-keydown gap exceeds this.
local BURST_GAP_MS = Timings.ms("keylogger", "burst_gap_ms")

--- Minimum chars in a burst to count toward the max-CPM record.
local MIN_BURST_FOR_CPM = 10

--- A "session" closes when the inter-keydown gap exceeds this (5 min).
local SESSION_GAP_MS = Timings.ms("keylogger", "session_gap_ms")

--- Burst length histogram boundaries. Last bucket is open-ended ("500+").
local BURST_LENGTH_BUCKETS = { 1, 5, 10, 20, 50, 100, 200, 500 }

--- Maximum session durations stored per (device,date,app).
local SESSION_DURATIONS_CAP = 100

--- Auto-repeat detection threshold (macOS auto-repeat fires every ~30 ms).
local AUTO_REPEAT_MAX_DELAY_MS = Timings.ms("keylogger", "auto_repeat_max_delay_ms")

--- A run of ≥ N consecutive manual backspaces counts as one cascade.
local CASCADE_MIN_BS = 3

--- Tap vs hold threshold for kc_hold tracking.
local HOLD_THRESHOLD_MS = Timings.ms("keylogger", "hold_threshold_ms")

--- Window-titles cap per (device,date,app).
local TITLE_CAP_PER_APP_DAY = 100

--- Keycodes counted as "content" for same-finger/same-hand streak tracking —
--- deliberately excludes modifiers, function keys, arrows, space, and a
--- handful of punctuation/dead-key keycodes, so they do not break a streak in
--- the middle (see the nil short-circuit at the KC_TO_FINGER lookup site,
--- events.lua ~line 301). This is analysis scope, not layout data, so it stays
--- local rather than living in azerty.json.
local CONTENT_KCS = {
	0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11,
	12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,
	25, 26, 28, 29, 31, 32, 34, 35, 37, 38, 40, 41, 43, 44, 45, 46, 47,
}

--- Emergency-only fallback used when the shared azerty.json catalogue cannot
--- be read/parsed, so a transient I/O failure degrades streak-tracking
--- accuracy instead of crashing the aggregator. Values mirror CONTENT_KCS.
local FALLBACK_KC_TO_FINGER = {
	[0]="r_pinky",[1]="r_ring",[2]="r_mid",[3]="r_idx",[4]="l_idx",[5]="r_idx",
	[6]="r_ring",[7]="r_mid",[8]="r_idx",[9]="r_idx",[11]="r_idx",
	[12]="r_pinky",[13]="r_ring",[14]="r_mid",[15]="r_idx",[16]="l_idx",[17]="r_idx",
	[18]="r_pinky",[19]="r_ring",[20]="r_mid",[21]="r_idx",[22]="l_idx",[23]="r_idx",
	[25]="l_ring",[26]="l_idx",[28]="l_mid",[29]="l_pinky",
	[31]="l_ring",[32]="l_idx",[34]="l_mid",[35]="l_pinky",
	[37]="l_ring",[38]="l_idx",[40]="l_mid",[41]="l_pinky",
	[43]="l_mid",[44]="l_pinky",[45]="l_idx",[46]="l_idx",[47]="l_ring",
}

--- Reads the shared azerty.json keycode catalogue (the same file the JS
--- typing-heatmap's KEYCODE_DATA is generated from, DC-1) and returns a
--- {kc=finger} lookup restricted to CONTENT_KCS, or nil on failure.
--- @return table<number,string>|nil
local function load_shared_kc_to_finger()
	local path = Paths.shared("data/keycodes/azerty.json")
	if type(path) ~= "string" or path == "" then return nil end
	local fh = io.open(path, "r")
	if not fh then return nil end
	local content = fh:read("*a")
	fh:close()
	if type(content) ~= "string" or content == "" then return nil end
	-- Strip a leading UTF-8 BOM — hs.json.decode rejects it.
	if content:sub(1, 3) == "\239\187\191" then content = content:sub(4) end
	local ok, data = pcall(hs.json.decode, content)
	if not ok or type(data) ~= "table" or type(data.keys) ~= "table" then return nil end

	local wanted = {}
	for _, kc in ipairs(CONTENT_KCS) do wanted[kc] = true end

	local out = {}
	for _, entry in ipairs(data.keys) do
		if type(entry) == "table" and wanted[entry.kc] and type(entry.finger) == "string" then
			out[entry.kc] = entry.finger
		end
	end
	return out
end

--- macOS virtual-keycode → finger column, derived from the shared azerty.json
--- catalogue instead of a hand-copied literal (DC-1). Restricted to CONTENT_KCS.
local KC_TO_FINGER = load_shared_kc_to_finger()
if not KC_TO_FINGER or next(KC_TO_FINGER) == nil then
	Logger.warn(LOG, "Shared azerty.json keycode catalogue unreadable — using emergency fallback finger map.")
	KC_TO_FINGER = FALLBACK_KC_TO_FINGER
end

-- Export constants so events.lua and sql.lua can reference them via C.*
M.THINK_PAUSE_THRESHOLD_MS = THINK_PAUSE_THRESHOLD_MS
M.MAX_KEYSTROKE_DELAY_MS   = MAX_KEYSTROKE_DELAY_MS
M.UI_PAUSE_BUCKETS_MS      = UI_PAUSE_BUCKETS_MS
M.TRIGGER_LOOKBACK_LEN     = TRIGGER_LOOKBACK_LEN
M.BURST_GAP_MS             = BURST_GAP_MS
M.SESSION_GAP_MS           = SESSION_GAP_MS
M.AUTO_REPEAT_MAX_DELAY_MS = AUTO_REPEAT_MAX_DELAY_MS
M.CASCADE_MIN_BS           = CASCADE_MIN_BS
M.HOLD_THRESHOLD_MS        = HOLD_THRESHOLD_MS
M.TITLE_CAP_PER_APP_DAY    = TITLE_CAP_PER_APP_DAY
M.KC_TO_FINGER             = KC_TO_FINGER





-- ===========================
-- =========================
-- ======= 2/ Guards =======
-- =========================
-- ===========================

--- Guards public functions against being called before M.init().
--- @param func_name string Name of the calling function for the error log.
--- @return boolean False if not yet initialized.
function M.require_init(func_name)
	if not S.initialized then
		Logger.error(LOG, "'%s' called before M.init() — module non-functional.", func_name)
		return false
	end
	return true
end

--- Returns today's "YYYY-MM-DD" date string.
--- @return string Current date.
function M.today()
	return os.date("%Y-%m-%d")
end





-- ====================================
-- ===================================
-- ======= 3/ Batch Management =======
-- ===================================
-- ====================================

--- Reset / initialise the per-tick accumulator batch.
local function reset_batch_impl()
	S.agg_batch = {
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

--- Ensure S.agg_batch is ready; called lazily from walk functions.
function M.ensure_batch()
	if not S.agg_batch then reset_batch_impl() end
end

--- Public reset used by M.init and by the log manager on day rollover.
function M.reset_batch()
	reset_batch_impl()
end

--- Return the ngram context table so the log manager can serialise it.
--- @return table The live S.ngram_ctx table (may be nil before first event).
function M.get_ngram_ctx()
	return S.ngram_ctx
end

--- Restore the ngram context from a decoded JSON table (called on startup).
--- @param ctx table Previously serialised context, or {} on a fresh start.
function M.set_ngram_ctx(ctx)
	S.ngram_ctx = (type(ctx) == "table") and ctx or {}
end

--- Reset the ngram context (called on day rollover).
function M.reset_ngram_ctx()
	S.ngram_ctx = {}
end





-- ================================
-- ===============================
-- ======= 4/ Walk Helpers =======
-- ===============================
-- ================================

--- Delegates to the shared keylogger/utils module.
function M.gc(tbl, k, default)
	return KUtils.gc(tbl, k, default)
end

--- Cumulative bucket accumulator — adds `value` to every bucket ≥ `delay`.
--- @param target_map table Map of bucket_ms-string → count.
--- @param delay number Inter-keystroke delay in ms.
--- @param value number Amount to add.
function M.bucket_add(target_map, delay, value)
	for _, t in ipairs(UI_PAUSE_BUCKETS_MS) do
		if delay <= t then
			local k = tostring(t)
			target_map[k] = (target_map[k] or 0) + value
		end
	end
end

--- Burst length bucket label.
--- @param n number Burst character count.
--- @return string Bucket boundary as a string, or "500+".
function M.burst_length_bucket(n)
	for _, b in ipairs(BURST_LENGTH_BUCKETS) do
		if n <= b then return tostring(b) end
	end
	return "500+"
end

--- Delegates to the shared keylogger/utils module.
function M.char_class(c)
	return KUtils.char_class(c)
end

--- Delegates to the shared keylogger/utils module.
function M.pop_utf8(s)
	return KUtils.pop_utf8(s)
end

--- Get-or-create the n-gram context entry for an app.
--- @param app string Application name.
--- @return table Per-app context (n-gram state, burst/session cursors, etc.).
function M.get_app_ctx(app)
	if not S.ngram_ctx then S.ngram_ctx = {} end
	local c = S.ngram_ctx[app]
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
		S.ngram_ctx[app] = c
	end
	return c
end

--- Bump a metric in the batch ngram dict.
--- @param table_name string Key in S.agg_batch.ngram.
--- @param key string Compound row key (date·app·token).
--- @param delay number Inter-keystroke delay in ms.
--- @param is_error boolean True if this is an error event.
--- @param synth_type string Synthetic type tag ("hotstring", "llm", "none", …).
function M.add_ngram_metric(table_name, key, delay, is_error, synth_type)
	local tbl = S.agg_batch.ngram[table_name]
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
--- @param table_name string Key in S.agg_batch.ngram.
--- @param date_str string "YYYY-MM-DD".
--- @param app string Application name.
--- @param token string The n-gram token.
--- @param delay number Inter-keystroke delay in ms.
--- @param is_error boolean True if this is an error event.
--- @param synth_type string Synthetic type tag.
function M.push_ngram(table_name, date_str, app, token, delay, is_error, synth_type)
	local key = date_str .. "\1" .. app .. "\1" .. token
	M.add_ngram_metric(table_name, key, delay, is_error, synth_type)
end

--- Bump a per-app-day numeric counter on S.agg_batch.app_day.
--- @param date_str string "YYYY-MM-DD".
--- @param app string Application name.
--- @param field string Field name to increment.
--- @param value number Amount to add.
function M.bump_app_day(date_str, app, field, value)
	local key = date_str .. "\1" .. app
	local row = M.gc(S.agg_batch.app_day, key, { date = date_str, app = app })
	row[field] = (row[field] or 0) + value
end





-- ========================================
-- ==========================================
-- ======= 5/ Burst / Session Helpers =======
-- ==========================================
-- ========================================

--- Finalise a burst object and merge it into the batch.
--- @param date_str string "YYYY-MM-DD".
--- @param app string Application name.
--- @param b table|nil Burst cursor, or nil if no burst was open.
function M.finalize_burst(date_str, app, b)
	if not b or b.char_count <= 0 then return end
	local key = date_str .. "\1" .. app
	local r = M.gc(S.agg_batch.bursts, key, {
		date = date_str, app = app,
		count_total = 0, max_cpm = 0, max_chars = 0,
		length_buckets = {}, inter_count = 0, inter_sum = 0, inter_sumsq = 0,
	})
	r.count_total = r.count_total + 1
	if b.char_count > r.max_chars then r.max_chars = b.char_count end
	if b.char_count >= MIN_BURST_FOR_CPM and b.sum_delays > 0 then
		local cpm = b.char_count * 60000 / b.sum_delays
		if cpm > r.max_cpm then r.max_cpm = cpm end
	end
	local k = M.burst_length_bucket(b.char_count)
	r.length_buckets[k] = (r.length_buckets[k] or 0) + 1
	r.inter_count = r.inter_count + math.max(0, b.char_count - 1)
	r.inter_sum   = r.inter_sum   + b.sum_delays
	r.inter_sumsq = r.inter_sumsq + b.sum_delays_sq
end

--- Finalise a session object and merge it into the batch.
--- @param date_str string "YYYY-MM-DD".
--- @param app string Application name.
--- @param s table|nil Session cursor, or nil if no session was open.
function M.finalize_session(date_str, app, s)
	if not s or s.char_count <= 0 then return end
	local key = date_str .. "\1" .. app
	local r = M.gc(S.agg_batch.sessions, key, {
		date = date_str, app = app,
		count_total = 0, longest_ms = 0, longest_chars = 0, total_active_ms = 0,
		durations = {},
	})
	r.count_total = r.count_total + 1
	if s.total_ms   > r.longest_ms    then r.longest_ms    = s.total_ms   end
	if s.char_count > r.longest_chars then r.longest_chars = s.char_count end
	r.total_active_ms = r.total_active_ms + s.total_ms
	if #r.durations < SESSION_DURATIONS_CAP then
		table.insert(r.durations, s.total_ms)
	end
end

return M
