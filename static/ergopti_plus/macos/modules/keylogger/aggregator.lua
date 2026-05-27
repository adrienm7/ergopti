--- modules/keylogger/aggregator.lua

--- ==============================================================================
--- MODULE: Keylogger Aggregator
--- DESCRIPTION:
--- Stateful walking and batch-flushing layer for the keylogger ingest pipeline.
--- Replays JSONL events into per-tick in-memory batches of UPSERT deltas, then
--- writes them atomically to the SQLite aggregate tables at the end of each
--- ingest tick.
---
--- DESIGN:
--- The walking functions (_walk_typing_entry, _walk_app_switch, etc.) are the
--- Lua port of the legacy aggregate_events() Python pipeline. They accumulate
--- deltas in _agg_batch without touching SQLite. _flush() drains the batch
--- into every agg_* table via ON CONFLICT … DO UPDATE statements.
---
--- N-gram context (_ngram_ctx) persists across ticks in RAM; it is serialised
--- to meta.ngram_ctx_json by the log manager at the end of each successful
--- ingest transaction so a crash mid-tick does not lose partial state.
---
--- DEPENDENCIES:
--- - lib.logger (project-wide logger).
--- - hs.json, hs.sqlite3.
--- - sqlite_writer (for SqliteWriter.get_db() handle).
--- - export (for Export.get_native_app_category()).
--- ==============================================================================

local M = {}

local hs      = hs
local json    = require("hs.json")
local sqlite3 = require("hs.sqlite3")
local utf8    = utf8

local Logger = require("lib.logger")
local LOG    = "keylogger.aggregator"

local SqliteWriter = require("modules.keylogger.sqlite_writer")
local Export       = require("modules.keylogger.export")




-- ==============================
--- ============================
-- ======= 1/ Constants =======
--- ============================
-- ==============================

--- Threshold separating "active typing" from "thinking pauses".
local THINK_PAUSE_THRESHOLD_MS = 2000

--- A pause longer than this between keystrokes breaks N-gram continuity.
local MAX_KEYSTROKE_DELAY_MS = 5000

--- Bucket thresholds (ms) for the "ignore pauses longer than…" UI dropdown.
local UI_PAUSE_BUCKETS_MS = { 1000, 2000, 3000, 5000, 10000, 20000, 30000, 60000 }

--- Lookback ring buffer length for HS / LLM trigger-time reclassification.
local TRIGGER_LOOKBACK_LEN = 50

--- A "burst" closes when the inter-keydown gap exceeds this.
local BURST_GAP_MS = 1000

--- Minimum chars in a burst to count toward the max-CPM record.
local MIN_BURST_FOR_CPM = 10

--- A "session" closes when the inter-keydown gap exceeds this (5 min).
local SESSION_GAP_MS = 300000

--- Burst length histogram boundaries. Last bucket is open-ended ("500+").
local BURST_LENGTH_BUCKETS = { 1, 5, 10, 20, 50, 100, 200, 500 }

--- Maximum session durations stored per (device,date,app).
local SESSION_DURATIONS_CAP = 100

--- Auto-repeat detection threshold (macOS auto-repeat fires every ~30 ms).
local AUTO_REPEAT_MAX_DELAY_MS = 50

--- A run of ≥ N consecutive manual backspaces counts as one cascade.
local CASCADE_MIN_BS = 3

--- Tap vs hold threshold for kc_hold tracking.
local HOLD_THRESHOLD_MS = 250

--- Window-titles cap per (device,date,app).
local TITLE_CAP_PER_APP_DAY = 100

--- macOS virtual-keycode → finger column. Kept in sync with KEYCODE_DATA in
--- ui/metrics_typing/state.js. Only "content" keys are listed; modifiers are
--- intentionally absent so they do not break a streak in the middle.
local KC_TO_FINGER = {
	[0]="r_pinky",[1]="r_ring",[2]="r_mid",[3]="r_idx",[4]="l_idx",[5]="r_idx",
	[6]="r_ring",[7]="r_mid",[8]="r_idx",[9]="r_idx",[11]="r_idx",
	[12]="r_pinky",[13]="r_ring",[14]="r_mid",[15]="r_idx",[16]="l_idx",[17]="r_idx",
	[18]="r_pinky",[19]="r_ring",[20]="r_mid",[21]="r_idx",[22]="l_idx",[23]="r_idx",
	[25]="l_ring",[26]="l_idx",[28]="l_mid",[29]="l_pinky",
	[31]="l_ring",[32]="l_idx",[34]="l_mid",[35]="l_pinky",
	[37]="l_ring",[38]="l_idx",[40]="l_mid",[41]="l_pinky",
	[43]="l_mid",[44]="l_pinky",[45]="l_idx",[46]="l_idx",[47]="l_ring",
}




-- ===============================
--- ===============================
-- ======= 2/ Module State =======
--- ===============================
-- ===============================

--- Device id injected by M.init().
local _device_id = nil

--- Whether M.init() has been called.
local _initialized = false

--- Per-app n-gram + burst + session walking context. Survives ingest ticks;
--- reset at day rollover. Serialised to meta.ngram_ctx_json by the caller.
local _ngram_ctx = nil

--- Per-tick batch of pending UPSERTs. Cleared after M.flush().
local _agg_batch = nil




-- ============================================
--- =========================
-- ======= 3/ Guards =======
--- =========================
-- ============================================

--- Guards public functions against being called before M.init().
local function _require_init(func_name)
	if not _initialized then
		Logger.error(LOG, "'%s' called before M.init() — module non-functional.", func_name)
		return false
	end
	return true
end

--- Returns today's "YYYY-MM-DD" date string.
local function _today()
	return os.date("%Y-%m-%d")
end




-- ===================================
--- ===================================
-- ======= 4/ Batch Management =======
--- ===================================
-- ===================================

--- Reset / initialise the per-tick accumulator batch.
local function _reset_batch()
	_agg_batch = {
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

--- Ensure _agg_batch is ready; called lazily from walk functions.
local function _ensure_batch()
	if not _agg_batch then _reset_batch() end
end

--- Public reset used by M.init and by the log manager on day rollover.
function M.reset_batch()
	_reset_batch()
end

--- Return the ngram context table so the log manager can serialise it.
--- @return table The live _ngram_ctx table (may be nil before first event).
function M.get_ngram_ctx()
	return _ngram_ctx
end

--- Restore the ngram context from a decoded JSON table (called on startup).
--- @param ctx table Previously serialised context, or {} on a fresh start.
function M.set_ngram_ctx(ctx)
	_ngram_ctx = (type(ctx) == "table") and ctx or {}
end

--- Reset the ngram context (called on day rollover).
function M.reset_ngram_ctx()
	_ngram_ctx = {}
end




-- =================================
--- ===============================
-- ======= 5/ Walk Helpers =======
--- ===============================
-- =================================

--- Get-or-create a sub-table at `tbl[k]`.
local function _gc(tbl, k, default)
	local v = tbl[k]
	if not v then
		v = default or {}
		tbl[k] = v
	end
	return v
end

--- Cumulative bucket accumulator.
local function _bucket_add(target_map, delay, value)
	for _, t in ipairs(UI_PAUSE_BUCKETS_MS) do
		if delay <= t then
			local k = tostring(t)
			target_map[k] = (target_map[k] or 0) + value
		end
	end
end

--- Burst length bucket label.
local function _burst_length_bucket(n)
	for _, b in ipairs(BURST_LENGTH_BUCKETS) do
		if n <= b then return tostring(b) end
	end
	return "500+"
end

--- UTF-8-aware character classifier.
local function _char_class(c)
	if not c or #c == 0 then return "other" end
	if c == " " or c == "\t" or c == "\n" or c == "\194\160" or c == "\226\128\175" then
		return "space"
	end
	local b = c:byte(1)
	if b >= 48 and b <= 57 then return "digit" end
	if (b >= 65 and b <= 90) or (b >= 97 and b <= 122) then return "letter" end
	if b >= 0xC2 and b <= 0xCF then return "letter" end
	if b >= 0xD0 and b <= 0xD7 then return "letter" end
	if c:sub(1, 1) == "[" and c:sub(-1) == "]" then return "other" end
	if c:match("^[%p<>=+%*/\\|%-]$") then return "punct" end
	return "other"
end

--- Pop the last UTF-8 codepoint off a string.
local function _pop_utf8(s)
	if not s or #s == 0 then return s or "" end
	local ok, off = pcall(utf8.offset, s, -1)
	if not ok or not off then return s:sub(1, -2) end
	return s:sub(1, off - 1)
end

--- Get-or-create the n-gram context entry for an app.
local function _get_app_ctx(app)
	if not _ngram_ctx then _ngram_ctx = {} end
	local c = _ngram_ctx[app]
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
		_ngram_ctx[app] = c
	end
	return c
end

--- Bump a metric in the batch ngram dict.
local function _add_ngram_metric(table_name, key, delay, is_error, synth_type)
	local tbl = _agg_batch.ngram[table_name]
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
local function _push_ngram(table_name, date_str, app, token, delay, is_error, synth_type)
	local key = date_str .. "\1" .. app .. "\1" .. token
	_add_ngram_metric(table_name, key, delay, is_error, synth_type)
end

--- Bump a per-app-day numeric counter on _agg_batch.app_day.
local function _bump_app_day(date_str, app, field, value)
	local key = date_str .. "\1" .. app
	local row = _gc(_agg_batch.app_day, key, { date = date_str, app = app })
	row[field] = (row[field] or 0) + value
end




-- =================================
--- ==================================
-- ======= 6/ Burst / Session =======
--- ==================================
-- =================================

local function _finalize_burst(date_str, app, b)
	if not b or b.char_count <= 0 then return end
	local key = date_str .. "\1" .. app
	local r = _gc(_agg_batch.bursts, key, {
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
	local k = _burst_length_bucket(b.char_count)
	r.length_buckets[k] = (r.length_buckets[k] or 0) + 1
	r.inter_count = r.inter_count + math.max(0, b.char_count - 1)
	r.inter_sum   = r.inter_sum   + b.sum_delays
	r.inter_sumsq = r.inter_sumsq + b.sum_delays_sq
end

local function _finalize_session(date_str, app, s)
	if not s or s.char_count <= 0 then return end
	local key = date_str .. "\1" .. app
	local r = _gc(_agg_batch.sessions, key, {
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




-- ================================
--- ================================
-- ======= 7/ Typing Walker =======
--- ================================
-- ================================

--- Replays a typing entry's per-keystroke array and pushes every metric into
--- _agg_batch. Mirrors the legacy aggregate_events() logic byte-for-byte.
--- @param entry table The decoded typing JSONL entry.
function M.walk_typing(entry)
	if not _require_init("walk_typing") then return end
	_ensure_batch()
	local app      = entry.app or "Unknown"
	local date_str = entry.timestamp and entry.timestamp:sub(1, 10) or _today()
	local events   = entry.events
	if type(events) ~= "table" then return end

	local ctx = _get_app_ctx(app)
	local p1, p2, p3, p4, p5, p6 = ctx.p1, ctx.p2, ctx.p3, ctx.p4, ctx.p5, ctx.p6
	local cur_word  = ctx.cur_word or ""
	local word_err  = ctx.word_err or false
	local backtrack = ctx.hist or {}
	local prev_word = ctx.prev_word
	local prev_sc   = ctx.prev_sc
	local prev_synth_type = "none"

	-- Derive the time slot from the entry's own timestamp (not wall-clock),
	-- so a batch replayed late still bins to the correct hour/min5 slot.
	local current_hour, current_min5
	do
		local ts = entry.timestamp or ""
		local hh = ts:sub(12, 13); local mm = ts:sub(15, 16)
		if hh == "" then hh = os.date("%H") end
		if mm == "" then mm = os.date("%M") end
		current_hour = hh
		local mn = tonumber(mm) or 0
		current_min5 = string.format("%s:%02d", hh, math.floor(mn / 5) * 5)
	end

	local app_day_key = date_str .. "\1" .. app
	local hourly_key  = app_day_key .. "\1" .. current_hour
	local min5_key    = app_day_key .. "\1" .. current_min5
	local hr  = _gc(_agg_batch.hourly,      hourly_key, { date=date_str, app=app, hour=current_hour, c=0, e=0, em=0, es=0, e_buckets={} })
	local m5  = _gc(_agg_batch.hourly_min5, min5_key,   { date=date_str, app=app, slot=current_min5, c=0, e=0, es=0, e_buckets={} })
	local cc  = _gc(_agg_batch.chars_class, app_day_key,{ date=date_str, app=app, letter=0,digit=0,punct=0,space=0,other=0 })
	local er  = _gc(_agg_batch.errors,      app_day_key,{ date=date_str, app=app, bs_total=0,cascade_count=0,cascade_max_len=0,recovery_sum_ms=0,recovery_count=0 })
	local eg  = _gc(_agg_batch.ergo,        app_day_key,{ date=date_str, app=app, same_finger_streak_max=0,same_hand_streak_max=0,auto_repeat_count=0 })

	if type(entry.layout) == "string" and entry.layout ~= "" then
		local lk = app_day_key .. "\1" .. entry.layout
		_agg_batch.layouts[lk] = (_agg_batch.layouts[lk] or { date=date_str, app=app, layout=entry.layout, count=0 })
		_agg_batch.layouts[lk].count = _agg_batch.layouts[lk].count + 1
	end

	if type(entry.title) == "string" and entry.title ~= "" then
		local tk = app_day_key .. "\1" .. entry.title
		local tr = _gc(_agg_batch.titles, tk, { date=date_str, app=app, title=entry.title, c=0, ms=0 })
		tr.c = tr.c + 1
	end

	for _, ev in ipairs(events) do
		local char         = ev[1]
		local delay        = ev[2] or 0
		local meta         = ev[3] or {}
		local shortcut_key = meta.sc
		local is_backspace = (char == "[BS]")
		local synth_type   = meta.st or "none"
		local is_synthetic = meta.s or false

		if type(shortcut_key) == "string" and shortcut_key ~= "" then
			local sc_tbl   = _agg_batch.sc_ngram.ngram_shortcuts
			local scbg_tbl = _agg_batch.sc_ngram.ngram_shortcut_bigrams
			local sk = app_day_key .. "\1" .. shortcut_key
			sc_tbl[sk] = (sc_tbl[sk] or { date=date_str, app=app, token=shortcut_key, count=0 })
			sc_tbl[sk].count = sc_tbl[sk].count + 1
			if prev_sc then
				local bgt = prev_sc .. "→" .. shortcut_key
				local bk = app_day_key .. "\1" .. bgt
				scbg_tbl[bk] = (scbg_tbl[bk] or { date=date_str, app=app, token=bgt, count=0 })
				scbg_tbl[bk].count = scbg_tbl[bk].count + 1
			end
			prev_sc = shortcut_key
		else
			-- Long pause breaks N-gram continuity
			if delay >= MAX_KEYSTROKE_DELAY_MS and not is_synthetic then
				p1, p2, p3, p4, p5, p6 = nil, nil, nil, nil, nil, nil
				backtrack = {}
				if #cur_word > 0 then
					if prev_word then
						_push_ngram("ngram_word_bigrams", date_str, app, prev_word .. " " .. cur_word, 0, word_err, "none")
					end
					_push_ngram("ngram_words", date_str, app, cur_word, 0, word_err, "none")
				end
				cur_word = ""; word_err = false; prev_word = nil; prev_sc = nil
			end

			-- Count synth triggers once per burst
			if is_synthetic and synth_type ~= "none" and synth_type ~= prev_synth_type then
				if synth_type == "hotstring" then
					_bump_app_day(date_str, app, "hs_triggers", 1)
				elseif synth_type == "llm" then
					_bump_app_day(date_str, app, "llm_triggers", 1)
				end
			end
			prev_synth_type = is_synthetic and synth_type or "none"

			if is_backspace then
				if #backtrack > 0 then
					local last_entry = table.remove(backtrack)
					if last_entry.c ~= "[BS]" then
						if last_entry.c  then _push_ngram("ngram_chars",      date_str, app, last_entry.c,  0, true, synth_type) end
						if last_entry.bg then _push_ngram("ngram_bigrams",    date_str, app, last_entry.bg, 0, true, synth_type) end
						if last_entry.tg then _push_ngram("ngram_trigrams",   date_str, app, last_entry.tg, 0, true, synth_type) end
						if last_entry.qg then _push_ngram("ngram_quadgrams",  date_str, app, last_entry.qg, 0, true, synth_type) end
						if last_entry.pg then _push_ngram("ngram_pentagrams", date_str, app, last_entry.pg, 0, true, synth_type) end
						if last_entry.hx then _push_ngram("ngram_hexagrams",  date_str, app, last_entry.hx, 0, true, synth_type) end
						if last_entry.hp then _push_ngram("ngram_heptagrams", date_str, app, last_entry.hp, 0, true, synth_type) end
					end
				end
				cur_word = _pop_utf8(cur_word)
				word_err = true

				if is_synthetic then
					hr.es = hr.es + 1; m5.es = m5.es + 1
					local trigger_evt = table.remove(ctx.recent_typing)
					if synth_type == "hotstring" then
						_bump_app_day(date_str, app, "hs_chars", -1)
						_bump_app_day(date_str, app, "hs_input_chars", 1)
						if trigger_evt then
							for _, t in ipairs(UI_PAUSE_BUCKETS_MS) do
								if trigger_evt.delay <= t then
									local bkey = app_day_key .. "\1" .. tostring(t)
									local row = _gc(_agg_batch.app_buckets, bkey, {
										date=date_str, app=app, bucket_ms=t,
										time_sum=0, credited=0, hs_in_t=0, hs_in_c=0, llm_in_t=0, llm_in_c=0,
									})
									row.hs_in_t = row.hs_in_t + trigger_evt.delay
									row.hs_in_c = row.hs_in_c + 1
								end
							end
						end
					elseif synth_type == "llm" then
						_bump_app_day(date_str, app, "llm_chars", -1)
						_bump_app_day(date_str, app, "llm_input_chars", 1)
						if trigger_evt then
							for _, t in ipairs(UI_PAUSE_BUCKETS_MS) do
								if trigger_evt.delay <= t then
									local bkey = app_day_key .. "\1" .. tostring(t)
									local row = _gc(_agg_batch.app_buckets, bkey, {
										date=date_str, app=app, bucket_ms=t,
										time_sum=0, credited=0, hs_in_t=0, hs_in_c=0, llm_in_t=0, llm_in_c=0,
									})
									row.llm_in_t = row.llm_in_t + trigger_evt.delay
									row.llm_in_c = row.llm_in_c + 1
								end
							end
						end
					end
				else
					hr.e  = hr.e  + 1; hr.em = hr.em + 1; m5.e  = m5.e  + 1
					_bump_app_day(date_str, app, "chars", 1)
					if delay > THINK_PAUSE_THRESHOLD_MS then
						_bump_app_day(date_str, app, "think_time_ms", delay)
						_bump_app_day(date_str, app, "pauses", 1)
					else
						_bump_app_day(date_str, app, "time_ms", delay)
					end
					_bucket_add(hr.e_buckets, delay, 1)
					_bucket_add(m5.e_buckets, delay, 1)
					table.remove(ctx.recent_typing)
					ctx.bs_run_len = ctx.bs_run_len + 1
					ctx.last_was_bs = true
					er.bs_total = er.bs_total + 1
					ctx.last_finger = nil
					ctx.same_finger_run = 0
					ctx.same_hand_run   = 0
					ctx.last_char = nil
				end

				local bs_entry = {}
				_push_ngram("ngram_chars", date_str, app, "[BS]", delay, false, synth_type); bs_entry.c = "[BS]"
				if p1 then _push_ngram("ngram_bigrams",  date_str, app, p1 .. "[BS]", delay, false, synth_type); bs_entry.bg = p1 .. "[BS]" end
				if p2 then _push_ngram("ngram_trigrams", date_str, app, p2 .. p1 .. "[BS]", delay, false, synth_type); bs_entry.tg = p2 .. p1 .. "[BS]" end
				table.insert(backtrack, bs_entry)
				p6 = p5; p5 = p4; p4 = p3; p3 = p2; p2 = p1; p1 = "[BS]"
			else
				local k_c  = char
				local k_bg = p1 and (p1 .. k_c) or nil
				local k_tg = p2 and (p2 .. p1 .. k_c) or nil
				local k_qg = p3 and (p3 .. p2 .. p1 .. k_c) or nil
				local k_pg = p4 and (p4 .. p3 .. p2 .. p1 .. k_c) or nil
				local k_hx = p5 and (p5 .. p4 .. p3 .. p2 .. p1 .. k_c) or nil
				local k_hp = p6 and (p6 .. p5 .. p4 .. p3 .. p2 .. p1 .. k_c) or nil

				local is_bracket_key = type(k_c) == "string" and k_c:sub(1, 1) == "[" and k_c:sub(-1) == "]"
				local record_delay   = delay < MAX_KEYSTROKE_DELAY_MS and delay or 0

				local entry_marks = {}
				if is_synthetic or is_bracket_key or delay < MAX_KEYSTROKE_DELAY_MS then
					_push_ngram("ngram_chars", date_str, app, k_c, record_delay, false, synth_type); entry_marks.c = k_c
					if k_bg then _push_ngram("ngram_bigrams",    date_str, app, k_bg, record_delay, false, synth_type); entry_marks.bg = k_bg end
					if k_tg then _push_ngram("ngram_trigrams",   date_str, app, k_tg, record_delay, false, synth_type); entry_marks.tg = k_tg end
					if k_qg then _push_ngram("ngram_quadgrams",  date_str, app, k_qg, record_delay, false, synth_type); entry_marks.qg = k_qg end
					if k_pg then _push_ngram("ngram_pentagrams", date_str, app, k_pg, record_delay, false, synth_type); entry_marks.pg = k_pg end
					if k_hx then _push_ngram("ngram_hexagrams",  date_str, app, k_hx, record_delay, false, synth_type); entry_marks.hx = k_hx end
					if k_hp then _push_ngram("ngram_heptagrams", date_str, app, k_hp, record_delay, false, synth_type); entry_marks.hp = k_hp end

					if not is_synthetic then
						_bump_app_day(date_str, app, "chars", 1)
						hr.c = hr.c + 1; m5.c = m5.c + 1
						if record_delay > THINK_PAUSE_THRESHOLD_MS then
							_bump_app_day(date_str, app, "think_time_ms", record_delay)
							_bump_app_day(date_str, app, "pauses", 1)
						else
							_bump_app_day(date_str, app, "time_ms", record_delay)
						end
						for _, t in ipairs(UI_PAUSE_BUCKETS_MS) do
							if record_delay <= t then
								local bkey = app_day_key .. "\1" .. tostring(t)
								local row = _gc(_agg_batch.app_buckets, bkey, {
									date=date_str, app=app, bucket_ms=t,
									time_sum=0, credited=0, hs_in_t=0, hs_in_c=0, llm_in_t=0, llm_in_c=0,
								})
								row.time_sum = row.time_sum + record_delay
								row.credited = row.credited + 1
							end
						end
						table.insert(ctx.recent_typing, { delay = record_delay })
						if #ctx.recent_typing > TRIGGER_LOOKBACK_LEN then
							table.remove(ctx.recent_typing, 1)
						end

						if (not ctx.current_burst) or record_delay > BURST_GAP_MS then
							_finalize_burst(date_str, app, ctx.current_burst)
							ctx.current_burst = { char_count = 1, sum_delays = 0, sum_delays_sq = 0, max_delay = 0 }
						else
							local b = ctx.current_burst
							b.char_count    = b.char_count + 1
							b.sum_delays    = b.sum_delays + record_delay
							b.sum_delays_sq = b.sum_delays_sq + (record_delay * record_delay)
							if record_delay > b.max_delay then b.max_delay = record_delay end
						end

						if (not ctx.current_session) or record_delay > SESSION_GAP_MS then
							_finalize_session(date_str, app, ctx.current_session)
							ctx.current_session = { char_count = 1, total_ms = 0 }
						else
							local s = ctx.current_session
							s.char_count = s.char_count + 1
							s.total_ms   = s.total_ms + record_delay
						end

						if ctx.last_was_bs then
							if ctx.bs_run_len >= CASCADE_MIN_BS then
								er.cascade_count = er.cascade_count + 1
								if ctx.bs_run_len > er.cascade_max_len then
									er.cascade_max_len = ctx.bs_run_len
								end
							end
							if record_delay <= MAX_KEYSTROKE_DELAY_MS then
								er.recovery_sum_ms = er.recovery_sum_ms + record_delay
								er.recovery_count  = er.recovery_count + 1
							end
							ctx.bs_run_len = 0; ctx.last_was_bs = false
						end

						local kc_num     = type(meta.kc) == "number" and meta.kc or nil
						local cur_finger = kc_num and KC_TO_FINGER[kc_num] or nil
						if cur_finger then
							if ctx.last_finger == cur_finger then
								ctx.same_finger_run = (ctx.same_finger_run or 1) + 1
							else
								ctx.same_finger_run = 1
							end
							if ctx.same_finger_run > eg.same_finger_streak_max then
								eg.same_finger_streak_max = ctx.same_finger_run
							end
							local cur_hand  = cur_finger:sub(1, 1)
							local last_hand = ctx.last_finger and ctx.last_finger:sub(1, 1) or nil
							if last_hand == cur_hand then
								ctx.same_hand_run = (ctx.same_hand_run or 1) + 1
							else
								ctx.same_hand_run = 1
							end
							if ctx.same_hand_run > eg.same_hand_streak_max then
								eg.same_hand_streak_max = ctx.same_hand_run
							end
							ctx.last_finger = cur_finger
						else
							ctx.last_finger = nil
							ctx.same_finger_run = 0
							ctx.same_hand_run   = 0
						end

						if ctx.last_char == k_c and record_delay > 0 and record_delay <= AUTO_REPEAT_MAX_DELAY_MS then
							eg.auto_repeat_count = eg.auto_repeat_count + 1
						end
						ctx.last_char = k_c

						local cls = _char_class(k_c)
						if     cls == "letter" then cc.letter = cc.letter + 1
						elseif cls == "digit"  then cc.digit  = cc.digit  + 1
						elseif cls == "punct"  then cc.punct  = cc.punct  + 1
						elseif cls == "space"  then cc.space  = cc.space  + 1
						else                        cc.other  = cc.other  + 1
						end

						if not cc.first_typed_min then cc.first_typed_min = current_min5 end
						cc.last_typed_min = current_min5
					else
						if synth_type == "hotstring" then
							_bump_app_day(date_str, app, "hs_chars", 1)
						elseif synth_type == "llm" then
							_bump_app_day(date_str, app, "llm_chars", 1)
						end
					end

					local is_separator = type(k_c) == "string" and (
						k_c:match("[%s.,!?;:\"'()%%{}%[%]<>=+*/\\|%-]") ~= nil
						or k_c == "\n" or k_c == "\194\160" or k_c == "\226\128\175")
					if is_separator then
						if #cur_word > 0 then
							if prev_word then
								_push_ngram("ngram_word_bigrams", date_str, app, prev_word .. " " .. cur_word, 0, word_err, "none")
							end
							_push_ngram("ngram_words", date_str, app, cur_word, 0, word_err, "none")
							prev_word = cur_word
							cur_word  = ""
							word_err  = false
						end
					else
						cur_word = cur_word .. k_c
					end
				end

				table.insert(backtrack, entry_marks)
				p6 = p5; p5 = p4; p4 = p3; p3 = p2; p2 = p1; p1 = k_c
			end
		end

		if not is_synthetic and type(meta.kc) == "number" then
			local kk = app_day_key .. "\1" .. tostring(meta.kc)
			_agg_batch.kc_ngram[kk] = (_agg_batch.kc_ngram[kk] or { date=date_str, app=app, keycode=meta.kc, count=0 })
			_agg_batch.kc_ngram[kk].count = _agg_batch.kc_ngram[kk].count + 1
		end
	end

	ctx.p1, ctx.p2, ctx.p3, ctx.p4, ctx.p5, ctx.p6 = p1, p2, p3, p4, p5, p6
	ctx.cur_word  = cur_word
	ctx.word_err  = word_err
	ctx.hist      = backtrack
	ctx.prev_word = prev_word
	ctx.prev_sc   = prev_sc

	_bump_app_day(date_str, app, "_category_seed", 0)
end




-- ==============================================
--- ===============================================
-- ======= 8/ Non-Typing Event Aggregation =======
--- ===============================================
-- ==============================================

--- Credits app_time_ms on app_switch events.
--- @param entry table Decoded app_switch JSONL entry.
function M.walk_app_switch(entry)
	if not _require_init("walk_app_switch") then return end
	_ensure_batch()
	if not entry.prev_app then return end
	local date_str = entry.timestamp:sub(1, 10)
	local key = date_str .. "\1" .. entry.prev_app
	_agg_batch.app_time[key] = (_agg_batch.app_time[key] or { date=date_str, app=entry.prev_app, ms=0 })
	_agg_batch.app_time[key].ms = _agg_batch.app_time[key].ms + (entry.duration_ms or 0)
	if entry.next_app then
		local sk = date_str .. "\1" .. entry.prev_app .. "\1" .. entry.next_app
		_agg_batch.switches_to[sk] = (_agg_batch.switches_to[sk] or { date=date_str, app_from=entry.prev_app, app_to=entry.next_app, count=0 })
		_agg_batch.switches_to[sk].count = _agg_batch.switches_to[sk].count + 1
	end
end

--- Credits agg_app_day_titles.ms on window_switch events.
--- @param entry table Decoded window_switch JSONL entry.
function M.walk_window_switch(entry)
	if not _require_init("walk_window_switch") then return end
	_ensure_batch()
	if type(entry.prev_title) ~= "string" or entry.prev_title == "" then return end
	local date_str = entry.timestamp:sub(1, 10)
	local app = entry.app or "Unknown"
	local tk = date_str .. "\1" .. app .. "\1" .. entry.prev_title
	local tr = _gc(_agg_batch.titles, tk, { date=date_str, app=app, title=entry.prev_title, c=0, ms=0 })
	tr.ms = tr.ms + (entry.duration_ms or 0)
end

--- Handles kc_hold + per-day system stats on system_event entries.
--- @param entry table Decoded system_event JSONL entry.
function M.walk_system_event(entry)
	if not _require_init("walk_system_event") then return end
	_ensure_batch()
	local date_str = entry.timestamp:sub(1, 10)
	local action   = entry.action
	if action == "modifier_hold" or action == "karabiner_release" then
		local kc  = entry.keycode
		local app = entry.app or "Unknown"
		local hold = entry.hold_ms or 0
		if type(kc) == "number" then
			local key = date_str .. "\1" .. app .. "\1" .. tostring(kc)
			local r = _gc(_agg_batch.kc_hold, key, {
				date=date_str, app=app, keycode=kc,
				sum_ms=0, count=0, max_ms=0, tap_count=0, hold_count=0,
			})
			r.sum_ms = r.sum_ms + hold; r.count = r.count + 1
			if hold > r.max_ms then r.max_ms = hold end
			if hold <= HOLD_THRESHOLD_MS then r.tap_count = r.tap_count + 1
			else r.hold_count = r.hold_count + 1 end
		end
	end
	local s = _gc(_agg_batch.system_day, date_str, {
		date=date_str, wifi_changes=0, space_switches=0,
		audio_muted_ms=0, locked_ms=0, sleep_ms=0, awake_ms=0,
		passive_count=0, night_wake_count=0,
	})
	if action == "wifi_change" then s.wifi_changes = s.wifi_changes + 1
	elseif action == "space_change"    then s.space_switches = s.space_switches + 1
	elseif action == "passive_period"  then s.passive_count  = s.passive_count  + 1
	elseif action == "unlock" then s.locked_ms = s.locked_ms + (entry.duration_ms or 0)
	elseif action == "wake"   then s.sleep_ms  = s.sleep_ms  + (entry.duration_ms or 0)
	end
end




-- ===================================
--- =================================
-- ======= 9/ Batch DB Flush =======
--- =================================
-- ===================================

--- Execute a SQL statement against the open db; log on failure.
local function _exec(sql)
	local db = SqliteWriter.get_db()
	if not db then return end
	local rc = db:exec(sql)
	if rc ~= sqlite3.OK then
		Logger.error(LOG, "exec failed: %s — %s.", db:errmsg() or "?", sql:sub(1, 200))
	end
end

local function _json_lit(tbl)
	if type(tbl) ~= "table" then return "'{}'" end
	local ok, s = pcall(json.encode, tbl)
	if not ok then return "'{}'" end
	return "'" .. (s:gsub("'", "''")) .. "'"
end

local function _sq(s)
	return "'" .. tostring(s):gsub("'", "''") .. "'"
end

local function _i(n)
	return math.floor(tonumber(n) or 0)
end

--- Flush all pending batch deltas into SQLite aggregate tables.
--- Must be called inside an open transaction managed by the caller.
function M.flush()
	if not _require_init("flush") then return end
	if not _agg_batch then return end
	local db = SqliteWriter.get_db()
	if not db then return end
	local d = _sq(_device_id)

	for _, row in pairs(_agg_batch.app_day) do
		local cat = Export.get_native_app_category(row.app)
		_exec(string.format(
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
			d, _sq(row.date), _sq(row.app),
			_i(row.chars), _i(row.pauses), _i(row.time_ms), _i(row.think_time_ms),
			_i(row.hs_chars), _i(row.llm_chars),
			_i(row.hs_triggers), _i(row.llm_triggers),
			_i(row.hs_input_chars), _i(row.llm_input_chars), _sq(cat)))
	end

	for _, row in pairs(_agg_batch.app_time) do
		local cat = Export.get_native_app_category(row.app)
		_exec(string.format(
			"INSERT INTO agg_app_day (device_id, date, app, app_time_ms, category) VALUES (%s,%s,%s,%d,%s) "
			.. "ON CONFLICT(device_id, date, app) DO UPDATE SET "
			.. "app_time_ms=app_time_ms+excluded.app_time_ms,"
			.. "category=COALESCE(agg_app_day.category, excluded.category)",
			d, _sq(row.date), _sq(row.app), _i(row.ms), _sq(cat)))
	end

	for _, row in pairs(_agg_batch.app_buckets) do
		_exec(string.format(
			"INSERT INTO agg_app_day_buckets (device_id, date, app, bucket_ms, time_sum, credited, hs_input_time_sum, hs_input_credited, llm_input_time_sum, llm_input_credited) VALUES (%s,%s,%s,%d,%d,%d,%d,%d,%d,%d) "
			.. "ON CONFLICT(device_id, date, app, bucket_ms) DO UPDATE SET "
			.. "time_sum=time_sum+excluded.time_sum,credited=credited+excluded.credited,"
			.. "hs_input_time_sum=hs_input_time_sum+excluded.hs_input_time_sum,"
			.. "hs_input_credited=hs_input_credited+excluded.hs_input_credited,"
			.. "llm_input_time_sum=llm_input_time_sum+excluded.llm_input_time_sum,"
			.. "llm_input_credited=llm_input_credited+excluded.llm_input_credited",
			d, _sq(row.date), _sq(row.app), _i(row.bucket_ms),
			_i(row.time_sum), _i(row.credited),
			_i(row.hs_in_t), _i(row.hs_in_c), _i(row.llm_in_t), _i(row.llm_in_c)))
	end

	for tbl_name, tbl in pairs(_agg_batch.ngram) do
		for key, item in pairs(tbl) do
			local s, e = key:find("\1")
			local date_str = key:sub(1, s - 1)
			local rest = key:sub(e + 1)
			local s2, e2 = rest:find("\1")
			local app = rest:sub(1, s2 - 1)
			local token = rest:sub(e2 + 1)
			_exec(string.format(
				"INSERT INTO %s (device_id, date, app, token, c, td, cd, e, esrc_json) VALUES (%s,%s,%s,%s,%d,%d,%d,%d,%s) "
				.. "ON CONFLICT(device_id, date, app, token) DO UPDATE SET "
				.. "c=c+excluded.c, td=td+excluded.td, cd=cd+excluded.cd, e=e+excluded.e, "
				.. "esrc_json=excluded.esrc_json",
				tbl_name, d, _sq(date_str), _sq(app), _sq(token),
				_i(item.c), _i(item.td), _i(item.cd), _i(item.e),
				_json_lit(item.esrc)))
		end
	end

	for _, row in pairs(_agg_batch.kc_ngram) do
		_exec(string.format(
			"INSERT INTO ngram_keycodes (device_id, date, app, keycode, c) VALUES (%s,%s,%s,%d,%d) "
			.. "ON CONFLICT(device_id, date, app, keycode) DO UPDATE SET c=c+excluded.c",
			d, _sq(row.date), _sq(row.app), _i(row.keycode), _i(row.count)))
	end

	for tbl_name, tbl in pairs(_agg_batch.sc_ngram) do
		for _, row in pairs(tbl) do
			_exec(string.format(
				"INSERT INTO %s (device_id, date, app, token, c) VALUES (%s,%s,%s,%s,%d) "
				.. "ON CONFLICT(device_id, date, app, token) DO UPDATE SET c=c+excluded.c",
				tbl_name, d, _sq(row.date), _sq(row.app), _sq(row.token), _i(row.count)))
		end
	end

	for _, row in pairs(_agg_batch.kc_hold) do
		_exec(string.format(
			"INSERT INTO agg_app_day_kc_hold (device_id, date, app, keycode, sum_ms, count, max_ms, tap_count, hold_count) VALUES (%s,%s,%s,%d,%d,%d,%d,%d,%d) "
			.. "ON CONFLICT(device_id, date, app, keycode) DO UPDATE SET "
			.. "sum_ms=sum_ms+excluded.sum_ms,count=count+excluded.count,"
			.. "max_ms=MAX(max_ms, excluded.max_ms),"
			.. "tap_count=tap_count+excluded.tap_count,hold_count=hold_count+excluded.hold_count",
			d, _sq(row.date), _sq(row.app), _i(row.keycode),
			_i(row.sum_ms), _i(row.count), _i(row.max_ms), _i(row.tap_count), _i(row.hold_count)))
	end

	for _, row in pairs(_agg_batch.titles) do
		_exec(string.format(
			"INSERT INTO agg_app_day_titles (device_id, date, app, title, c, ms) VALUES (%s,%s,%s,%s,%d,%d) "
			.. "ON CONFLICT(device_id, date, app, title) DO UPDATE SET c=c+excluded.c, ms=ms+excluded.ms",
			d, _sq(row.date), _sq(row.app), _sq(row.title), _i(row.c), _i(row.ms)))
	end
	for key, _ in pairs(_agg_batch.titles) do
		local s, e = key:find("\1")
		local rest = key:sub(e + 1)
		local s2, e2 = rest:find("\1")
		local date_str = key:sub(1, s - 1)
		local app = rest:sub(1, s2 - 1)
		_exec(string.format(
			"DELETE FROM agg_app_day_titles WHERE device_id=%s AND date=%s AND app=%s AND title NOT IN ("
			.. "SELECT title FROM agg_app_day_titles WHERE device_id=%s AND date=%s AND app=%s "
			.. "ORDER BY (c + ms) DESC LIMIT %d)",
			d, _sq(date_str), _sq(app), d, _sq(date_str), _sq(app), TITLE_CAP_PER_APP_DAY))
	end

	for _, row in pairs(_agg_batch.hourly) do
		_exec(string.format(
			"INSERT INTO agg_app_day_hourly (device_id, date, app, hour, c, e, em, es, e_buckets_json) VALUES (%s,%s,%s,%s,%d,%d,%d,%d,%s) "
			.. "ON CONFLICT(device_id, date, app, hour) DO UPDATE SET "
			.. "c=c+excluded.c, e=e+excluded.e, em=em+excluded.em, es=es+excluded.es, "
			.. "e_buckets_json=excluded.e_buckets_json",
			d, _sq(row.date), _sq(row.app), _sq(row.hour),
			_i(row.c), _i(row.e), _i(row.em), _i(row.es), _json_lit(row.e_buckets)))
	end

	for _, row in pairs(_agg_batch.hourly_min5) do
		_exec(string.format(
			"INSERT INTO agg_app_day_hourly_min5 (device_id, date, app, slot, c, e, es, e_buckets_json) VALUES (%s,%s,%s,%s,%d,%d,%d,%s) "
			.. "ON CONFLICT(device_id, date, app, slot) DO UPDATE SET "
			.. "c=c+excluded.c, e=e+excluded.e, es=es+excluded.es, "
			.. "e_buckets_json=excluded.e_buckets_json",
			d, _sq(row.date), _sq(row.app), _sq(row.slot),
			_i(row.c), _i(row.e), _i(row.es), _json_lit(row.e_buckets)))
	end

	for _, row in pairs(_agg_batch.layouts) do
		_exec(string.format(
			"INSERT INTO agg_app_day_layouts (device_id, date, app, layout, count) VALUES (%s,%s,%s,%s,%d) "
			.. "ON CONFLICT(device_id, date, app, layout) DO UPDATE SET count=count+excluded.count",
			d, _sq(row.date), _sq(row.app), _sq(row.layout), _i(row.count)))
	end

	for _, row in pairs(_agg_batch.chars_class) do
		_exec(string.format(
			"INSERT INTO agg_app_day_chars_class (device_id, date, app, letter, digit, punct, space, other, first_typed_min, last_typed_min) VALUES (%s,%s,%s,%d,%d,%d,%d,%d,%s,%s) "
			.. "ON CONFLICT(device_id, date, app) DO UPDATE SET "
			.. "letter=letter+excluded.letter,digit=digit+excluded.digit,"
			.. "punct=punct+excluded.punct,space=space+excluded.space,other=other+excluded.other,"
			.. "first_typed_min=COALESCE(agg_app_day_chars_class.first_typed_min, excluded.first_typed_min),"
			.. "last_typed_min=COALESCE(excluded.last_typed_min, agg_app_day_chars_class.last_typed_min)",
			d, _sq(row.date), _sq(row.app),
			_i(row.letter), _i(row.digit), _i(row.punct), _i(row.space), _i(row.other),
			row.first_typed_min and _sq(row.first_typed_min) or "NULL",
			row.last_typed_min  and _sq(row.last_typed_min)  or "NULL"))
	end

	for _, row in pairs(_agg_batch.errors) do
		_exec(string.format(
			"INSERT INTO agg_app_day_errors (device_id, date, app, bs_total, cascade_count, cascade_max_len, recovery_sum_ms, recovery_count) VALUES (%s,%s,%s,%d,%d,%d,%d,%d) "
			.. "ON CONFLICT(device_id, date, app) DO UPDATE SET "
			.. "bs_total=bs_total+excluded.bs_total,cascade_count=cascade_count+excluded.cascade_count,"
			.. "cascade_max_len=MAX(cascade_max_len, excluded.cascade_max_len),"
			.. "recovery_sum_ms=recovery_sum_ms+excluded.recovery_sum_ms,"
			.. "recovery_count=recovery_count+excluded.recovery_count",
			d, _sq(row.date), _sq(row.app),
			_i(row.bs_total), _i(row.cascade_count), _i(row.cascade_max_len),
			_i(row.recovery_sum_ms), _i(row.recovery_count)))
	end

	for _, row in pairs(_agg_batch.ergo) do
		_exec(string.format(
			"INSERT INTO agg_app_day_ergo (device_id, date, app, same_finger_streak_max, same_hand_streak_max, auto_repeat_count) VALUES (%s,%s,%s,%d,%d,%d) "
			.. "ON CONFLICT(device_id, date, app) DO UPDATE SET "
			.. "same_finger_streak_max=MAX(same_finger_streak_max, excluded.same_finger_streak_max),"
			.. "same_hand_streak_max=MAX(same_hand_streak_max, excluded.same_hand_streak_max),"
			.. "auto_repeat_count=auto_repeat_count+excluded.auto_repeat_count",
			d, _sq(row.date), _sq(row.app),
			_i(row.same_finger_streak_max), _i(row.same_hand_streak_max), _i(row.auto_repeat_count)))
	end

	for _, row in pairs(_agg_batch.bursts) do
		_exec(string.format(
			"INSERT INTO agg_app_day_burst (device_id, date, app, count_total, max_cpm, max_chars, length_buckets_json, inter_delay_count, inter_delay_sum, inter_delay_sumsq) VALUES (%s,%s,%s,%d,%f,%d,%s,%d,%d,%d) "
			.. "ON CONFLICT(device_id, date, app) DO UPDATE SET "
			.. "count_total=count_total+excluded.count_total,"
			.. "max_cpm=MAX(max_cpm, excluded.max_cpm),max_chars=MAX(max_chars, excluded.max_chars),"
			.. "length_buckets_json=excluded.length_buckets_json,"
			.. "inter_delay_count=inter_delay_count+excluded.inter_delay_count,"
			.. "inter_delay_sum=inter_delay_sum+excluded.inter_delay_sum,"
			.. "inter_delay_sumsq=inter_delay_sumsq+excluded.inter_delay_sumsq",
			d, _sq(row.date), _sq(row.app),
			_i(row.count_total), row.max_cpm, _i(row.max_chars),
			_json_lit(row.length_buckets),
			_i(row.inter_count), _i(row.inter_sum), _i(row.inter_sumsq)))
	end

	for _, row in pairs(_agg_batch.sessions) do
		_exec(string.format(
			"INSERT INTO agg_app_day_session (device_id, date, app, count_total, longest_ms, longest_chars, total_active_ms, durations_json) VALUES (%s,%s,%s,%d,%d,%d,%d,%s) "
			.. "ON CONFLICT(device_id, date, app) DO UPDATE SET "
			.. "count_total=count_total+excluded.count_total,"
			.. "longest_ms=MAX(longest_ms, excluded.longest_ms),"
			.. "longest_chars=MAX(longest_chars, excluded.longest_chars),"
			.. "total_active_ms=total_active_ms+excluded.total_active_ms,"
			.. "durations_json=excluded.durations_json",
			d, _sq(row.date), _sq(row.app),
			_i(row.count_total), _i(row.longest_ms), _i(row.longest_chars), _i(row.total_active_ms),
			_json_lit(row.durations)))
	end

	for _, row in pairs(_agg_batch.switches_to) do
		_exec(string.format(
			"INSERT INTO agg_app_day_switches_to (device_id, date, app_from, app_to, count) VALUES (%s,%s,%s,%s,%d) "
			.. "ON CONFLICT(device_id, date, app_from, app_to) DO UPDATE SET count=count+excluded.count",
			d, _sq(row.date), _sq(row.app_from), _sq(row.app_to), _i(row.count)))
	end

	for _, row in pairs(_agg_batch.system_day) do
		_exec(string.format(
			"INSERT INTO agg_system_day (device_id, date, wifi_changes, space_switches, audio_muted_ms, locked_ms, sleep_ms, awake_ms, passive_count, night_wake_count) VALUES (%s,%s,%d,%d,%d,%d,%d,%d,%d,%d) "
			.. "ON CONFLICT(device_id, date) DO UPDATE SET "
			.. "wifi_changes=wifi_changes+excluded.wifi_changes,"
			.. "space_switches=space_switches+excluded.space_switches,"
			.. "audio_muted_ms=audio_muted_ms+excluded.audio_muted_ms,"
			.. "locked_ms=locked_ms+excluded.locked_ms,sleep_ms=sleep_ms+excluded.sleep_ms,"
			.. "awake_ms=awake_ms+excluded.awake_ms,"
			.. "passive_count=passive_count+excluded.passive_count,"
			.. "night_wake_count=night_wake_count+excluded.night_wake_count",
			d, _sq(row.date), _i(row.wifi_changes), _i(row.space_switches),
			_i(row.audio_muted_ms), _i(row.locked_ms), _i(row.sleep_ms), _i(row.awake_ms),
			_i(row.passive_count), _i(row.night_wake_count)))
	end

	_reset_batch()
end




-- ==============================
--- ===============================
-- ======= 10/ Initializer =======
--- ===============================
-- ==============================

--- Initialize the aggregator with the device id.
--- @param deps table Must contain: device_id (string).
function M.init(deps)
	Logger.start(LOG, "Initializing…")
	if type(deps) ~= "table" or type(deps.device_id) ~= "string" then
		Logger.error(LOG, "M.init(): invalid deps — aggregator non-functional.")
		return
	end
	if _initialized then
		Logger.warn(LOG, "M.init() called more than once — ignoring duplicate call.")
		return
	end
	_device_id   = deps.device_id
	_initialized = true
	_reset_batch()
	Logger.success(LOG, "Initialized.")
end

return M
