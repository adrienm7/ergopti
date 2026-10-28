--- _shared/lua/keystats/walker.lua

--- ==============================================================================
--- MODULE: Keystats Event Walker (shared by macOS and Linux)
--- DESCRIPTION:
--- One walk over a typing entry's keystrokes, producing the derived tables the
--- dashboards read: the nine n-gram families, the hour and five-minute
--- activity, the character classes, the error analysis, the burst and session
--- records, the pause buckets, the streaks and the per-day counters. It also
--- credits application and window switches.
---
--- FEATURES & RATIONALE:
--- 1. One walk, three drivers. The Windows walker (keystats_walker_events.ahk)
---    is the reference the cross-driver corpus
---    `_shared/tests/corpus/keystats/aggregation_vectors.json` pins; macOS and
---    Linux used to keep two more copies that had drifted (word boundaries,
---    streak breaks, correction history, synthetic corrections). Both Lua
---    drivers now walk through this module and replay the same corpus.
--- 2. Pure. A walk takes the batch and the per-application context it
---    updates; it reads no clock, no database and no file. What differs per
---    driver arrives as a port: which finger typed a keystroke (macOS keys on a
---    virtual keycode, Linux on the character), and which hour slot a
---    keystroke belongs to (macOS and Windows stamp the entry, Linux stamps
---    each keystroke on a monotonic clock).
--- 3. The context outlives the walk. A word, a sequence, a correction, a burst
---    and a session continue across entries; `settle` credits what a context
---    still holds once its own gap has passed, or all of it on a new day.
--- ==============================================================================

local M = {}

local Helpers = require("keystats.aggregator_helpers")
local Utils = require("keystats.utils")

-- Every timing the walk compares against. Each driver reads them from its own
-- timing registry (the shared [keystats] canon) and hands them over, so the
-- module stays free of driver infrastructure.
local REQUIRED_TIMINGS = {
	"max_keystroke_delay_ms", "think_pause_ms", "burst_gap_ms",
	"session_gap_ms", "auto_repeat_max_delay_ms",
}

-- What a backspace looks like in a typing entry.
local BACKSPACE = "[BS]"

-- The n-gram family of each token length, and the history key of each.
local FAMILIES = {
	{ table_name = "ngram_chars", mark = "c" },
	{ table_name = "ngram_bigrams", mark = "bg" },
	{ table_name = "ngram_trigrams", mark = "tg" },
	{ table_name = "ngram_quadgrams", mark = "qg" },
	{ table_name = "ngram_pentagrams", mark = "pg" },
	{ table_name = "ngram_hexagrams", mark = "hx" },
	{ table_name = "ngram_heptagrams", mark = "hp" },
}

-- Characters that end a word, besides the Lua whitespace class: the Windows
-- walker's set, which macOS shared. Not locale-aware on purpose, so word lists
-- stay comparable across languages.
local WORD_SEPARATOR_PATTERN = "[%s.,!?;:\"'()%%{}%[%]<>=+*/\\|%-]"
local EXTRA_WORD_SEPARATORS = {
	["\n"] = true,
	["\194\160"] = true, -- U+00A0 NO-BREAK SPACE
	["\226\128\175"] = true, -- U+202F NARROW NO-BREAK SPACE
}

-- Joins date, app and token into one batch key, as the writers split it.
local SEPARATOR = "\1"




-- =================================
-- =================================
-- ======= 1/ Small helpers ========
-- =================================
-- =================================

--- Whether a character ends the open word.
--- @param char string
--- @return boolean
local function is_word_separator(char)
	return type(char) == "string"
		and (char:match(WORD_SEPARATOR_PATTERN) ~= nil or EXTRA_WORD_SEPARATORS[char] == true)
end

--- Pops the newest erasable history entry and flags its n-grams as errors.
--- @param batch table
--- @param ctx table
--- @param date_str string
--- @param app string
--- @param synth_type string Source of the correcting backspace.
local function flag_erased(batch, ctx, date_str, app, synth_type)
	local erased = table.remove(ctx.hist)
	if not erased or erased.c == BACKSPACE then return end
	for _, family in ipairs(FAMILIES) do
		local token = erased[family.mark]
		if token then Helpers.push_ngram(batch, family.table_name, date_str, app, token, 0, true, synth_type) end
	end
end

--- Records a finished word and its bigram with the previous word.
--- @param batch table
--- @param ctx table
--- @param date_str string
--- @param app string
local function end_word(batch, ctx, date_str, app)
	if #ctx.cur_word == 0 then return end
	if ctx.prev_word then
		Helpers.push_ngram(batch, "ngram_word_bigrams", date_str, app,
			ctx.prev_word .. " " .. ctx.cur_word, 0, ctx.word_err, "none")
	end
	Helpers.push_ngram(batch, "ngram_words", date_str, app, ctx.cur_word, 0, ctx.word_err, "none")
end

--- Keeps the newest HIST_CAP erasable entries only (the Windows HIST_CAP).
--- @param ctx table
--- @param entry table
local function remember(ctx, entry)
	ctx.hist[#ctx.hist + 1] = entry
	if #ctx.hist > Helpers.HIST_CAP then table.remove(ctx.hist, 1) end
end

--- Adds one value to the trigger-input pause buckets of a synthetic correction.
--- @param batch table
--- @param app_day_key string
--- @param date_str string
--- @param app string
--- @param delay number Delay of the typed trigger keystroke.
--- @param prefix string "hs" or "llm".
local function bump_input_buckets(batch, app_day_key, date_str, app, delay, prefix)
	for _, threshold in ipairs(Helpers.UI_PAUSE_BUCKETS_MS) do
		if delay <= threshold then
			local row = Helpers.gc(batch.app_buckets, app_day_key .. SEPARATOR .. tostring(threshold), {
				date = date_str, app = app, bucket_ms = threshold,
				time_sum = 0, credited = 0, hs_in_t = 0, hs_in_c = 0, llm_in_t = 0, llm_in_c = 0,
			})
			row[prefix .. "_in_t"] = row[prefix .. "_in_t"] + delay
			row[prefix .. "_in_c"] = row[prefix .. "_in_c"] + 1
		end
	end
end

--- Extends or restarts the same-finger and same-hand runs for one keystroke.
--- A keystroke whose finger is unknown breaks both runs rather than guessing.
--- Exported for the macOS physical channel, which keeps its own runs.
--- @param ergo table|nil The app-day ergonomics row; nil only to break the runs.
--- @param ctx table
--- @param finger string|nil
function M.advance_streak(ergo, ctx, finger)
	if not finger then
		ctx.last_finger, ctx.same_finger_run, ctx.same_hand_run = nil, 0, 0
		return
	end
	ctx.same_finger_run = ctx.last_finger == finger and (ctx.same_finger_run or 1) + 1 or 1
	ctx.same_hand_run = ctx.last_finger and ctx.last_finger:sub(1, 1) == finger:sub(1, 1)
		and (ctx.same_hand_run or 1) + 1 or 1
	ctx.last_finger = finger
	if ctx.same_finger_run > ergo.same_finger_streak_max then ergo.same_finger_streak_max = ctx.same_finger_run end
	if ctx.same_hand_run > ergo.same_hand_streak_max then ergo.same_hand_streak_max = ctx.same_hand_run end
end

--- Resolves an entry's own hour and five-minute slot from its timestamp
--- ("YYYY-MM-DD HH:MM…"), the Windows and macOS policy: a batch replayed late
--- still bins to the hour it was typed in. A malformed minute uses slot zero.
--- @param timestamp string|nil
--- @return table|nil { hour = "HH", min5 = "HH:MM" }, nil without a timestamp.
function M.timestamp_slot(timestamp)
	if type(timestamp) ~= "string" then return nil end
	local hour, minute = timestamp:sub(12, 13), timestamp:sub(15, 16)
	if not hour:match("^%d%d$") then return nil end
	local minutes = tonumber(minute) or 0
	return { hour = hour, min5 = string.format("%s:%02d", hour, math.floor(minutes / 5) * 5) }
end




-- =================================
-- =================================
-- ======= 2/ Construction =========
-- =================================
-- =================================

--- Builds a walker for one driver.
--- @param config table {
---   timings = { max_keystroke_delay_ms, think_pause_ms, burst_gap_ms,
---               session_gap_ms, auto_repeat_max_delay_ms } (milliseconds),
---   finger_of = function(char, meta) -> finger name ("l_idx"…) or nil }
--- @return table walker { walk_typing, walk_app_switch, walk_window_switch, settle }
function M.new(config)
	assert(type(config) == "table", "walker config must be a table")
	assert(type(config.timings) == "table", "walker config requires timings")
	local T = {}
	for _, key in ipairs(REQUIRED_TIMINGS) do
		local value = config.timings[key]
		assert(type(value) == "number" and value > 0 and value == value and value ~= math.huge,
			"walker timing " .. key .. " must be a positive number")
		T[key] = value
	end
	assert(type(config.finger_of) == "function", "walker config requires finger_of(char, meta)")
	local finger_of = config.finger_of

	local W = {}

	--- Replays one typing entry into the batch, continuing the application's
	--- context and leaving it updated for the next entry.
	--- @param batch table A batch from aggregator_helpers.new_batch.
	--- @param ctx table The application's context (aggregator_helpers.get_app_ctx).
	--- @param entry table { app, date, timestamp, events = {{char, delay, meta}…},
	---        layout, title }. `date` defaults to the timestamp's day.
	--- @param slot_of function|nil Given (index, event), the keystroke's
	---        { hour, min5 }; nil skips the time-of-day tables for that keystroke.
	---        Defaults to the entry timestamp's slot for every keystroke.
	--- @param gap_of function|nil Given (index, delay), the uncapped gap since the
	---        previous manual keystroke, for the session cut. Defaults to delay.
	function W.walk_typing(batch, ctx, entry, slot_of, gap_of)
		local events = entry.events
		if type(events) ~= "table" then return end
		local app = entry.app or "Unknown"
		local date_str = entry.date or (type(entry.timestamp) == "string" and entry.timestamp:sub(1, 10)) or nil
		assert(type(date_str) == "string" and date_str:match("^%d%d%d%d%-%d%d%-%d%d$"),
			"a typing entry requires its date or timestamp")
		if not slot_of then
			local slot = M.timestamp_slot(entry.timestamp)
			slot_of = function() return slot end
		end

		local app_day_key = date_str .. SEPARATOR .. app
		local cc = Helpers.gc(batch.chars_class, app_day_key,
			{ date = date_str, app = app, letter = 0, digit = 0, punct = 0, space = 0, other = 0 })
		local er = Helpers.gc(batch.errors, app_day_key, { date = date_str, app = app,
			bs_total = 0, cascade_count = 0, cascade_max_len = 0, recovery_sum_ms = 0, recovery_count = 0 })
		local eg = Helpers.gc(batch.ergo, app_day_key, { date = date_str, app = app,
			same_finger_streak_max = 0, same_hand_streak_max = 0, auto_repeat_count = 0,
			focus_to_first_key_sum_ms = 0, focus_to_first_key_count = 0 })

		--- The hour and five-minute rows of one keystroke, or nil without a slot.
		local function time_rows(index, event)
			local slot = slot_of(index, event)
			if not slot then return nil, nil, nil end
			local hr = Helpers.gc(batch.hourly, app_day_key .. SEPARATOR .. slot.hour,
				{ date = date_str, app = app, hour = slot.hour, c = 0, e = 0, em = 0, es = 0, e_buckets = {} })
			local m5 = Helpers.gc(batch.hourly_min5, app_day_key .. SEPARATOR .. slot.min5,
				{ date = date_str, app = app, slot = slot.min5, c = 0, e = 0, es = 0, e_buckets = {} })
			return hr, m5, slot
		end

		if type(entry.layout) == "string" and entry.layout ~= "" then
			local row = Helpers.gc(batch.layouts, app_day_key .. SEPARATOR .. entry.layout,
				{ date = date_str, app = app, layout = entry.layout, count = 0 })
			row.count = row.count + 1
		end
		if type(entry.title) == "string" and entry.title ~= "" then
			local row = Helpers.gc(batch.titles, app_day_key .. SEPARATOR .. entry.title,
				{ date = date_str, app = app, title = entry.title, c = 0, ms = 0 })
			row.c = row.c + 1
		end

		local prev_synth_type = "none"
		for index, ev in ipairs(events) do
			local char = ev[1]
			local delay = tonumber(ev[2]) or 0
			local meta = type(ev[3]) == "table" and ev[3] or {}
			local shortcut_key = meta.sc
			local synth_type = type(meta.st) == "string" and meta.st or "none"
			local is_synthetic = meta.s == true or meta.s == 1

			if type(shortcut_key) == "string" and shortcut_key ~= "" then
				-- Shortcuts are indexed apart and take no part in the n-gram chain.
				local sc = Helpers.gc(batch.sc_ngram.ngram_shortcuts, app_day_key .. SEPARATOR .. shortcut_key,
					{ date = date_str, app = app, token = shortcut_key, count = 0 })
				sc.count = sc.count + 1
				if ctx.prev_sc then
					local token = ctx.prev_sc .. "→" .. shortcut_key
					local bg = Helpers.gc(batch.sc_ngram.ngram_shortcut_bigrams, app_day_key .. SEPARATOR .. token,
						{ date = date_str, app = app, token = token, count = 0 })
					bg.count = bg.count + 1
				end
				ctx.prev_sc = shortcut_key
			else
				-- A long pause breaks n-gram continuity: two characters either side
				-- of a break are not a sequence, and a backspace after it erases
				-- nothing typed before it.
				if delay >= T.max_keystroke_delay_ms and not is_synthetic then
					ctx.p1, ctx.p2, ctx.p3, ctx.p4, ctx.p5, ctx.p6 = nil, nil, nil, nil, nil, nil
					ctx.hist = {}
					end_word(batch, ctx, date_str, app)
					ctx.cur_word, ctx.word_err, ctx.prev_word, ctx.prev_sc = "", false, nil, nil
				end

				-- A synthetic burst counts one trigger.
				if is_synthetic and synth_type ~= "none" and synth_type ~= prev_synth_type then
					if synth_type == "hotstring" then
						Helpers.bump_app_day(batch, date_str, app, "hs_triggers", 1)
					elseif synth_type == "llm" then
						Helpers.bump_app_day(batch, date_str, app, "llm_triggers", 1)
					end
				end
				prev_synth_type = is_synthetic and synth_type or "none"

				if char == BACKSPACE then
					flag_erased(batch, ctx, date_str, app, synth_type)
					ctx.cur_word = Utils.pop_utf8(ctx.cur_word)
					ctx.word_err = true
					local hr, m5 = time_rows(index, ev)

					if is_synthetic then
						-- The driver erasing its own trigger: not the user's mistake.
						if hr then hr.es = hr.es + 1; m5.es = m5.es + 1 end
						local trigger = table.remove(ctx.recent_typing)
						if synth_type == "hotstring" or synth_type == "llm" then
							local prefix = synth_type == "hotstring" and "hs" or "llm"
							-- Gross output stays gross: the page subtracts the trigger
							-- input recorded here exactly once to obtain the net gain.
							Helpers.bump_app_day(batch, date_str, app, prefix .. "_input_chars", 1)
							if trigger and type(trigger.delay) == "number" then
								bump_input_buckets(batch, app_day_key, date_str, app, trigger.delay, prefix)
							end
						end
					else
						if hr then
							hr.e, hr.em, m5.e = hr.e + 1, hr.em + 1, m5.e + 1
							Helpers.bucket_add(hr.e_buckets, delay, 1)
							Helpers.bucket_add(m5.e_buckets, delay, 1)
						end
						Helpers.bump_app_day(batch, date_str, app, "chars", 1)
						if delay > T.think_pause_ms then
							Helpers.bump_app_day(batch, date_str, app, "think_time_ms", delay)
							Helpers.bump_app_day(batch, date_str, app, "pauses", 1)
						else
							Helpers.bump_app_day(batch, date_str, app, "time_ms", delay)
						end
						table.remove(ctx.recent_typing)
						ctx.bs_run_len = ctx.bs_run_len + 1
						ctx.last_was_bs = true
						er.bs_total = er.bs_total + 1
						M.advance_streak(eg, ctx, nil)
						ctx.last_char = nil
					end

					-- The correction itself chains: "x[BS]" and "yx[BS]".
					local marks = { c = BACKSPACE }
					Helpers.push_ngram(batch, "ngram_chars", date_str, app, BACKSPACE, delay, false, synth_type)
					if ctx.p1 then
						marks.bg = ctx.p1 .. BACKSPACE
						Helpers.push_ngram(batch, "ngram_bigrams", date_str, app, marks.bg, delay, false, synth_type)
					end
					if ctx.p2 then
						marks.tg = ctx.p2 .. ctx.p1 .. BACKSPACE
						Helpers.push_ngram(batch, "ngram_trigrams", date_str, app, marks.tg, delay, false, synth_type)
					end
					remember(ctx, marks)
					ctx.p6, ctx.p5, ctx.p4, ctx.p3, ctx.p2, ctx.p1 = ctx.p5, ctx.p4, ctx.p3, ctx.p2, ctx.p1, BACKSPACE
				else
					-- The bounded delay belongs to the last keystroke of each token; a
					-- gap that broke continuity still counts its character.
					local ngram_delay = delay < T.max_keystroke_delay_ms and delay or 0
					local previous = { ctx.p1, ctx.p2, ctx.p3, ctx.p4, ctx.p5, ctx.p6 }
					local marks = {}
					local token = char
					for length, family in ipairs(FAMILIES) do
						if length > 1 then
							local before = previous[length - 1]
							if not before then break end
							token = before .. token
						end
						Helpers.push_ngram(batch, family.table_name, date_str, app, token, ngram_delay, false, synth_type)
						marks[family.mark] = token
					end

					if not is_synthetic then
						local hr, m5, slot = time_rows(index, ev)
						Helpers.bump_app_day(batch, date_str, app, "chars", 1)
						if hr then hr.c = hr.c + 1; m5.c = m5.c + 1 end
						if delay > T.think_pause_ms then
							Helpers.bump_app_day(batch, date_str, app, "think_time_ms", delay)
							Helpers.bump_app_day(batch, date_str, app, "pauses", 1)
						else
							Helpers.bump_app_day(batch, date_str, app, "time_ms", delay)
						end
						for _, threshold in ipairs(Helpers.UI_PAUSE_BUCKETS_MS) do
							if delay <= threshold then
								local row = Helpers.gc(batch.app_buckets, app_day_key .. SEPARATOR .. tostring(threshold), {
									date = date_str, app = app, bucket_ms = threshold,
									time_sum = 0, credited = 0, hs_in_t = 0, hs_in_c = 0, llm_in_t = 0, llm_in_c = 0,
								})
								row.time_sum = row.time_sum + delay
								row.credited = row.credited + 1
							end
						end
						ctx.recent_typing[#ctx.recent_typing + 1] = { delay = delay }
						if #ctx.recent_typing > Helpers.TRIGGER_LOOKBACK_LEN then table.remove(ctx.recent_typing, 1) end

						if not ctx.current_burst or delay > T.burst_gap_ms then
							Helpers.finalize_burst(batch, date_str, app, ctx.current_burst)
							ctx.current_burst = { char_count = 1, sum_delays = 0, sum_delays_sq = 0, max_delay = 0 }
						else
							local b = ctx.current_burst
							b.char_count = b.char_count + 1
							b.sum_delays = b.sum_delays + delay
							b.sum_delays_sq = b.sum_delays_sq + delay * delay
							if delay > b.max_delay then b.max_delay = delay end
						end

						local gap = gap_of and gap_of(index, delay) or delay
						if not ctx.current_session or gap > T.session_gap_ms then
							Helpers.finalize_session(batch, date_str, app, ctx.current_session)
							ctx.current_session = { char_count = 1, total_ms = 0 }
						else
							local s = ctx.current_session
							s.char_count = s.char_count + 1
							s.total_ms = s.total_ms + delay
						end

						if ctx.last_was_bs then
							if ctx.bs_run_len >= Helpers.CASCADE_MIN_BS then
								er.cascade_count = er.cascade_count + 1
								if ctx.bs_run_len > er.cascade_max_len then er.cascade_max_len = ctx.bs_run_len end
							end
							if delay <= T.max_keystroke_delay_ms then
								er.recovery_sum_ms = er.recovery_sum_ms + delay
								er.recovery_count = er.recovery_count + 1
							end
							ctx.bs_run_len, ctx.last_was_bs = 0, false
						end

						M.advance_streak(eg, ctx, finger_of(char, meta))
						if ctx.last_char == char and delay > 0 and delay <= T.auto_repeat_max_delay_ms then
							eg.auto_repeat_count = eg.auto_repeat_count + 1
						end
						ctx.last_char = char

						local class = Utils.char_class(char)
						cc[class] = cc[class] + 1
						if slot then
							if not cc.first_typed_min then cc.first_typed_min = slot.min5 end
							cc.last_typed_min = slot.min5
						end
					elseif synth_type == "hotstring" then
						Helpers.bump_app_day(batch, date_str, app, "hs_chars", 1)
					elseif synth_type == "llm" then
						Helpers.bump_app_day(batch, date_str, app, "llm_chars", 1)
					end

					if is_word_separator(char) then
						if #ctx.cur_word > 0 then
							end_word(batch, ctx, date_str, app)
							ctx.prev_word, ctx.cur_word, ctx.word_err = ctx.cur_word, "", false
						end
					else
						ctx.cur_word = ctx.cur_word .. char
					end
					remember(ctx, marks)
					ctx.p6, ctx.p5, ctx.p4, ctx.p3, ctx.p2, ctx.p1 = ctx.p5, ctx.p4, ctx.p3, ctx.p2, ctx.p1, char
				end
			end

			if not is_synthetic and type(meta.kc) == "number" then
				local row = Helpers.gc(batch.kc_ngram, app_day_key .. SEPARATOR .. tostring(meta.kc),
					{ date = date_str, app = app, keycode = meta.kc, count = 0 })
				row.count = row.count + 1
			end
		end

		Helpers.bump_app_day(batch, date_str, app, "_category_seed", 0)
	end

	--- Credits the time spent in the application left on an app switch, and the
	--- directed switch itself.
	--- @param batch table
	--- @param entry table { prev_app, next_app, timestamp, duration_ms }
	function W.walk_app_switch(batch, entry)
		if not entry.prev_app then return end
		local date_str = entry.timestamp:sub(1, 10)
		local row = Helpers.gc(batch.app_time, date_str .. SEPARATOR .. entry.prev_app,
			{ date = date_str, app = entry.prev_app, ms = 0 })
		row.ms = row.ms + (entry.duration_ms or 0)
		if entry.next_app then
			local switch = Helpers.gc(batch.switches_to,
				date_str .. SEPARATOR .. entry.prev_app .. SEPARATOR .. entry.next_app,
				{ date = date_str, app_from = entry.prev_app, app_to = entry.next_app, count = 0 })
			switch.count = switch.count + 1
		end
	end

	--- Credits the time spent on the window left on a window switch.
	--- @param batch table
	--- @param entry table { app, prev_title, timestamp, duration_ms }
	function W.walk_window_switch(batch, entry)
		if type(entry.prev_title) ~= "string" or entry.prev_title == "" then return end
		local date_str = entry.timestamp:sub(1, 10)
		local app = entry.app or "Unknown"
		local row = Helpers.gc(batch.titles, date_str .. SEPARATOR .. app .. SEPARATOR .. entry.prev_title,
			{ date = date_str, app = app, title = entry.prev_title, c = 0, ms = 0 })
		row.ms = row.ms + (entry.duration_ms or 0)
	end

	--- Credits what a context still holds once it has provably ended: a pause
	--- ends the word, the sequence and the correction; a burst and a session end
	--- at their gaps. `force` ends everything, for a new day or a shutdown. The
	--- totals are those one walk over the whole stream would give, credited
	--- earlier and to the day they were typed on.
	--- @param batch table
	--- @param ctx table
	--- @param date_str string Day the context belongs to.
	--- @param app string
	--- @param gap number|nil Milliseconds since the last manual keystroke; nil
	---        judges nothing unless forced.
	--- @param force boolean|nil
	--- @return boolean credited Whether any row was credited.
	function W.settle(batch, ctx, date_str, app, gap, force)
		local credited = false
		local function ended(threshold, inclusive)
			if force then return true end
			if gap == nil then return false end
			return gap > threshold or (inclusive and gap == threshold)
		end
		-- The walk treats a delay AT the pause threshold as a pause, hence inclusive.
		if ended(T.max_keystroke_delay_ms, true) then
			if ctx.last_was_bs and (ctx.bs_run_len or 0) > 0 then
				local er = Helpers.gc(batch.errors, date_str .. SEPARATOR .. app, { date = date_str, app = app,
					bs_total = 0, cascade_count = 0, cascade_max_len = 0, recovery_sum_ms = 0, recovery_count = 0 })
				if ctx.bs_run_len >= Helpers.CASCADE_MIN_BS then
					er.cascade_count = er.cascade_count + 1
					if ctx.bs_run_len > er.cascade_max_len then er.cascade_max_len = ctx.bs_run_len end
				end
				credited = true
			end
			ctx.bs_run_len, ctx.last_was_bs = 0, false
			if #(ctx.cur_word or "") > 0 then
				end_word(batch, ctx, date_str, app)
				credited = true
			end
			ctx.cur_word, ctx.prev_word, ctx.word_err = "", nil, false
			ctx.p1, ctx.p2, ctx.p3, ctx.p4, ctx.p5, ctx.p6 = nil, nil, nil, nil, nil, nil
			ctx.hist = {}
		end
		if ctx.current_burst and ended(T.burst_gap_ms) then
			Helpers.finalize_burst(batch, date_str, app, ctx.current_burst)
			ctx.current_burst = nil
			credited = true
		end
		if ctx.current_session and ended(T.session_gap_ms) then
			Helpers.finalize_session(batch, date_str, app, ctx.current_session)
			ctx.current_session = nil
			credited = true
		end
		return credited
	end

	return W
end

return M
