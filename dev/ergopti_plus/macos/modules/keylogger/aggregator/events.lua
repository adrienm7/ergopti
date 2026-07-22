--- modules/keylogger/aggregator/events.lua

--- ==============================================================================
--- MODULE: Aggregator Events — Walk Functions
--- DESCRIPTION:
--- Implements the JSONL event walkers (walk_typing, walk_app_switch,
--- walk_window_switch, walk_system_event) that replay per-keystroke data into
--- the per-tick accumulator managed by aggregator/core.lua.
---
--- All mutable state is accessed through aggregator/state.lua (S) and all
--- helper utilities are delegated to aggregator/core.lua (C) so that each
--- sub-module owns a clearly-bounded responsibility.
---
--- MIRRORS: windows/modules/keylogger/keylogger_walker_events.ahk
--- ==============================================================================

local M = {}

local S = require("modules.keylogger.aggregator.state")
local C = require("modules.keylogger.aggregator.core")





-- ================================
-- ================================
-- ======= 1/ Typing Walker =======
-- ================================
-- ================================

--- Replays a typing entry's per-keystroke array and pushes every metric into
--- S.agg_batch. Mirrors the legacy aggregate_events() logic byte-for-byte.
--- @param entry table The decoded typing JSONL entry.
function M.walk_typing(entry)
	if not C.require_init("walk_typing") then return end
	C.ensure_batch()
	local app      = entry.app or "Unknown"
	local date_str = entry.timestamp and entry.timestamp:sub(1, 10) or C.today()
	local events   = entry.events
	if type(events) ~= "table" then return end

	local ctx = C.get_app_ctx(app)
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
	local hr  = C.gc(S.agg_batch.hourly,      hourly_key, { date=date_str, app=app, hour=current_hour, c=0, e=0, em=0, es=0, e_buckets={} })
	local m5  = C.gc(S.agg_batch.hourly_min5, min5_key,   { date=date_str, app=app, slot=current_min5, c=0, e=0, es=0, e_buckets={} })
	local cc  = C.gc(S.agg_batch.chars_class, app_day_key,{ date=date_str, app=app, letter=0,digit=0,punct=0,space=0,other=0 })
	local er  = C.gc(S.agg_batch.errors,      app_day_key,{ date=date_str, app=app, bs_total=0,cascade_count=0,cascade_max_len=0,recovery_sum_ms=0,recovery_count=0 })
	-- Shape must match the default used by walk_system_event's focus_first_key
	-- branch below (same S.agg_batch.ergo row, keyed by the same app_day_key) —
	-- whichever walker runs first for a given app-day creates the row via C.gc,
	-- so both defaults must carry every field either walker increments.
	local eg  = C.gc(S.agg_batch.ergo,        app_day_key,{
		date=date_str, app=app,
		same_finger_streak_max=0, same_hand_streak_max=0, auto_repeat_count=0,
		focus_to_first_key_sum_ms=0, focus_to_first_key_count=0,
	})

	if type(entry.layout) == "string" and entry.layout ~= "" then
		local lk = app_day_key .. "\1" .. entry.layout
		S.agg_batch.layouts[lk] = (S.agg_batch.layouts[lk] or { date=date_str, app=app, layout=entry.layout, count=0 })
		S.agg_batch.layouts[lk].count = S.agg_batch.layouts[lk].count + 1
	end

	if type(entry.title) == "string" and entry.title ~= "" then
		local tk = app_day_key .. "\1" .. entry.title
		local tr = C.gc(S.agg_batch.titles, tk, { date=date_str, app=app, title=entry.title, c=0, ms=0 })
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
			local sc_tbl   = S.agg_batch.sc_ngram.ngram_shortcuts
			local scbg_tbl = S.agg_batch.sc_ngram.ngram_shortcut_bigrams
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
			if delay >= C.MAX_KEYSTROKE_DELAY_MS and not is_synthetic then
				p1, p2, p3, p4, p5, p6 = nil, nil, nil, nil, nil, nil
				backtrack = {}
				if #cur_word > 0 then
					if prev_word then
						C.push_ngram("ngram_word_bigrams", date_str, app, prev_word .. " " .. cur_word, 0, word_err, "none")
					end
					C.push_ngram("ngram_words", date_str, app, cur_word, 0, word_err, "none")
				end
				cur_word = ""; word_err = false; prev_word = nil; prev_sc = nil
			end

			-- Count synth triggers once per burst
			if is_synthetic and synth_type ~= "none" and synth_type ~= prev_synth_type then
				if synth_type == "hotstring" then
					C.bump_app_day(date_str, app, "hs_triggers", 1)
				elseif synth_type == "llm" then
					C.bump_app_day(date_str, app, "llm_triggers", 1)
				end
			end
			prev_synth_type = is_synthetic and synth_type or "none"

			if is_backspace then
				if #backtrack > 0 then
					local last_entry = table.remove(backtrack)
					if last_entry.c ~= "[BS]" then
						if last_entry.c  then C.push_ngram("ngram_chars",      date_str, app, last_entry.c,  0, true, synth_type) end
						if last_entry.bg then C.push_ngram("ngram_bigrams",    date_str, app, last_entry.bg, 0, true, synth_type) end
						if last_entry.tg then C.push_ngram("ngram_trigrams",   date_str, app, last_entry.tg, 0, true, synth_type) end
						if last_entry.qg then C.push_ngram("ngram_quadgrams",  date_str, app, last_entry.qg, 0, true, synth_type) end
						if last_entry.pg then C.push_ngram("ngram_pentagrams", date_str, app, last_entry.pg, 0, true, synth_type) end
						if last_entry.hx then C.push_ngram("ngram_hexagrams",  date_str, app, last_entry.hx, 0, true, synth_type) end
						if last_entry.hp then C.push_ngram("ngram_heptagrams", date_str, app, last_entry.hp, 0, true, synth_type) end
					end
				end
				cur_word = C.pop_utf8(cur_word)
				word_err = true

				if is_synthetic then
					hr.es = hr.es + 1; m5.es = m5.es + 1
					local trigger_evt = table.remove(ctx.recent_typing)
					if synth_type == "hotstring" then
						-- hs_chars is gross generated output. The UI subtracts this
						-- separately recorded trigger input exactly once to obtain the
						-- net gain; decrementing both here and there double-subtracted.
						C.bump_app_day(date_str, app, "hs_input_chars", 1)
						if trigger_evt and type(trigger_evt.delay) == "number" then
							for _, t in ipairs(C.UI_PAUSE_BUCKETS_MS) do
								if trigger_evt.delay <= t then
									local bkey = app_day_key .. "\1" .. tostring(t)
									local row = C.gc(S.agg_batch.app_buckets, bkey, {
										date=date_str, app=app, bucket_ms=t,
										time_sum=0, credited=0, hs_in_t=0, hs_in_c=0, llm_in_t=0, llm_in_c=0,
									})
									row.hs_in_t = row.hs_in_t + trigger_evt.delay
									row.hs_in_c = row.hs_in_c + 1
								end
							end
						end
					elseif synth_type == "llm" then
						-- Keep the same gross-output contract as hotstrings and the
						-- Linux/Windows persisted event rebuilds.
						C.bump_app_day(date_str, app, "llm_input_chars", 1)
						if trigger_evt and type(trigger_evt.delay) == "number" then
							for _, t in ipairs(C.UI_PAUSE_BUCKETS_MS) do
								if trigger_evt.delay <= t then
									local bkey = app_day_key .. "\1" .. tostring(t)
									local row = C.gc(S.agg_batch.app_buckets, bkey, {
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
					C.bump_app_day(date_str, app, "chars", 1)
					if delay > C.THINK_PAUSE_THRESHOLD_MS then
						C.bump_app_day(date_str, app, "think_time_ms", delay)
						C.bump_app_day(date_str, app, "pauses", 1)
					else
						C.bump_app_day(date_str, app, "time_ms", delay)
					end
					C.bucket_add(hr.e_buckets, delay, 1)
					C.bucket_add(m5.e_buckets, delay, 1)
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
				C.push_ngram("ngram_chars", date_str, app, "[BS]", delay, false, synth_type); bs_entry.c = "[BS]"
				if p1 then C.push_ngram("ngram_bigrams",  date_str, app, p1 .. "[BS]", delay, false, synth_type); bs_entry.bg = p1 .. "[BS]" end
				if p2 then C.push_ngram("ngram_trigrams", date_str, app, p2 .. p1 .. "[BS]", delay, false, synth_type); bs_entry.tg = p2 .. p1 .. "[BS]" end
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
				local record_delay   = delay < C.MAX_KEYSTROKE_DELAY_MS and delay or 0

				local entry_marks = {}
				if is_synthetic or is_bracket_key or delay < C.MAX_KEYSTROKE_DELAY_MS then
					C.push_ngram("ngram_chars", date_str, app, k_c, record_delay, false, synth_type); entry_marks.c = k_c
					if k_bg then C.push_ngram("ngram_bigrams",    date_str, app, k_bg, record_delay, false, synth_type); entry_marks.bg = k_bg end
					if k_tg then C.push_ngram("ngram_trigrams",   date_str, app, k_tg, record_delay, false, synth_type); entry_marks.tg = k_tg end
					if k_qg then C.push_ngram("ngram_quadgrams",  date_str, app, k_qg, record_delay, false, synth_type); entry_marks.qg = k_qg end
					if k_pg then C.push_ngram("ngram_pentagrams", date_str, app, k_pg, record_delay, false, synth_type); entry_marks.pg = k_pg end
					if k_hx then C.push_ngram("ngram_hexagrams",  date_str, app, k_hx, record_delay, false, synth_type); entry_marks.hx = k_hx end
					if k_hp then C.push_ngram("ngram_heptagrams", date_str, app, k_hp, record_delay, false, synth_type); entry_marks.hp = k_hp end

					if not is_synthetic then
						C.bump_app_day(date_str, app, "chars", 1)
						hr.c = hr.c + 1; m5.c = m5.c + 1
						if record_delay > C.THINK_PAUSE_THRESHOLD_MS then
							C.bump_app_day(date_str, app, "think_time_ms", record_delay)
							C.bump_app_day(date_str, app, "pauses", 1)
						else
							C.bump_app_day(date_str, app, "time_ms", record_delay)
						end
						for _, t in ipairs(C.UI_PAUSE_BUCKETS_MS) do
							if record_delay <= t then
								local bkey = app_day_key .. "\1" .. tostring(t)
								local row = C.gc(S.agg_batch.app_buckets, bkey, {
									date=date_str, app=app, bucket_ms=t,
									time_sum=0, credited=0, hs_in_t=0, hs_in_c=0, llm_in_t=0, llm_in_c=0,
								})
								row.time_sum = row.time_sum + record_delay
								row.credited = row.credited + 1
							end
						end
						table.insert(ctx.recent_typing, { delay = record_delay })
						if #ctx.recent_typing > C.TRIGGER_LOOKBACK_LEN then
							table.remove(ctx.recent_typing, 1)
						end

						if (not ctx.current_burst) or record_delay > C.BURST_GAP_MS then
							C.finalize_burst(date_str, app, ctx.current_burst)
							ctx.current_burst = { char_count = 1, sum_delays = 0, sum_delays_sq = 0, max_delay = 0 }
						else
							local b = ctx.current_burst
							b.char_count    = b.char_count + 1
							b.sum_delays    = b.sum_delays + record_delay
							b.sum_delays_sq = b.sum_delays_sq + (record_delay * record_delay)
							if record_delay > b.max_delay then b.max_delay = record_delay end
						end

						if (not ctx.current_session) or record_delay > C.SESSION_GAP_MS then
							C.finalize_session(date_str, app, ctx.current_session)
							ctx.current_session = { char_count = 1, total_ms = 0 }
						else
							local s = ctx.current_session
							s.char_count = s.char_count + 1
							s.total_ms   = s.total_ms + record_delay
						end

						if ctx.last_was_bs then
							if ctx.bs_run_len >= C.CASCADE_MIN_BS then
								er.cascade_count = er.cascade_count + 1
								if ctx.bs_run_len > er.cascade_max_len then
									er.cascade_max_len = ctx.bs_run_len
								end
							end
							if record_delay <= C.MAX_KEYSTROKE_DELAY_MS then
								er.recovery_sum_ms = er.recovery_sum_ms + record_delay
								er.recovery_count  = er.recovery_count + 1
							end
							ctx.bs_run_len = 0; ctx.last_was_bs = false
						end

						local kc_num     = type(meta.kc) == "number" and meta.kc or nil
						local cur_finger = kc_num and C.KC_TO_FINGER[kc_num] or nil
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

						if ctx.last_char == k_c and record_delay > 0 and record_delay <= C.AUTO_REPEAT_MAX_DELAY_MS then
							eg.auto_repeat_count = eg.auto_repeat_count + 1
						end
						ctx.last_char = k_c

						local cls = C.char_class(k_c)
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
							C.bump_app_day(date_str, app, "hs_chars", 1)
						elseif synth_type == "llm" then
							C.bump_app_day(date_str, app, "llm_chars", 1)
						end
					end

					local is_separator = type(k_c) == "string" and (
						k_c:match("[%s.,!?;:\"'()%%{}%[%]<>=+*/\\|%-]") ~= nil
						or k_c == "\n" or k_c == "\194\160" or k_c == "\226\128\175")
					if is_separator then
						if #cur_word > 0 then
							if prev_word then
								C.push_ngram("ngram_word_bigrams", date_str, app, prev_word .. " " .. cur_word, 0, word_err, "none")
							end
							C.push_ngram("ngram_words", date_str, app, cur_word, 0, word_err, "none")
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
			S.agg_batch.kc_ngram[kk] = (S.agg_batch.kc_ngram[kk] or { date=date_str, app=app, keycode=meta.kc, count=0 })
			S.agg_batch.kc_ngram[kk].count = S.agg_batch.kc_ngram[kk].count + 1
		end
	end

	ctx.p1, ctx.p2, ctx.p3, ctx.p4, ctx.p5, ctx.p6 = p1, p2, p3, p4, p5, p6
	ctx.cur_word  = cur_word
	ctx.word_err  = word_err
	ctx.hist      = backtrack
	ctx.prev_word = prev_word
	ctx.prev_sc   = prev_sc

	C.bump_app_day(date_str, app, "_category_seed", 0)
end





-- ======================================================
-- ===============================================
-- ======= 2/ Non-Typing Event Aggregation =======
-- ===============================================
-- ======================================================

--- Credits app_time_ms on app_switch events.
--- @param entry table Decoded app_switch JSONL entry.
function M.walk_app_switch(entry)
	if not C.require_init("walk_app_switch") then return end
	C.ensure_batch()
	if not entry.prev_app then return end
	local date_str = entry.timestamp:sub(1, 10)
	local key = date_str .. "\1" .. entry.prev_app
	S.agg_batch.app_time[key] = (S.agg_batch.app_time[key] or { date=date_str, app=entry.prev_app, ms=0 })
	S.agg_batch.app_time[key].ms = S.agg_batch.app_time[key].ms + (entry.duration_ms or 0)
	if entry.next_app then
		local sk = date_str .. "\1" .. entry.prev_app .. "\1" .. entry.next_app
		S.agg_batch.switches_to[sk] = (S.agg_batch.switches_to[sk] or { date=date_str, app_from=entry.prev_app, app_to=entry.next_app, count=0 })
		S.agg_batch.switches_to[sk].count = S.agg_batch.switches_to[sk].count + 1
	end
end

--- Credits agg_app_day_titles.ms on window_switch events.
--- @param entry table Decoded window_switch JSONL entry.
function M.walk_window_switch(entry)
	if not C.require_init("walk_window_switch") then return end
	C.ensure_batch()
	if type(entry.prev_title) ~= "string" or entry.prev_title == "" then return end
	local date_str = entry.timestamp:sub(1, 10)
	local app = entry.app or "Unknown"
	local tk = date_str .. "\1" .. app .. "\1" .. entry.prev_title
	local tr = C.gc(S.agg_batch.titles, tk, { date=date_str, app=app, title=entry.prev_title, c=0, ms=0 })
	tr.ms = tr.ms + (entry.duration_ms or 0)
end

-- Manifest stat names that LogManager.increment_manifest_stat() is allowed to
-- bump on agg_app_day. Whitelisted (rather than trusting entry.stat blindly)
-- so a future caller cannot inject an arbitrary column name into the batch —
-- see modules/keylogger/init.lua log_hotstring_suggested / log_llm_suggested,
-- the only two current producers of the manifest_increment system_event.
local MANIFEST_STAT_FIELDS = {
	hs_suggested  = true,
	llm_suggested = true,
}

--- Handles kc_hold + per-day system stats on system_event entries.
--- @param entry table Decoded system_event JSONL entry.
function M.walk_system_event(entry)
	if not C.require_init("walk_system_event") then return end
	C.ensure_batch()
	local date_str = entry.timestamp:sub(1, 10)
	local action   = entry.action
	if action == "manifest_increment" and MANIFEST_STAT_FIELDS[entry.stat] then
		local app = entry.app or "Unknown"
		C.bump_app_day(date_str, app, entry.stat, tonumber(entry.amount) or 1)
	end
	if action == "focus_first_key" then
		-- F-MED-27: same shape as F-HIGH-26 — LogManager.log_focus_first_key()
		-- appends this event, but walk_system_event had no branch for it and the
		-- destination columns were absent from the agg_app_day_ergo UPSERT, so
		-- the latency metric was computed, logged, and then silently discarded.
		-- Default shape MUST match walk_typing's S.agg_batch.ergo default above —
		-- whichever walker runs first for an app-day creates the row via C.gc.
		local app = entry.app or "Unknown"
		local key = date_str .. "\1" .. app
		local eg = C.gc(S.agg_batch.ergo, key, {
			date=date_str, app=app,
			same_finger_streak_max=0, same_hand_streak_max=0, auto_repeat_count=0,
			focus_to_first_key_sum_ms=0, focus_to_first_key_count=0,
		})
		eg.focus_to_first_key_sum_ms = eg.focus_to_first_key_sum_ms + (tonumber(entry.latency_ms) or 0)
		eg.focus_to_first_key_count  = eg.focus_to_first_key_count + 1
	end
	if action == "modifier_hold" or action == "karabiner_release" then
		local kc  = entry.keycode
		local app = entry.app or "Unknown"
		local hold = entry.hold_ms or 0
		if type(kc) == "number" then
			local key = date_str .. "\1" .. app .. "\1" .. tostring(kc)
			local r = C.gc(S.agg_batch.kc_hold, key, {
				date=date_str, app=app, keycode=kc,
				sum_ms=0, count=0, max_ms=0, tap_count=0, hold_count=0,
			})
			r.sum_ms = r.sum_ms + hold; r.count = r.count + 1
			if hold > r.max_ms then r.max_ms = hold end
			if hold <= C.HOLD_THRESHOLD_MS then r.tap_count = r.tap_count + 1
			else r.hold_count = r.hold_count + 1 end
		end
	end
	local s = C.gc(S.agg_batch.system_day, date_str, {
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

return M
