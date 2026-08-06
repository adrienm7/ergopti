--- modules/keylogger/aggregate_walker.lua

--- ==============================================================================
--- MODULE: Aggregate Walker (Linux)
--- DESCRIPTION:
--- One pass over a buffered character stream, producing the derived tables the
--- dashboard reads: the nine n-gram families, the character-class breakdown, the
--- error analysis, the hour-by-hour and five-minute activity histograms, the
--- burst and session records, and the cumulative pause buckets behind the
--- "ignore pauses longer than…" control. It uses the driver-agnostic
--- accumulators in _shared/lua/keylogger/aggregator_helpers.lua.
---
--- WHAT WAS THERE BEFORE:
--- One n-gram family and nothing else. This driver counted single characters, so
--- eight of the nine n-gram tables and all twelve per-app-day aggregate tables
--- were empty BY CONSTRUCTION — not by accident, and not recoverable from the
--- data already stored. The same-finger analysis, the word lists, the error
--- analysis, the activity timeline and the heatmap's first/last counts each had
--- nothing to read and rendered blank, on a driver that had been collecting
--- keystrokes the whole time.
---
--- WHY ONE PASS AND NOT SEVERAL MODULES:
--- Every one of these tables depends on the same three rules about what counts
--- as a continuous run. Splitting them across modules would mean restating those
--- rules, and a divergence between two copies is invisible until the numbers
--- disagree — at which point neither is trustworthy. macOS reached the same
--- conclusion; its aggregator is one walk for the same reason.
---
--- FEATURES & RATIONALE:
--- 1. The accumulators are shared. `new_batch` already names all nine n-gram
---    tables and every aggregate sub-table, and `push_ngram` already carries the
---    delay, the error flag and the synthetic source into each row. macOS was
---    their only consumer; nothing here needed writing except the walk.
--- 2. A long pause breaks continuity. Two characters either side of a coffee
---    break are not a bigram, and counting them as one puts a phantom pair into
---    the same-finger analysis that no hand ever typed. The threshold is the
---    cross-driver one from the shared timing canon.
--- 3. Synthetic output does not become a typing n-gram. A hotstring's expansion
---    is text the user did not type; folding it into the bigram counts would
---    make the layout look better the more expansions they use, which is exactly
---    backwards for a tool that measures typing effort.
--- 4. Pure. It takes a stream and returns a batch — no clock, no database, no
---    file. The wall-clock offset needed to place a keystroke in an hour arrives
---    as a parameter, so everything it decides stays decidable on a machine with
---    no keyboard and a frozen clock.
--- ==============================================================================

local M = {}

local Helpers = require("keylogger.aggregator_helpers")
local Timings = require("infra.timings")

-- Beyond this gap two keystrokes are not a sequence. Shared with the other two
-- drivers through the timing canon rather than restated here.
local MAX_KEYSTROKE_DELAY_MS = Timings.ms("keylogger", "max_keystroke_delay_ms")

-- The order matters: index N holds the table for an N-character token, so a
-- single loop can push every length the stream currently supports.
local FAMILY_FOR_LENGTH = {
	[1] = "ngram_chars",
	[2] = "ngram_bigrams",
	[3] = "ngram_trigrams",
	[4] = "ngram_quadgrams",
	[5] = "ngram_pentagrams",
	[6] = "ngram_hexagrams",
	[7] = "ngram_heptagrams",
}

-- What a backspace marker looks like in the buffered stream.
local BACKSPACE_MARKER = "[BS]"

-- A run of at least this many consecutive backspaces is one cascade rather than
-- N separate corrections — the shared constant, so the three drivers agree on
-- what counts as having to go back and fix a whole word.
local CASCADE_MIN_BS = Helpers.CASCADE_MIN_BS

-- Beyond this gap the user stopped and started again: a new burst below, and a
-- new typing session at the coarser threshold. Both come from the shared canon
-- so the three drivers cut their bursts in the same places.
local BURST_GAP_MS = Timings.ms("keylogger", "burst_gap_ms")
local SESSION_GAP_MS = Timings.ms("keylogger", "session_gap_ms")

-- Minutes per slot in the fine-grained activity histogram. The schema names the
-- column "min5" and the dashboard labels its axis in five-minute steps; this is
-- the number both of those mean.
local MIN5_STEP_MINUTES = 5

-- What joins date, app and token into one map key. Spelled once because the
-- reader of these keys splits on it, and a literal escape repeated at six sites
-- is exactly how a writer and its reader quietly stop agreeing.
local SEPARATOR = "\1"

-- Milliseconds in a second, for turning a monotonic stamp into the wall-clock
-- hour a keystroke belongs to.
local MS_PER_SECOND = 1000

-- What separates words. Deliberately not a locale-aware rule: the dashboard
-- compares word lists across languages, and a French-only definition of a word
-- boundary would make two users' corpora incomparable.
local WORD_SEPARATORS = { [" "] = true, ["\n"] = true, ["\t"] = true }




-- =========================================
-- =========================================
-- ======= 1/ Walking ======================
-- =========================================
-- =========================================

--- Whether an event was produced by the driver rather than by the user.
--- @param event table A buffered typing event.
--- @return boolean is_synthetic, string source
local function synthetic_of(event)
	local meta = event[3]
	if type(meta) ~= "table" then return false, "none" end
	local is_synthetic = meta.s == 1 or meta.s == true
	return is_synthetic, (is_synthetic and type(meta.st) == "string") and meta.st or "none"
end

--- Which class a character belongs to in the composition breakdown.
---
--- Byte patterns, not a Unicode table: accented letters arrive as multi-byte
--- sequences that `%a` does not match, so anything outside ASCII is classified
--- as a letter rather than as "other". A French corpus is mostly accented text,
--- and filing it under "other" would make the breakdown say nothing at all.
--- @param char string
--- @return string One of "letter", "digit", "punct", "space", "other".
local function class_of(char)
	if char == "" then return "other" end
	if #char > 1 then return "letter" end
	if char:match("^%s$") then return "space" end
	if char:match("^%d$") then return "digit" end
	if char:match("^%a$") then return "letter" end
	if char:match("^%p$") then return "punct" end
	return "other"
end

--- Replays one application's buffered stream into the derived batch.
---
--- @param events table Array of { char, delay_ms, meta } as the keylogger buffers them.
--- @param date_str string "YYYY-MM-DD".
--- @param app string Application identifier.
--- @param batch table|nil An existing batch to add to; a fresh one when absent.
--- @param clock table|nil { times = {monotonic_ms…}, wall_offset_ms = n } to place
---        keystrokes on the wall clock. Absent means the time-of-day tables are
---        skipped rather than filled with a guess.
--- @return table The batch.
function M.walk(events, date_str, app, batch, clock)
	batch = batch or Helpers.new_batch()
	if type(events) ~= "table" then return batch end

	-- The tail of the current run, newest last. Cleared by a pause, a backspace
	-- or a switch to synthetic output, because each of those means the next
	-- character does not follow the previous one from the same hand.
	local run = {}
	local word, previous_word = "", nil

	local app_day_key = date_str .. SEPARATOR .. app
	local classes = Helpers.gc(batch.chars_class, app_day_key, {
		date = date_str, app = app,
		letter = 0, digit = 0, punct = 0, space = 0, other = 0,
	})
	local errors = Helpers.gc(batch.errors, app_day_key, {
		date = date_str, app = app,
		bs_total = 0, cascade_count = 0, cascade_max_len = 0,
		recovery_sum_ms = 0, recovery_count = 0,
	})

	-- How many backspaces in a row we are currently inside. A cascade is only
	-- knowable once the run ENDS, so it is closed on the next ordinary keystroke
	-- and again after the loop — a stream that ends mid-correction still counts.
	local backspace_run = 0

	--- Closes an in-progress correction, crediting the cascade and the time the
	--- user took to resume.
	--- @param resume_delay number|nil Milliseconds before the next ordinary keystroke.
	local function close_correction(resume_delay)
		if backspace_run == 0 then return end
		if backspace_run >= CASCADE_MIN_BS then
			errors.cascade_count = errors.cascade_count + 1
			if backspace_run > errors.cascade_max_len then
				errors.cascade_max_len = backspace_run
			end
		end
		-- Only a prompt resumption is recovery time. Past the pause threshold the
		-- user stopped typing rather than thought about the fix, and folding that
		-- in would report a coffee break as the cost of a typo.
		if resume_delay and resume_delay <= MAX_KEYSTROKE_DELAY_MS then
			errors.recovery_sum_ms = errors.recovery_sum_ms + resume_delay
			errors.recovery_count = errors.recovery_count + 1
		end
		backspace_run = 0
	end

	-- The burst and session currently open, or nil between them. A burst is a
	-- run of keystrokes with no real gap; a session is the coarser version of
	-- the same idea. Neither can be credited until it ENDS, because its length
	-- and its speed are only known then.
	local burst, session = nil, nil
	-- Two maps rather than one: the dashboard divides the total time by the
	-- number of keystrokes credited to get a mean delay, and a single map would
	-- give it only the numerator.
	local buckets = Helpers.gc(batch.app_buckets, app_day_key, { time = {}, credited = {} })

	--- Adds one keystroke to the open burst, or opens a new one.
	--- @param delay number Milliseconds since the previous keystroke.
	local function extend_burst(delay)
		if not burst or delay > BURST_GAP_MS then
			Helpers.finalize_burst(batch, date_str, app, burst)
			burst = { char_count = 1, sum_delays = 0, sum_delays_sq = 0, max_delay = 0 }
			return
		end
		burst.char_count = burst.char_count + 1
		burst.sum_delays = burst.sum_delays + delay
		-- The sum of squares is kept so the dashboard can compute a standard
		-- deviation without storing every delay: rhythm is as interesting as
		-- speed, and a burst of 200 characters would otherwise cost 200 rows.
		burst.sum_delays_sq = burst.sum_delays_sq + (delay * delay)
		if delay > burst.max_delay then burst.max_delay = delay end
	end

	--- Adds one keystroke to the open session, or opens a new one.
	--- @param delay number Milliseconds since the previous keystroke.
	local function extend_session(delay)
		if not session or delay > SESSION_GAP_MS then
			Helpers.finalize_session(batch, date_str, app, session)
			session = { char_count = 1, total_ms = 0 }
			return
		end
		session.char_count = session.char_count + 1
		session.total_ms = session.total_ms + delay
	end

	--- Credits one keystroke to its hour and its five-minute slot.
	--- @param index number Position in the stream, to look the timestamp up.
	local function bump_time_of_day(index)
		if type(clock) ~= "table" or type(clock.times) ~= "table" then return end
		local monotonic = tonumber(clock.times[index])
		if not monotonic then return end
		local wall_ms = monotonic + (tonumber(clock.wall_offset_ms) or 0)
		local seconds = math.floor(wall_ms / MS_PER_SECOND)
		local hour = os.date("%H", seconds)
		local minute = tonumber(os.date("%M", seconds)) or 0
		local slot = string.format("%s:%02d", hour,
			math.floor(minute / MIN5_STEP_MINUTES) * MIN5_STEP_MINUTES)

		-- The first and last minute the user typed in this application today. Kept
		-- on the class row because that is the row the schema puts them on, and
		-- because they answer the same question: what the day looked like, rather
		-- than how much of it there was.
		local minute_label = string.format("%s:%02d", hour, minute)
		if not classes.first_typed_min or minute_label < classes.first_typed_min then
			classes.first_typed_min = minute_label
		end
		if not classes.last_typed_min or minute_label > classes.last_typed_min then
			classes.last_typed_min = minute_label
		end

		local hourly = Helpers.gc(batch.hourly, app_day_key .. SEPARATOR .. hour, {
			date = date_str, app = app, hour = hour, c = 0, e = 0, em = 0, es = 0,
		})
		hourly.c = hourly.c + 1
		local min5 = Helpers.gc(batch.hourly_min5, app_day_key .. SEPARATOR .. slot, {
			date = date_str, app = app, slot = slot, c = 0, e = 0, es = 0,
		})
		min5.c = min5.c + 1
	end

	--- Ends the current word, if there is one.
	local function flush_word()
		if word == "" then return end
		if previous_word then
			Helpers.push_ngram(batch, "ngram_word_bigrams", date_str, app,
				previous_word .. " " .. word, 0, false, "none")
		end
		Helpers.push_ngram(batch, "ngram_words", date_str, app, word, 0, false, "none")
		previous_word = word
		word = ""
	end

	for index, event in ipairs(events) do
		local char  = event[1]
		local delay = tonumber(event[2]) or 0
		local is_synthetic, source = synthetic_of(event)

		if char == BACKSPACE_MARKER then
			-- A correction. The run is broken because what follows continues from
			-- a different character than it appears to, and the partial word is
			-- abandoned rather than recorded — the user was not writing it.
			run = {}
			word = ""
			-- A hotstring erases its own trigger, and those deletions are the
			-- driver's work rather than the user's mistakes. Counting them would
			-- make the measured error rate rise with every expansion.
			if not is_synthetic then
				errors.bs_total = errors.bs_total + 1
				backspace_run = backspace_run + 1
			end
		elseif is_synthetic then
			-- Counted so the source histogram stays honest about how much of the
			-- day's text the driver produced, but NOT chained: an expansion is not
			-- something the user's hands did, and letting it join the bigram counts
			-- would make the layout look better the more expansions they use.
			Helpers.push_ngram(batch, "ngram_chars", date_str, app, char, 0, false, source)
			run = {}
			word = ""
		else
			close_correction(delay)
			local class = class_of(char)
			classes[class] = classes[class] + 1
			bump_time_of_day(index)
			extend_burst(delay)
			extend_session(delay)
			-- Cumulative, not exclusive: each threshold answers "how much time is
			-- left if I ignore pauses longer than this", so a 200 ms gap belongs to
			-- every bucket at or above 200 ms. The dashboard dropdown reads one
			-- bucket and expects a total, not a slice.
			Helpers.bucket_add(buckets.time, delay, delay)
			Helpers.bucket_add(buckets.credited, delay, 1)

			if delay >= MAX_KEYSTROKE_DELAY_MS then
				-- Long enough that the next keystroke is a new movement, not the
				-- continuation of one. Two characters either side of a coffee break
				-- are not a bigram.
				flush_word()
				run = {}
				previous_word = nil
			end

			run[#run + 1] = char
			-- Only the last seven matter, and holding more would grow without bound
			-- on a long session.
			if #run > #FAMILY_FOR_LENGTH then table.remove(run, 1) end

			for length, family in ipairs(FAMILY_FOR_LENGTH) do
				if #run >= length then
					local token = table.concat(run, "", #run - length + 1, #run)
					-- The delay belongs to the LAST keystroke of the token, which is
					-- what the dashboard means by an n-gram's cost: how long the hand
					-- took to complete the sequence.
					Helpers.push_ngram(batch, family, date_str, app, token, delay, false, "none")
				end
			end

			if WORD_SEPARATORS[char] then
				flush_word()
			else
				word = word .. char
			end
		end
	end

	-- The stream ends mid-word far more often than not — a flush lands between
	-- keystrokes, not between sentences — so the tail is recorded rather than
	-- discarded. A correction still open at the end is closed with no resume
	-- time, for the same reason: the cascade happened whether or not the user
	-- has typed the next character yet.
	flush_word()
	close_correction(nil)
	-- A burst or session still open at the flush boundary is credited now rather
	-- than dropped. Persisting runs every few seconds, so "still open" is the
	-- common case: discarding it would lose almost every burst the user makes.
	Helpers.finalize_burst(batch, date_str, app, burst)
	Helpers.finalize_session(batch, date_str, app, session)
	return batch
end




-- =========================================
-- =========================================
-- ======= 2/ Reading a batch out ==========
-- =========================================
-- =========================================

--- Splits a batch's n-gram tables into per-table, per-app-day maps the writer
--- takes.
---
--- The batch keys rows by "date\1app\1token" because the shared accumulator has
--- to hold several applications at once; the writer takes one application at a
--- time. Undoing that here rather than in the writer keeps the writer's shape
--- the same as its five siblings.
--- @param batch table
--- @return table Array of { table_name, date, app, ngrams }.
function M.batches_for_writer(batch)
	local out = {}
	if type(batch) ~= "table" or type(batch.ngram) ~= "table" then return out end

	for table_name, rows in pairs(batch.ngram) do
		local grouped = {}
		for key, item in pairs(rows) do
			local date_str, app, token = key:match("^([^\1]*)\1([^\1]*)\1(.*)$")
			if date_str and token ~= "" then
				local bucket = grouped[date_str .. "\1" .. app]
				if not bucket then
					bucket = { date = date_str, app = app, ngrams = {} }
					grouped[date_str .. "\1" .. app] = bucket
				end
				-- The delay total travels with the count. Without it every token
				-- reads as free, and "which sequences cost you the most" — the
				-- question the same-finger analysis exists to answer — ranks a
				-- column of zeroes.
				bucket.ngrams[token] = {
					c       = item.c,
					td      = item.td,
					cd      = item.cd,
					e       = item.e,
					sources = item.esrc,
				}
			end
		end
		for _, bucket in pairs(grouped) do
			if next(bucket.ngrams) ~= nil then
				out[#out + 1] = {
					table_name = table_name,
					date       = bucket.date,
					app        = bucket.app,
					ngrams     = bucket.ngrams,
				}
			end
		end
	end
	return out
end

--- Reads the per-app-day aggregate rows out of a batch.
---
--- Returned as one flat array per table rather than as the batch's compound-key
--- maps, because the writer upserts a row at a time and the key it needs is
--- already inside each row.
--- @param batch table
--- @return table One array per aggregate table, keyed by the batch sub-table name.
function M.daily_rows(batch)
	local out = {
		chars_class = {}, errors = {}, hourly = {}, hourly_min5 = {},
		bursts = {}, sessions = {}, app_buckets = {},
	}
	if type(batch) ~= "table" then return out end
	for name, rows in pairs(out) do
		if name ~= "app_buckets" then
			for _, row in pairs(batch[name] or {}) do
				rows[#rows + 1] = row
			end
		end
	end

	-- The pause buckets accumulate as threshold-to-total maps per app-day, which
	-- is the shape the shared accumulator writes. The schema stores one row per
	-- threshold, so the maps are unrolled here rather than in the writer — the
	-- writer's job is one row at a time.
	for key, maps in pairs(batch.app_buckets or {}) do
		local date_str, app = key:match("^([^\1]*)\1(.*)$")
		if date_str and app then
			for threshold, time_sum in pairs(maps.time or {}) do
				out.app_buckets[#out.app_buckets + 1] = {
					date = date_str, app = app,
					bucket_ms = tonumber(threshold) or 0,
					time_sum = time_sum,
					-- The denominator of the mean the dashboard shows. Carried rather
					-- than inferred: dividing by a keystroke count that includes the
					-- pauses this bucket excludes gives a number that is wrong in the
					-- flattering direction, and plausible enough to be believed.
					credited = (maps.credited or {})[threshold] or 0,
				}
			end
		end
	end
	return out
end

return M
