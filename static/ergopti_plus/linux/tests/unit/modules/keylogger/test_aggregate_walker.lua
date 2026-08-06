--- tests/unit/modules/keylogger/test_aggregate_walker.lua

--- ==============================================================================
--- MODULE: Nine N-gram Families, Not One
--- DESCRIPTION:
--- The walk that turns a buffered character stream into the n-gram tables the
--- dashboard reads.
---
--- WHAT WAS THERE BEFORE:
--- One family. This driver counted single characters and nothing else, so eight
--- of the nine tables were empty BY CONSTRUCTION — not by accident, and not
--- recoverable from what had already been stored. Every panel built on them
--- rendered blank on a driver that had been collecting keystrokes all along:
--- the same-finger bigram analysis, the word lists, the error analysis, the
--- heatmap's first and last counts.
---
--- THE THREE RULES THAT MAKE THE COUNTS MEAN SOMETHING:
--- A long pause breaks the run — two characters either side of a coffee break
--- are not a bigram, and counting them as one puts a pair into the same-finger
--- analysis that no hand ever typed. A backspace breaks it — what follows
--- continues from a different character than it appears to. And synthetic output
--- never chains: a hotstring's expansion is text the user did not type, and
--- folding it into the bigram counts would make the layout look better the more
--- expansions they use, which is backwards for a tool that measures effort.
---
--- Each of those is a way to be quietly wrong rather than visibly broken, which
--- is why they are the cases below rather than "it produces some bigrams".
--- ==============================================================================

local helpers = require("tests.helpers")

local Fakes = helpers.load_module("tests.fakes")

local Walker = helpers.load_module("modules.keylogger.aggregate_walker")
local Timings = helpers.load_module("infra.timings")

local PAUSE_MS = Timings.ms("keylogger", "max_keystroke_delay_ms")

--- One buffered keystroke.
--- @param char string
--- @param delay number|nil
--- @param source string|nil "hotstring", "llm", … for synthetic output.
--- @return table
local function key(char, delay, source)
	if source then
		return { char, delay or 0, { s = 1, st = source } }
	end
	return { char, delay or 0, { s = 0 } }
end

--- Types a string as ordinary keystrokes at a comfortable pace.
--- @param text string
--- @param delay number|nil
--- @return table
local function typed(text, delay)
	local out = {}
	for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		out[#out + 1] = key(char, delay or 120)
	end
	return out
end

--- The count a family holds for one token.
--- @param batch table
--- @param family string
--- @param token string
--- @return number
local function count_of(batch, family, token)
	local rows = batch.ngram[family] or {}
	local item = rows["2026-08-06\1app\1" .. token]
	return item and item.c or 0
end




-- =================================================================
-- =================================================================
-- ======= 1/ Every family gets written ============================
-- =================================================================
-- =================================================================

helpers.describe("ngram walker: the nine families", function()

	helpers.it("produces tokens of every length from one to seven", function()
		local batch = Walker.walk(typed("abcdefgh"), "2026-08-06", "app")
		helpers.assert_eq(count_of(batch, "ngram_chars", "a"), 1)
		helpers.assert_eq(count_of(batch, "ngram_bigrams", "ab"), 1)
		helpers.assert_eq(count_of(batch, "ngram_trigrams", "abc"), 1)
		helpers.assert_eq(count_of(batch, "ngram_quadgrams", "abcd"), 1)
		helpers.assert_eq(count_of(batch, "ngram_pentagrams", "abcde"), 1)
		helpers.assert_eq(count_of(batch, "ngram_hexagrams", "abcdef"), 1)
		helpers.assert_eq(count_of(batch, "ngram_heptagrams", "abcdefg"), 1,
			"eight of these nine tables were empty by construction, so every panel "
				.. "built on them rendered blank on a driver that had been collecting "
				.. "keystrokes the whole time")
	end)

	helpers.it("records words and word pairs", function()
		local batch = Walker.walk(typed("le chat noir "), "2026-08-06", "app")
		helpers.assert_eq(count_of(batch, "ngram_words", "chat"), 1)
		helpers.assert_eq(count_of(batch, "ngram_word_bigrams", "le chat"), 1,
			"the word lists and the pair lists are two different panels, and both "
				.. "were empty")
	end)

	helpers.it("keeps the last word even though the stream ends mid-sentence", function()
		local batch = Walker.walk(typed("bonjour"), "2026-08-06", "app")
		helpers.assert_eq(count_of(batch, "ngram_words", "bonjour"), 1,
			"a flush lands between keystrokes, not between sentences, so discarding "
				.. "the tail would lose a word every time the daemon persists")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ What breaks a run ====================================
-- =================================================================
-- =================================================================

helpers.describe("ngram walker: what must not become a sequence", function()

	helpers.it("does not join two characters across a long pause", function()
		local batch = Walker.walk({
			key("a", 100), key("b", 100),
			key("c", PAUSE_MS + 5000),
			key("d", 100),
		}, "2026-08-06", "app")

		helpers.assert_eq(count_of(batch, "ngram_bigrams", "ab"), 1, "a normal pair still counts")
		helpers.assert_eq(count_of(batch, "ngram_bigrams", "bc"), 0,
			"two characters either side of a coffee break are not a bigram — counting "
				.. "them as one puts a pair into the same-finger analysis that no hand "
				.. "ever typed")
		helpers.assert_eq(count_of(batch, "ngram_bigrams", "cd"), 1,
			"and the run restarts cleanly afterwards")
	end)

	helpers.it("does not chain across a correction", function()
		local batch = Walker.walk({
			key("a", 100), key("b", 100),
			key("[BS]", 100),
			key("c", 100),
		}, "2026-08-06", "app")

		helpers.assert_eq(count_of(batch, "ngram_bigrams", "bc"), 0,
			"after a backspace the next character continues from a different one "
				.. "than it appears to; 'bc' is a pair the user never produced")
	end)

	helpers.it("counts a hotstring's output without chaining it", function()
		local batch = Walker.walk({
			key("b", 100), key("t", 100), key("w", 100),
			key("b", 0, "hotstring"), key("y", 0, "hotstring"),
		}, "2026-08-06", "app")

		helpers.assert_eq(count_of(batch, "ngram_bigrams", "by"), 0,
			"an expansion is text the user did not type. Folding it into the bigram "
				.. "counts makes the layout look better the more expansions they use, "
				.. "which is backwards for a tool that measures typing effort.")

		local rows = batch.ngram.ngram_chars["2026-08-06\1app\1b"]
		helpers.assert_not_nil(rows, "the character itself is still counted")
		helpers.assert_true((rows.esrc.hotstring or 0) > 0,
			"and tagged with where it came from, so the day's total stays honest "
				.. "about how much of it the driver produced")
	end)

	helpers.it("does not carry a word across a correction", function()
		local batch = Walker.walk({
			key("c", 100), key("h", 100), key("a", 100),
			key("[BS]", 100),
			key("t", 100), key(" ", 100),
		}, "2026-08-06", "app")
		helpers.assert_eq(count_of(batch, "ngram_words", "chat"), 0,
			"the user typed 'cha', deleted, then 't' — 'chat' is a word the walk "
				.. "would have invented")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 3/ Handing the batch to the writer ======================
-- =================================================================
-- =================================================================

helpers.describe("ngram walker: what the writer receives", function()

	helpers.it("splits the batch by table and by application-day", function()
		local batch = Walker.walk(typed("ab"), "2026-08-06", "firefox")
		Walker.walk(typed("cd"), "2026-08-06", "code", batch)

		local groups = Walker.batches_for_writer(batch)
		helpers.assert_true(#groups > 0, "the writer must receive something at all")

		local seen_apps, seen_tables = {}, {}
		for _, group in ipairs(groups) do
			seen_apps[group.app] = true
			seen_tables[group.table_name] = true
			helpers.assert_eq(group.date, "2026-08-06")
		end
		helpers.assert_true(seen_apps.firefox and seen_apps.code,
			"the accumulator holds several applications at once because one flush "
				.. "covers all of them; the writer takes one at a time, and undoing "
				.. "that here keeps the writer the same shape as its five siblings")
		helpers.assert_true(seen_tables.ngram_bigrams,
			"and the table name travels with the rows, or they all land in "
				.. "ngram_chars again")
	end)

	helpers.it("emits nothing for a family with no rows", function()
		local batch = Walker.walk({}, "2026-08-06", "app")
		helpers.assert_eq(#Walker.batches_for_writer(batch), 0,
			"an empty group would cost a sqlite3 spawn to write nothing, on a path "
				.. "that already runs several times a second")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 4/ They reach the database ==============================
-- =================================================================
-- =================================================================

helpers.describe("ngram walker: a real flush writes every family", function()

	helpers.it("hands more than one table to the writer", function()
		-- The walk and the writer were both correct in isolation before this test,
		-- and the flush called neither. A unit that works and is never invoked is
		-- the shape three separate defects in this driver have taken, so the join
		-- gets its own case.
		local calls = {}
		local writer_name = "modules.keylogger.sqlite_writer"
		local logger_name = "modules.keylogger.keylogger"
		local prev_writer, prev_logger = package.loaded[writer_name], package.loaded[logger_name]
		-- The shared double, with the one method this case reads about recorded in
		-- a shape it can assert on. A hand-written table here would go stale the
		-- next time the writer grows a method.
		local writer = Fakes.sqlite_writer()
		writer.upsert_ngrams = function(_device, _date, _app, ngrams, table_name)
			calls[#calls + 1] = { table_name = table_name or "ngram_chars", ngrams = ngrams }
			return true
		end
		package.loaded[writer_name] = writer
		package.loaded[logger_name] = nil

		local ok, err = pcall(function()
			local kl = require(logger_name)
			kl.init({ sqlite_path = "/tmp/ergopti_ngram_probe.sqlite" })
			kl.reset_session()
			kl.on_app_focus("app.test", 1000)
			local at = 1000
			for char in ("bonjour "):gmatch(".") do
				at = at + 120
				kl.on_keydown(char, at, "app.test")
			end
			kl.flush()
		end)

		package.loaded[writer_name] = prev_writer
		package.loaded[logger_name] = prev_logger
		helpers.assert_true(ok, "the flush must complete: " .. tostring(err))

		-- Anchored before the loop: with no calls at all the loop below runs zero
		-- times and every later assertion still reports "family missing", which
		-- is a true statement about a test that never observed anything.
		helpers.assert_true(#calls > 0,
			"the flush reached the writer zero times — nothing below can distinguish "
				.. "a missing family from a walk that never ran")

		local seen = {}
		for _, call in ipairs(calls) do seen[call.table_name] = true end
		helpers.assert_true(seen.ngram_chars, "the family that already worked must keep working")
		helpers.assert_true(seen.ngram_bigrams,
			"and the eight that never did must now arrive — the walk and the writer "
				.. "were each correct in isolation while the flush called neither")
		helpers.assert_true(seen.ngram_words,
			"including the word lists, which are their own dashboard panel")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 5/ The character composition ============================
-- =================================================================
-- =================================================================

helpers.describe("aggregate walker: what the day was made of", function()

	helpers.it("sorts characters into the five classes", function()
		local batch = Walker.walk(typed("ab 12 ,."), "2026-08-06", "app")
		local row = batch.chars_class["2026-08-06\1app"]
		helpers.assert_not_nil(row, "the breakdown row must exist")
		helpers.assert_eq(row.letter, 2)
		helpers.assert_eq(row.digit, 2)
		helpers.assert_eq(row.space, 2)
		helpers.assert_eq(row.punct, 2)
	end)

	helpers.it("counts an accented letter as a letter", function()
		local batch = Walker.walk(typed("éàü"), "2026-08-06", "app")
		local row = batch.chars_class["2026-08-06\1app"]
		helpers.assert_eq(row.letter, 3,
			"these arrive as multi-byte sequences that the ASCII class pattern does "
				.. "not match. Filing them under 'other' would make the breakdown "
				.. "meaningless for a French corpus, which is most of this one.")
		helpers.assert_eq(row.other, 0)
	end)

	helpers.it("does not count an expansion as something the user typed", function()
		local batch = Walker.walk({
			key("a", 100),
			key("b", 0, "hotstring"), key("c", 0, "hotstring"),
		}, "2026-08-06", "app")
		local row = batch.chars_class["2026-08-06\1app"]
		helpers.assert_eq(row.letter, 1,
			"the composition breakdown answers what the USER typed. Counting the "
				.. "driver's own output would make the profile drift towards whatever "
				.. "the expansions happen to contain.")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 6/ The error analysis ===================================
-- =================================================================
-- =================================================================

helpers.describe("aggregate walker: corrections", function()

	helpers.it("counts manual backspaces", function()
		local batch = Walker.walk({
			key("a", 100), key("[BS]", 100), key("[BS]", 100), key("b", 100),
		}, "2026-08-06", "app")
		helpers.assert_eq(batch.errors["2026-08-06\1app"].bs_total, 2)
	end)

	helpers.it("does not count the deletions a hotstring makes to erase its trigger", function()
		local batch = Walker.walk({
			key("b", 100), key("t", 100), key("w", 100),
			key("[BS]", 0, "hotstring"), key("[BS]", 0, "hotstring"), key("[BS]", 0, "hotstring"),
			key("b", 0, "hotstring"),
		}, "2026-08-06", "app")
		helpers.assert_eq(batch.errors["2026-08-06\1app"].bs_total, 0,
			"those deletions are the driver erasing its own trigger. Counting them "
				.. "would make the measured error rate rise with every expansion — the "
				.. "feature would look like it makes the user worse.")
	end)

	helpers.it("counts a run of three or more as one cascade", function()
		local batch = Walker.walk({
			key("a", 100),
			key("[BS]", 100), key("[BS]", 100), key("[BS]", 100), key("[BS]", 100),
			key("b", 100),
		}, "2026-08-06", "app")
		local row = batch.errors["2026-08-06\1app"]
		helpers.assert_eq(row.cascade_count, 1,
			"four deletions in a row are one correction, not four")
		helpers.assert_eq(row.cascade_max_len, 4)
	end)

	helpers.it("does not call a single backspace a cascade", function()
		local batch = Walker.walk({
			key("a", 100), key("[BS]", 100), key("b", 100),
		}, "2026-08-06", "app")
		helpers.assert_eq(batch.errors["2026-08-06\1app"].cascade_count, 0,
			"fixing one character is ordinary typing; if that counted, the cascade "
				.. "figure would just be the backspace count again")
	end)

	helpers.it("closes a cascade that is still open when the stream ends", function()
		local batch = Walker.walk({
			key("a", 100), key("[BS]", 100), key("[BS]", 100), key("[BS]", 100),
		}, "2026-08-06", "app")
		helpers.assert_eq(batch.errors["2026-08-06\1app"].cascade_count, 1,
			"a flush lands between keystrokes, so a correction still in progress at "
				.. "the boundary is the normal case rather than an edge one")
	end)

	helpers.it("measures how quickly the user resumed", function()
		local batch = Walker.walk({
			key("a", 100), key("[BS]", 100), key("b", 250),
		}, "2026-08-06", "app")
		local row = batch.errors["2026-08-06\1app"]
		helpers.assert_eq(row.recovery_count, 1)
		helpers.assert_eq(row.recovery_sum_ms, 250)
	end)

	helpers.it("does not call a coffee break recovery time", function()
		local batch = Walker.walk({
			key("a", 100), key("[BS]", 100), key("b", PAUSE_MS + 60000),
		}, "2026-08-06", "app")
		helpers.assert_eq(batch.errors["2026-08-06\1app"].recovery_count, 0,
			"past the pause threshold the user stopped typing rather than thought "
				.. "about the fix, and folding that in would report a lunch break as "
				.. "the cost of a typo")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 7/ The time of day ======================================
-- =================================================================
-- =================================================================

helpers.describe("aggregate walker: when the typing happened", function()

	--- A clock that puts every keystroke on one chosen wall-clock instant.
	---
	--- The walk adds the offset to a monotonic stamp, so making the stamps 1..N
	--- and the offset absolute lands them all in the same second — which is what
	--- lets the expected hour be computed here rather than guessed.
	--- \1param count number How many events the stream holds.
	--- \1param at number Epoch seconds every keystroke should land on.
	--- \1return table
	local function clock_at(count, at)
		local times = {}
		for index = 1, count do times[index] = index end
		return { times = times, wall_offset_ms = at * 1000 }
	end

	helpers.it("credits each keystroke to its hour and its five-minute slot", function()
		local events = typed("abcd")
		-- Read back through the same os.date the walk uses, so a machine in any
		-- time zone agrees with itself.
		local at = os.time({ year = 2026, month = 8, day = 6, hour = 10, min = 7, sec = 0 })
		local batch = Walker.walk(events, "2026-08-06", "app", nil, clock_at(#events, at))

		local hour = os.date("%H", at)
		local minute = tonumber(os.date("%M", at))
		local slot = string.format("%s:%02d", hour, math.floor(minute / 5) * 5)

		local hourly = batch.hourly["2026-08-06\1app\1" .. hour]
		helpers.assert_not_nil(hourly, "the activity timeline had no rows at all before this")
		helpers.assert_eq(hourly.c, 4)

		local min5 = batch.hourly_min5["2026-08-06\1app\1" .. slot]
		helpers.assert_not_nil(min5, "and neither did its fine-grained version")
		helpers.assert_eq(min5.c, 4)
		helpers.assert_eq(min5.slot, slot,
			"the slot is floored to a five-minute step, so 10:07 belongs to 10:05")
	end)

	helpers.it("records the first and last minute the user typed", function()
		local events = typed("ab")
		local at = os.time({ year = 2026, month = 8, day = 6, hour = 14, min = 32, sec = 0 })
		local batch = Walker.walk(events, "2026-08-06", "app", nil, clock_at(#events, at))
		local row = batch.chars_class["2026-08-06\1app"]
		local expected = os.date("%H:%M", at)
		helpers.assert_eq(row.first_typed_min, expected)
		helpers.assert_eq(row.last_typed_min, expected)
	end)

	helpers.it("skips the time-of-day tables rather than guessing when it has no clock", function()
		local batch = Walker.walk(typed("abc"), "2026-08-06", "app")
		helpers.assert_true(next(batch.hourly) == nil,
			"a keystroke with no timestamp has no hour. Defaulting to the flush time "
				.. "would pile a whole session onto whichever minute the daemon "
				.. "happened to persist in, and the histogram would show bursts the "
				.. "user never typed.")
		helpers.assert_true(next(batch.hourly_min5) == nil)
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 8/ Bursts, sessions and pause buckets ===================
-- =================================================================
-- =================================================================

helpers.describe("aggregate walker: runs of typing", function()

	local BURST_GAP_MS = Timings.ms("keylogger", "burst_gap_ms")
	local SESSION_GAP_MS = Timings.ms("keylogger", "session_gap_ms")

	helpers.it("counts an uninterrupted run as one burst", function()
		local batch = Walker.walk(typed("bonjour tout le monde", 90), "2026-08-06", "app")
		local row = batch.bursts["2026-08-06\1app"]
		helpers.assert_not_nil(row, "the burst panel had no rows at all before this")
		helpers.assert_eq(row.count_total, 1)
		helpers.assert_eq(row.max_chars, 21)
	end)

	helpers.it("starts a new burst after a real gap", function()
		local batch = Walker.walk({
			key("a", 80), key("b", 80),
			key("c", BURST_GAP_MS + 500),
			key("d", 80),
		}, "2026-08-06", "app")
		helpers.assert_eq(batch.bursts["2026-08-06\1app"].count_total, 2,
			"a burst is a run with no real gap in it; merging across one would "
				.. "report a single long fluent stretch the user never had")
	end)

	helpers.it("credits a burst still open when the stream ends", function()
		local batch = Walker.walk(typed("abc", 80), "2026-08-06", "app")
		helpers.assert_eq(batch.bursts["2026-08-06\1app"].count_total, 1,
			"persisting runs every few seconds, so a burst in progress at the "
				.. "boundary is the common case — dropping it would lose nearly every "
				.. "burst the user makes")
	end)

	helpers.it("keeps the squared delays so rhythm is recoverable", function()
		local batch = Walker.walk({ key("a", 0), key("b", 100), key("c", 200) },
			"2026-08-06", "app")
		local row = batch.bursts["2026-08-06\1app"]
		helpers.assert_eq(row.inter_sum, 300)
		helpers.assert_eq(row.inter_sumsq, 100 * 100 + 200 * 200,
			"the sum of squares is how a standard deviation is computed without "
				.. "storing every delay; a 200-character burst would otherwise cost "
				.. "200 rows to say the same thing")
	end)

	helpers.it("records one session for a continuous stretch", function()
		local batch = Walker.walk(typed("bonjour", 90), "2026-08-06", "app")
		local row = batch.sessions["2026-08-06\1app"]
		helpers.assert_not_nil(row, "the session panel was empty too")
		helpers.assert_eq(row.count_total, 1)
		helpers.assert_eq(row.longest_chars, 7)
	end)

	helpers.it("splits sessions at the coarser threshold, not the burst one", function()
		local batch = Walker.walk({
			key("a", 80), key("b", 80),
			key("c", BURST_GAP_MS + 500),
			key("d", 80),
		}, "2026-08-06", "app")
		helpers.assert_eq(batch.sessions["2026-08-06\1app"].count_total, 1,
			"a pause long enough to break a burst is a pause within one session — "
				.. "the two thresholds measure different things, and using one for "
				.. "both would make the session count a duplicate of the burst count")

		local long = Walker.walk({
			key("a", 80),
			key("b", SESSION_GAP_MS + 1000),
		}, "2026-08-06", "app")
		helpers.assert_eq(long.sessions["2026-08-06\1app"].count_total, 2)
	end)

end)




helpers.describe("aggregate walker: the pause buckets", function()

	helpers.it("credits a delay to every threshold at or above it", function()
		local batch = Walker.walk({ key("a", 0), key("b", 1500) }, "2026-08-06", "app")
		local maps = batch.app_buckets["2026-08-06\1app"]
		helpers.assert_not_nil(maps, "the dropdown behind this had nothing to read")
		helpers.assert_eq(maps.time["1000"] or 0, 0,
			"a 1500 ms gap is longer than the 1 s threshold, so that bucket excludes it")
		helpers.assert_eq(maps.time["2000"], 1500,
			"and every threshold above it includes the whole delay: the control asks "
				.. "how much time is left once pauses over N are ignored, which is a "
				.. "total rather than a slice")
		helpers.assert_eq(maps.time["60000"], 1500)
	end)

	helpers.it("counts the keystrokes each bucket credits", function()
		local batch = Walker.walk({ key("a", 0), key("b", 200), key("c", 300) },
			"2026-08-06", "app")
		local maps = batch.app_buckets["2026-08-06\1app"]
		helpers.assert_eq(maps.credited["1000"], 3,
			"the dashboard divides the bucket's time by this to get a mean delay. "
				.. "Dividing by a keystroke count that includes the pauses the bucket "
				.. "excludes gives a number wrong in the flattering direction, and "
				.. "plausible enough to be believed.")
	end)

	helpers.it("unrolls one row per threshold for the writer", function()
		local batch = Walker.walk(typed("ab", 100), "2026-08-06", "app")
		local rows = Walker.daily_rows(batch).app_buckets
		helpers.assert_true(#rows > 1,
			"the schema keys these by (device, date, app, bucket_ms), so a single "
				.. "row per app-day would collapse all eight thresholds onto one")
		for _, row in ipairs(rows) do
			helpers.assert_true(row.bucket_ms > 0,
				"a threshold of zero would upsert every bucket onto the same key")
			helpers.assert_eq(row.app, "app")
		end
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 9/ Same finger, same hand ===============================
-- =================================================================
-- =================================================================

helpers.describe("aggregate walker: the streaks the layout exists to reduce", function()

	local FingerMap = helpers.load_module("keylogger.finger_map")

	--- Whether the shared keycode catalogue could be read at all.
	---
	--- Every case below is meaningless without it, and a suite that quietly
	--- passes when its fixture is missing is the failure mode this repository has
	--- a ratchet for. So it is asserted once, loudly, rather than skipped.
	--- \1return table
	local function require_catalogue()
		local Paths = helpers.load_module("infra.paths")
		local root = Paths.shared_root()
		helpers.assert_not_nil(root, "the shared tree must be findable")
		local handle = io.open(root .. "/data/keycodes/azerty.json", "r")
		helpers.assert_not_nil(handle, "the shared keycode catalogue must exist")
		local body = handle:read("*a")
		handle:close()
		local Json = helpers.load_module("json")
		FingerMap._reset()
		local lookup = FingerMap.load("qwerty", function() return body end, Json.decode, "x")
		helpers.assert_not_nil(lookup, "the catalogue must decode into a finger lookup")
		return lookup
	end

	--- Two characters the catalogue says share a finger, and two that do not.
	--- Derived from the catalogue rather than named, so a change to the layout
	--- data cannot leave this test asserting something the product denies.
	--- \1param lookup table
	--- \1return string a, string b, string other
	local function pick_pair(lookup)
		local by_finger = {}
		for char, entry in pairs(lookup) do
			if char:match("^%l$") then
				by_finger[entry.finger] = by_finger[entry.finger] or {}
				local list = by_finger[entry.finger]
				list[#list + 1] = char
			end
		end
		for finger, chars in pairs(by_finger) do
			if #chars >= 2 then
				table.sort(chars)
				for other_char, entry in pairs(lookup) do
					if other_char:match("^%l$") and entry.finger ~= finger then
						return chars[1], chars[2], other_char
					end
				end
			end
		end
		return nil, nil, nil
	end

	helpers.it("counts two characters typed by one finger as a run", function()
		local lookup = require_catalogue()
		local first, second, other = pick_pair(lookup)
		helpers.assert_not_nil(first,
			"the catalogue must describe at least one finger with two keys, or "
				.. "there is nothing here to measure")

		local batch = Walker.walk(typed(first .. second, 90), "2026-08-06", "app")
		local row = batch.ergo["2026-08-06\1app"]
		helpers.assert_not_nil(row, "the ergonomics panel had no rows at all before this")
		helpers.assert_true(row.same_finger_streak_max >= 2,
			"'how often does one finger have to move twice in a row' is the whole "
				.. "argument for an alternative layout, and this driver could not "
				.. "answer it — the panel the layout exists to justify was empty")
		helpers.assert_true(other ~= nil)
	end)

	helpers.it("does not call two different fingers a run", function()
		local lookup = require_catalogue()
		local first, _, other = pick_pair(lookup)
		local batch = Walker.walk(typed(first .. other, 90), "2026-08-06", "app")
		helpers.assert_eq(batch.ergo["2026-08-06\1app"].same_finger_streak_max, 1,
			"a maximum of one means no run happened; seeding the counter at two "
				.. "would report every isolated keystroke as a same-finger event")
	end)

	helpers.it("breaks the run on a correction", function()
		local lookup = require_catalogue()
		local first, second = pick_pair(lookup)
		local batch = Walker.walk({
			key(first, 90), key("[BS]", 90), key(second, 90),
		}, "2026-08-06", "app")
		helpers.assert_eq(batch.ergo["2026-08-06\1app"].same_finger_streak_max, 1,
			"what follows a backspace continues from a different character than it "
				.. "appears to, so those two keystrokes were never consecutive under "
				.. "one finger")
	end)

	helpers.it("does not let an expansion extend a run", function()
		local lookup = require_catalogue()
		local first, second = pick_pair(lookup)
		local batch = Walker.walk({
			key(first, 90), key(second, 0, "hotstring"),
		}, "2026-08-06", "app")
		helpers.assert_eq(batch.ergo["2026-08-06\1app"].same_finger_streak_max, 1,
			"counting the driver's own output would make the layout look worse the "
				.. "more it types for the user, which is backwards")
	end)

	helpers.it("breaks the run on a character the catalogue does not describe", function()
		local batch = Walker.walk(typed("\194\1691\194\1692", 90), "2026-08-06", "app")
		local row = batch.ergo["2026-08-06\1app"]
		helpers.assert_true(row.same_finger_streak_max <= 1,
			"guessing a finger for a character the layout data does not cover would "
				.. "inflate the one number the whole argument rests on")
	end)

	helpers.it("hands the row to the writer", function()
		local batch = Walker.walk(typed("abc", 90), "2026-08-06", "app")
		local rows = Walker.daily_rows(batch).ergo
		helpers.assert_eq(#rows, 1,
			"a table computed and never emitted is the same blank panel as one "
				.. "never computed — this driver has shipped that three times")
		helpers.assert_eq(rows[1].app, "app")
	end)

end)

