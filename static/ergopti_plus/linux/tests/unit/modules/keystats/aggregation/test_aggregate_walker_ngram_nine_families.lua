--- tests/unit/modules/keystats/aggregation/test_aggregate_walker_ngram_nine_families.lua

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
--- analysis that no hand ever typed. A backspace is a token of the run, as on
--- Windows and macOS: "a[BS]b" is a sequence the hands made, "ab" is not. And
--- synthetic output
--- never chains: a hotstring's expansion is text the user did not type, and
--- folding it into the bigram counts would make the layout look better the more
--- expansions they use, which is backwards for a tool that measures effort.
---
--- Each of those is a way to be quietly wrong rather than visibly broken, which
--- is why they are the cases below rather than "it produces some bigrams".
--- ==============================================================================

package.loaded["tests.support.modules.keystats.aggregation.aggregate_walker_fixture"] = nil
local Fixture = require("tests.support.modules.keystats.aggregation.aggregate_walker_fixture")
local helpers, it, Fakes, Walker, Timings, PAUSE_MS, SESSION_GAP_MS, key, typed, count_of =
	Fixture.helpers, Fixture.it, Fixture.Fakes, Fixture.Walker, Fixture.Timings, Fixture.PAUSE_MS, Fixture.SESSION_GAP_MS, Fixture.key, Fixture.typed, Fixture.count_of




-- =================================================================
-- =================================================================
-- ======= 1/ Every family gets written ============================
-- =================================================================
-- =================================================================

helpers.describe("ngram walker: the nine families", function()

	it("produces tokens of every length from one to seven", function()
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

	it("records words and word pairs", function()
		local batch = Walker.walk(typed("le chat noir "), "2026-08-06", "app")
		helpers.assert_eq(count_of(batch, "ngram_words", "chat"), 1)
		helpers.assert_eq(count_of(batch, "ngram_word_bigrams", "le chat"), 1,
			"the word lists and the pair lists are two different panels, and both "
				.. "were empty")
	end)

	it("keeps the last word even though the stream ends mid-sentence", function()
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
	it("keeps long-gap characters but excludes their delay from n-gram timing", function()
		local batch = Walker.walk({
			key("a", 200),
			key("b", PAUSE_MS + 4000),
			key("c", 200),
			key("d", SESSION_GAP_MS + 1000),
			key("e", 200),
		}, "2026-08-06", "app")
		local rows = batch.ngram.ngram_chars
		local total_delay, delay_count = 0, 0
		for _, item in pairs(rows) do
			total_delay = total_delay + item.td
			delay_count = delay_count + item.cd
		end

		helpers.assert_eq(total_delay, 600,
			"only the three short gaps belong to character n-gram timing")
		helpers.assert_eq(delay_count, 3,
			"long gaps do not create character n-gram delay samples")
		for _, token in ipairs({ "b", "d" }) do
			local item = rows["2026-08-06\1app\1" .. token]
			helpers.assert_not_nil(item, "the long-gap character itself remains counted")
			helpers.assert_eq(item.td, 0, "long-gap timing is excluded for " .. token)
			helpers.assert_eq(item.cd, 0, "long-gap delay samples are excluded for " .. token)
		end
	end)

	it("does not join two characters across a long pause", function()
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

	it("chains through a correction, never across it", function()
		local batch = Walker.walk({
			key("a", 100), key("b", 100),
			key("[BS]", 100),
			key("c", 100),
		}, "2026-08-06", "app")

		helpers.assert_eq(count_of(batch, "ngram_bigrams", "bc"), 0,
			"after a backspace the next character continues from a different one "
				.. "than it appears to; 'bc' is a pair the user never produced")
		helpers.assert_eq(count_of(batch, "ngram_bigrams", "[BS]c"), 1,
			"the correction itself is what the next character follows, as on Windows and macOS")
	end)

	it("chains a hotstring's output and keeps its source", function()
		local batch = Walker.walk({
			key("b", 100), key("t", 100), key("w", 100),
			key("b", 0, "hotstring"), key("y", 0, "hotstring"),
		}, "2026-08-06", "app")

		-- Windows and macOS chain generated text like typed text; the rows carry
		-- the source, so a view of typing effort alone filters on it.
		local bigram = batch.ngram.ngram_bigrams["2026-08-06\1app\1by"]
		helpers.assert_not_nil(bigram, "the expansion chains as it does on Windows")
		helpers.assert_true((bigram.esrc.hotstring or 0) > 0, "and keeps its source")
		helpers.assert_not_nil(batch.ngram.ngram_bigrams["2026-08-06\1app\1wb"],
			"it also chains with the typed text before it")

		local rows = batch.ngram.ngram_chars["2026-08-06\1app\1b"]
		helpers.assert_not_nil(rows, "the character itself is still counted")
		helpers.assert_true((rows.esrc.hotstring or 0) > 0,
			"and tagged with where it came from, so the day's total stays honest "
				.. "about how much of it the driver produced")
	end)

	it("does not carry a word across a correction", function()
		local batch = Walker.walk({
			key("c", 100), key("h", 100), key("a", 100),
			key("[BS]", 100),
			key("t", 100), key(" ", 100),
		}, "2026-08-06", "app")
		helpers.assert_eq(count_of(batch, "ngram_words", "chat"), 0,
			"the user typed 'cha', deleted, then 't' — 'chat' is a word the walk "
				.. "would have invented")
		-- Backspace pops the last character of the open word (Windows and macOS)
		-- and flags it, instead of dropping what was typed so far.
		local word = batch.ngram.ngram_words["2026-08-06\1app\1cht"]
		helpers.assert_not_nil(word, "the word continues from what survived the Backspace")
		helpers.assert_eq(word.c, 0)
		helpers.assert_eq(word.e, 1)
	end)

	it("flags the n-grams of the character a Backspace erases", function()
		local batch = Walker.walk({
			key("a", 100), key("b", 100), key("c", 100), key("[BS]", 100),
		}, "2026-08-06", "app")
		local prefix = "2026-08-06\1app\1"
		for family, token in pairs({ ngram_chars = "c", ngram_bigrams = "bc", ngram_trigrams = "abc" }) do
			local row = batch.ngram[family][prefix .. token]
			helpers.assert_eq(row.c, 1, family .. " " .. token .. " was typed")
			helpers.assert_eq(row.e, 1, family .. " " .. token .. " was erased")
		end
		helpers.assert_eq(batch.ngram.ngram_chars[prefix .. "b"].e, 0, "what survived is not flagged")
	end)

	it("erases nothing typed before a long pause", function()
		local batch = Walker.walk({ key("a", 100), key("b", 100), key("[BS]", PAUSE_MS) }, "2026-08-06", "app")
		helpers.assert_eq(batch.ngram.ngram_chars["2026-08-06\1app\1b"].e, 0)
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 3/ Handing the batch to the writer ======================
-- =================================================================
-- =================================================================

helpers.describe("ngram walker: what the writer receives", function()

	it("splits the batch by table and by application-day", function()
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

	it("emits nothing for a family with no rows", function()
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

	it("hands more than one table to the writer", function()
		-- The walk and the writer were both correct in isolation before this test,
		-- and the flush called neither. A unit that works and is never invoked is
		-- the shape three separate defects in this driver have taken, so the join
		-- gets its own case.
		local calls = {}
		local writer_name = "modules.keystats.sqlite_writer"
		local logger_name = "modules.keystats.keystats"
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
			require("tests.support.metrics_consent_fixture").enable(kl)
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




helpers.describe("ngram walker: each character is stored once", function()

	it("counts a typed character once in ngram_chars", function()
		-- The walker writes every character, and step 3 of the flush wrote the
		-- per-app delta of the same characters again: both upserts add, so every
		-- persisted character count was doubled.
		local chars_o = 0
		local writer_name = "modules.keystats.sqlite_writer"
		local logger_name = "modules.keystats.keystats"
		local prev_writer, prev_logger = package.loaded[writer_name], package.loaded[logger_name]
		local writer = Fakes.sqlite_writer()
		writer.upsert_ngrams = function(_device, _date, _app, ngrams, table_name)
			if (table_name or "ngram_chars") == "ngram_chars" then
				local entry = ngrams.o
				chars_o = chars_o + (type(entry) == "table" and (entry.c or 0) or (entry or 0))
			end
			return true
		end
		package.loaded[writer_name] = writer
		package.loaded[logger_name] = nil
		local ok, err = pcall(function()
			local kl = require(logger_name)
			kl.init({ sqlite_path = "/tmp/ergopti_ngram_once.sqlite" })
			require("tests.support.metrics_consent_fixture").enable(kl)
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
		helpers.assert_true(ok, tostring(err))
		helpers.assert_eq(chars_o, 2, "\"bonjour\" holds two o")
	end)

end)




helpers.describe("keystats: the JSON fallback does not hoard raw events", function()

	it("empties the raw buffers when it flushes without SQLite", function()
		local writer_name = "modules.keystats.sqlite_writer"
		local logger_name = "modules.keystats.keystats"
		local prev_writer, prev_logger = package.loaded[writer_name], package.loaded[logger_name]
		package.loaded[writer_name] = Fakes.sqlite_writer({ available = false })
		package.loaded[logger_name] = nil
		local dir = os.tmpname()
		os.remove(dir)
		local before, after
		local ok, err = pcall(function()
			local kl = require(logger_name)
			kl.init({ sqlite_path = "/tmp/ergopti_fallback.sqlite", log_dir = dir })
			require("tests.support.metrics_consent_fixture").enable(kl)
			kl.reset_session()
			kl.on_app_focus("app.test", 1000)
			for index, char in ipairs({ "s", "a", "l", "u", "t" }) do kl.on_keydown(char, 1000 + index * 100, "app.test") end
			before = kl._pending_buffer_count_for_test()
			kl.flush()
			after = kl._pending_buffer_count_for_test()
		end)
		package.loaded[writer_name] = prev_writer
		package.loaded[logger_name] = prev_logger
		os.execute("rm -rf '" .. dir .. "'")
		helpers.assert_true(ok, tostring(err))
		helpers.assert_true(before > 0, "keys were buffered")
		helpers.assert_eq(after, 0, "only the SQLite branch emptied them; they grew all session")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 5/ The character composition ============================
-- =================================================================
-- =================================================================

helpers.describe("aggregate walker: what the day was made of", function()

	it("sorts characters into the five classes", function()
		local batch = Walker.walk(typed("ab 12 ,."), "2026-08-06", "app")
		local row = batch.chars_class["2026-08-06\1app"]
		helpers.assert_not_nil(row, "the breakdown row must exist")
		helpers.assert_eq(row.letter, 2)
		helpers.assert_eq(row.digit, 2)
		helpers.assert_eq(row.space, 2)
		helpers.assert_eq(row.punct, 2)
	end)

	it("counts an accented letter as a letter", function()
		local batch = Walker.walk(typed("éàü"), "2026-08-06", "app")
		local row = batch.chars_class["2026-08-06\1app"]
		helpers.assert_eq(row.letter, 3,
			"these arrive as multi-byte sequences that the ASCII class pattern does "
				.. "not match. Filing them under 'other' would make the breakdown "
				.. "meaningless for a French corpus, which is most of this one.")
		helpers.assert_eq(row.other, 0)
	end)

	it("does not count an expansion as something the user typed", function()
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

	it("counts manual backspaces", function()
		local batch = Walker.walk({
			key("a", 100), key("[BS]", 100), key("[BS]", 100), key("b", 100),
		}, "2026-08-06", "app")
		helpers.assert_eq(batch.errors["2026-08-06\1app"].bs_total, 2)
	end)

	it("does not count the deletions a hotstring makes to erase its trigger", function()
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

	it("counts a run of three or more as one cascade", function()
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

	it("does not call a single backspace a cascade", function()
		local batch = Walker.walk({
			key("a", 100), key("[BS]", 100), key("b", 100),
		}, "2026-08-06", "app")
		helpers.assert_eq(batch.errors["2026-08-06\1app"].cascade_count, 0,
			"fixing one character is ordinary typing; if that counted, the cascade "
				.. "figure would just be the backspace count again")
	end)

	it("closes a cascade that is still open when the stream ends", function()
		local batch = Walker.walk({
			key("a", 100), key("[BS]", 100), key("[BS]", 100), key("[BS]", 100),
		}, "2026-08-06", "app")
		helpers.assert_eq(batch.errors["2026-08-06\1app"].cascade_count, 1,
			"a flush lands between keystrokes, so a correction still in progress at "
				.. "the boundary is the normal case rather than an edge one")
	end)

	it("measures how quickly the user resumed", function()
		local batch = Walker.walk({
			key("a", 100), key("[BS]", 100), key("b", 250),
		}, "2026-08-06", "app")
		local row = batch.errors["2026-08-06\1app"]
		helpers.assert_eq(row.recovery_count, 1)
		helpers.assert_eq(row.recovery_sum_ms, 250)
	end)

	it("does not call a coffee break recovery time", function()
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

	it("credits each keystroke to its hour and its five-minute slot", function()
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

	it("records the first and last five-minute slot the user typed in", function()
		local events = typed("ab")
		local at = os.time({ year = 2026, month = 8, day = 6, hour = 14, min = 32, sec = 0 })
		local batch = Walker.walk(events, "2026-08-06", "app", nil, clock_at(#events, at))
		local row = batch.chars_class["2026-08-06\1app"]
		-- The slot the activity histogram bins the keystroke in, as on Windows and
		-- macOS (corpus vector typed_minutes_use_five_minute_slots): 14:32 is 14:30.
		local minute = tonumber(os.date("%M", at))
		local expected = string.format("%s:%02d", os.date("%H", at), math.floor(minute / 5) * 5)
		helpers.assert_eq(row.first_typed_min, expected)
		helpers.assert_eq(row.last_typed_min, expected)
	end)

	it("skips the time-of-day tables rather than guessing when it has no clock", function()
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

	local BURST_GAP_MS = Timings.ms("keystats", "burst_gap_ms")
	local SESSION_GAP_MS = Timings.ms("keystats", "session_gap_ms")

	it("counts an uninterrupted run as one burst", function()
		local batch = Walker.walk(typed("bonjour tout le monde", 90), "2026-08-06", "app")
		local row = batch.bursts["2026-08-06\1app"]
		helpers.assert_not_nil(row, "the burst panel had no rows at all before this")
		helpers.assert_eq(row.count_total, 1)
		helpers.assert_eq(row.max_chars, 21)
	end)

	it("starts a new burst after a real gap", function()
		local batch = Walker.walk({
			key("a", 80), key("b", 80),
			key("c", BURST_GAP_MS + 500),
			key("d", 80),
		}, "2026-08-06", "app")
		helpers.assert_eq(batch.bursts["2026-08-06\1app"].count_total, 2,
			"a burst is a run with no real gap in it; merging across one would "
				.. "report a single long fluent stretch the user never had")
	end)

	it("credits a burst still open when the stream ends", function()
		local batch = Walker.walk(typed("abc", 80), "2026-08-06", "app")
		helpers.assert_eq(batch.bursts["2026-08-06\1app"].count_total, 1,
			"persisting runs every few seconds, so a burst in progress at the "
				.. "boundary is the common case — dropping it would lose nearly every "
				.. "burst the user makes")
	end)

	it("keeps the squared delays so rhythm is recoverable", function()
		local batch = Walker.walk({ key("a", 0), key("b", 100), key("c", 200) },
			"2026-08-06", "app")
		local row = batch.bursts["2026-08-06\1app"]
		helpers.assert_eq(row.inter_sum, 300)
		helpers.assert_eq(row.inter_sumsq, 100 * 100 + 200 * 200,
			"the sum of squares is how a standard deviation is computed without "
				.. "storing every delay; a 200-character burst would otherwise cost "
				.. "200 rows to say the same thing")
	end)

	it("records one session for a continuous stretch", function()
		local batch = Walker.walk(typed("bonjour", 90), "2026-08-06", "app")
		local row = batch.sessions["2026-08-06\1app"]
		helpers.assert_not_nil(row, "the session panel was empty too")
		helpers.assert_eq(row.count_total, 1)
		helpers.assert_eq(row.longest_chars, 7)
	end)

	it("splits sessions at the coarser threshold, not the burst one", function()
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

	-- The shared walk keeps one row per threshold, the schema's own key, as the
	-- Windows and macOS walkers do.
	local function bucket(batch, threshold)
		return batch.app_buckets["2026-08-06\1app\1" .. threshold]
	end

	it("credits a delay to every threshold at or above it", function()
		local batch = Walker.walk({ key("a", 0), key("b", 1500) }, "2026-08-06", "app")
		helpers.assert_not_nil(bucket(batch, 2000), "the dropdown behind this had nothing to read")
		helpers.assert_eq(bucket(batch, 1000).time_sum, 0,
			"a 1500 ms gap is longer than the 1 s threshold, so that bucket excludes it")
		helpers.assert_eq(bucket(batch, 2000).time_sum, 1500,
			"and every threshold above it includes the whole delay: the control asks "
				.. "how much time is left once pauses over N are ignored, which is a "
				.. "total rather than a slice")
		helpers.assert_eq(bucket(batch, 60000).time_sum, 1500)
	end)

	it("counts the keystrokes each bucket credits", function()
		local batch = Walker.walk({ key("a", 0), key("b", 200), key("c", 300) },
			"2026-08-06", "app")
		helpers.assert_eq(bucket(batch, 1000).credited, 3,
			"the dashboard divides the bucket's time by this to get a mean delay. "
				.. "Dividing by a keystroke count that includes the pauses the bucket "
				.. "excludes gives a number wrong in the flattering direction, and "
				.. "plausible enough to be believed.")
	end)

	it("unrolls one row per threshold for the writer", function()
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

