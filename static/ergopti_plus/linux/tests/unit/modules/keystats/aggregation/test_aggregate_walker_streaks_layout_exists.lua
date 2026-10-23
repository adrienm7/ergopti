--- tests/unit/modules/keystats/aggregation/test_aggregate_walker_streaks_layout_exists.lua

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
local helpers, it, Walker, key, typed, count_of =
	Fixture.helpers, Fixture.it, Fixture.Walker, Fixture.key, Fixture.typed, Fixture.count_of




-- =================================================================
-- =================================================================
-- ======= 9/ Same finger, same hand ===============================
-- =================================================================
-- =================================================================

helpers.describe("aggregate walker: the streaks the layout exists to reduce", function()

	local FingerMap = helpers.load_module("keystats.finger_map")

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
		local Json = require("json")
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

	it("counts two characters typed by one finger as a run", function()
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

	it("does not call two different fingers a run", function()
		local lookup = require_catalogue()
		local first, _, other = pick_pair(lookup)
		local batch = Walker.walk(typed(first .. other, 90), "2026-08-06", "app")
		helpers.assert_eq(batch.ergo["2026-08-06\1app"].same_finger_streak_max, 1,
			"a maximum of one means no run happened; seeding the counter at two "
				.. "would report every isolated keystroke as a same-finger event")
	end)

	it("breaks the run on a correction", function()
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

	it("does not let an expansion extend a run", function()
		local lookup = require_catalogue()
		local first, second = pick_pair(lookup)
		local batch = Walker.walk({
			key(first, 90), key(second, 0, "hotstring"),
		}, "2026-08-06", "app")
		helpers.assert_eq(batch.ergo["2026-08-06\1app"].same_finger_streak_max, 1,
			"counting the driver's own output would make the layout look worse the "
				.. "more it types for the user, which is backwards")
	end)

	it("breaks the run on a character the catalogue does not describe", function()
		local batch = Walker.walk(typed("\194\1691\194\1692", 90), "2026-08-06", "app")
		local row = batch.ergo["2026-08-06\1app"]
		helpers.assert_true(row.same_finger_streak_max <= 1,
			"guessing a finger for a character the layout data does not cover would "
				.. "inflate the one number the whole argument rests on")
	end)

	it("hands the row to the writer", function()
		local batch = Walker.walk(typed("abc", 90), "2026-08-06", "app")
		local rows = Walker.daily_rows(batch).ergo
		helpers.assert_eq(#rows, 1,
			"a table computed and never emitted is the same blank panel as one "
				.. "never computed — this driver has shipped that three times")
		helpers.assert_eq(rows[1].app, "app")
	end)

end)




helpers.describe("linux-hourly-manual-errors", function()
	local function walk(events, times)
		return Walker.daily_rows(Walker.walk(events, "2000-01-01", "owned", nil,
			{ times = times, wall_offset_ms = 0 }))
	end
	it("linux-hourly-manual-errors: manual correction bins are cumulative without changing typed counts", function()
		local at = os.time({ year = 2000, month = 1, day = 1, hour = 10, min = 0, sec = 0 }) * 1000
		local rows = walk({ key("a"), key("[BS]", 1000), key("b", 100), key("[BS]", 1500) },
			{ at, at + 1000, at + 1100, at + 2600 })
		local hour, slot = rows.hourly[1], rows.hourly_min5[1]
		helpers.assert_eq(hour.c, 2)
		helpers.assert_eq(hour.e, 2)
		helpers.assert_eq(hour.em, 2)
		helpers.assert_eq(hour.es, 0)
		helpers.assert_eq(hour.e_buckets["1000"], 1)
		helpers.assert_eq(hour.e_buckets["2000"], 2)
		helpers.assert_eq(slot.e, 2)
		helpers.assert_eq(slot.c, 2)
		helpers.assert_eq(slot.e_buckets["1000"], 1)
		helpers.assert_eq(rows.errors[1].bs_total, 2)
	end)
	it("linux-hourly-manual-errors: synthetic erasure preserves the existing manual-error exclusion", function()
		local at = os.time({ year = 2000, month = 1, day = 1, hour = 10, min = 0, sec = 0 }) * 1000
		local rows = walk({ key("a"), key("[BS]", 100, "hotstring"), key("b", 100) }, { at, at + 100, at + 200 })
		helpers.assert_eq(rows.errors[1].bs_total, 0)
		helpers.assert_eq(rows.hourly[1].c, 2)
		helpers.assert_eq(rows.hourly[1].e, 0)
		helpers.assert_eq(rows.hourly[1].em, 0)
		helpers.assert_nil(next(rows.hourly[1].e_buckets))
	end)
	it("linux-hourly-manual-errors: correction-only hours do not change first or last typed minute", function()
		local at = os.time({ year = 2000, month = 1, day = 1, hour = 10, min = 0, sec = 0 }) * 1000
		local rows = walk({ key("[BS]", 100), key("a"), key("[BS]", 100) }, { at - 3600000, at, at + 3600000 })
		helpers.assert_eq(rows.chars_class[1].first_typed_min, "10:00")
		helpers.assert_eq(rows.chars_class[1].last_typed_min, "10:00")
		local errors, chars = 0, 0
		for _, row in ipairs(rows.hourly) do errors, chars = errors + row.e, chars + row.c end
		helpers.assert_eq(errors, 2)
		helpers.assert_eq(chars, 1)
	end)
	it("linux-hourly-manual-errors: absent clock metadata retains daily correction totals without inventing bins", function()
		local rows = walk({ key("a"), key("[BS]", 100) }, nil)
		helpers.assert_eq(rows.errors[1].bs_total, 1)
		helpers.assert_eq(#rows.hourly, 0)
		helpers.assert_eq(#rows.hourly_min5, 0)
	end)
end)




-- ============================================================================
-- Canonical backspace unigrams
-- ============================================================================

helpers.describe("aggregate walker: backspace unigram retention", function()
	it("linux-backspace-unigrams: manual correction keeps its count and native delay", function()
		local batch = Walker.walk({ key("a", 100), key("[BS]", 110), key("b", 120) },
			"2026-08-06", "app")
		local item = batch.ngram.ngram_chars["2026-08-06\1app\1[BS]"]
		helpers.assert_true(item ~= nil, "the supported Backspace row survives persistence")
		helpers.assert_eq(item.c, 1)
		helpers.assert_eq(item.td, 110)
		helpers.assert_eq(item.cd, 1)
		helpers.assert_eq(item.e, 0)
		helpers.assert_nil(next(item.esrc))
		helpers.assert_eq(batch.errors["2026-08-06\1app"].bs_total, 1)
		helpers.assert_eq(batch.chars_class["2026-08-06\1app"].letter, 2)
		helpers.assert_eq(count_of(batch, "ngram_bigrams", "ab"), 0)
		helpers.assert_eq(count_of(batch, "ngram_words", "a"), 0)
		-- The Backspace popped "a" and flagged the word: an erased word, not a typed one.
		local word = batch.ngram.ngram_words["2026-08-06\1app\1b"]
		helpers.assert_eq(word.c, 0)
		helpers.assert_eq(word.e, 1)
	end)
	it("linux-backspace-unigrams: synthetic deletions keep HS and LLM source counts", function()
		local batch = Walker.walk({ key("a", 100), key("[BS]", 0, "hotstring"),
			key("[BS]", 0, "hotstring"), key("[BS]", 0, "llm"), key("b", 100) },
			"2026-08-06", "app")
		local item = batch.ngram.ngram_chars["2026-08-06\1app\1[BS]"]
		helpers.assert_true(item ~= nil)
		helpers.assert_eq(item.c, 3)
		helpers.assert_eq(item.td, 0)
		helpers.assert_eq(item.cd, 0)
		helpers.assert_eq(item.e, 0)
		helpers.assert_eq(item.esrc.hotstring, 2)
		helpers.assert_eq(item.esrc.llm, 1)
		helpers.assert_eq(batch.errors["2026-08-06\1app"].bs_total, 0)
		helpers.assert_eq(batch.errors["2026-08-06\1app"].cascade_count, 0)
		helpers.assert_eq(batch.chars_class["2026-08-06\1app"].letter, 2)
		helpers.assert_eq(count_of(batch, "ngram_bigrams", "ab"), 0)
	end)
	it("linux-backspace-unigrams: cascade and recovery contexts stay independent", function()
		local batch = Walker.walk({ key("a", 100), key("[BS]", 100), key("[BS]", 100),
			key("[BS]", 100), key("b", 140) }, "2026-08-06", "app")
		local item = batch.ngram.ngram_chars["2026-08-06\1app\1[BS]"]
		helpers.assert_true(item ~= nil)
		helpers.assert_eq(item.c, 3)
		helpers.assert_eq(item.td, 300)
		helpers.assert_eq(item.cd, 3)
		local errors = batch.errors["2026-08-06\1app"]
		helpers.assert_eq(errors.bs_total, 3)
		helpers.assert_eq(errors.cascade_count, 1)
		helpers.assert_eq(errors.cascade_max_len, 3)
		helpers.assert_eq(errors.recovery_sum_ms, 140)
		helpers.assert_eq(errors.recovery_count, 1)
		-- The sequences ending in a correction and the ones that follow it are
		-- counted, as on Windows and macOS (linux-backspace-sequences).
		helpers.assert_eq(count_of(batch, "ngram_bigrams", "a[BS]"), 1)
		helpers.assert_eq(count_of(batch, "ngram_bigrams", "[BS]b"), 1)
		helpers.assert_eq(count_of(batch, "ngram_trigrams", "[BS][BS]b"), 1)
		helpers.assert_eq(count_of(batch, "ngram_trigrams", "a[BS]b"), 0, "three corrections stand between a and b")
	end)
	it("linux-backspace-unigrams: literal software spelling stays four codepoints", function()
		local batch = Walker.walk({ key("[", 0, "other"), key("B", 0, "other"),
			key("S", 0, "other"), key("]", 0, "other") }, "2026-08-06", "app")
		helpers.assert_eq(count_of(batch, "ngram_chars", "[BS]"), 0)
		for _, char in ipairs({ "[", "B", "S", "]" }) do
			local item = batch.ngram.ngram_chars["2026-08-06\1app\1" .. char]
			helpers.assert_eq(item.c, 1)
			helpers.assert_eq(item.esrc.other, 1)
		end
		helpers.assert_eq(batch.errors["2026-08-06\1app"].bs_total, 0)
	end)
end)




-- ============================================================================
-- Backspace bigrams and trigrams: the sequences that end in a correction
-- ============================================================================

-- Windows and macOS push "x[BS]" and "yx[BS]" for every Backspace, so the
-- dashboard can show which sequences the user goes back over, and the marker
-- stays in the chain, so "[BS]x" and "y[BS]x" count what the user typed next.
-- This walker first counted the unigram only, then broke the chain after it.
helpers.describe("aggregate walker: backspace sequences", function()
	local PAUSE_MS = Fixture.PAUSE_MS
	local function item(batch, family, token)
		return batch.ngram[family]["2026-08-06\1app\1" .. token]
	end
	it("linux-backspace-sequences: a manual correction ends a bigram and a trigram", function()
		local batch = Walker.walk({ key("t", 100), key("h", 100), key("e", 100), key("[BS]", 110) },
			"2026-08-06", "app")
		local bigram, trigram = item(batch, "ngram_bigrams", "e[BS]"), item(batch, "ngram_trigrams", "he[BS]")
		helpers.assert_true(bigram ~= nil and trigram ~= nil, "both sequences are counted")
		helpers.assert_eq(bigram.c, 1)
		helpers.assert_eq(bigram.td, 110, "the correction's own delay times the sequence")
		helpers.assert_eq(bigram.cd, 1)
		helpers.assert_eq(bigram.e, 0)
		helpers.assert_nil(next(bigram.esrc), "a manual correction has no synthetic source")
		helpers.assert_eq(trigram.c, 1)
		helpers.assert_eq(trigram.td, 110)
		helpers.assert_eq(count_of(batch, "ngram_quadgrams", "the[BS]"), 0,
			"Windows and macOS stop at trigrams for a correction")
	end)
	it("linux-backspace-sequences: consecutive corrections chain with each other", function()
		local batch = Walker.walk({ key("a", 100), key("b", 100), key("[BS]", 90), key("[BS]", 80),
			key("[BS]", 70) }, "2026-08-06", "app")
		helpers.assert_eq(count_of(batch, "ngram_bigrams", "b[BS]"), 1)
		helpers.assert_eq(count_of(batch, "ngram_bigrams", "[BS][BS]"), 2)
		helpers.assert_eq(item(batch, "ngram_bigrams", "[BS][BS]").td, 150)
		helpers.assert_eq(count_of(batch, "ngram_trigrams", "ab[BS]"), 1)
		helpers.assert_eq(count_of(batch, "ngram_trigrams", "b[BS][BS]"), 1)
		helpers.assert_eq(count_of(batch, "ngram_trigrams", "[BS][BS][BS]"), 1)
		helpers.assert_eq(batch.errors["2026-08-06\1app"].bs_total, 3, "the error counts are unchanged")
	end)
	it("linux-backspace-sequences: the characters after a correction chain with it", function()
		local batch = Walker.walk({ key("a", 100), key("[BS]", 100), key("b", 100), key("c", 100),
			key("[BS]", 100) }, "2026-08-06", "app")
		helpers.assert_eq(count_of(batch, "ngram_bigrams", "[BS]b"), 1)
		helpers.assert_eq(item(batch, "ngram_bigrams", "[BS]b").td, 100, "the next keystroke times the pair")
		helpers.assert_eq(count_of(batch, "ngram_bigrams", "bc"), 1)
		helpers.assert_eq(count_of(batch, "ngram_bigrams", "c[BS]"), 1)
		helpers.assert_eq(count_of(batch, "ngram_trigrams", "a[BS]b"), 1)
		helpers.assert_eq(count_of(batch, "ngram_trigrams", "[BS]bc"), 1)
		helpers.assert_eq(count_of(batch, "ngram_trigrams", "bc[BS]"), 1)
		helpers.assert_eq(count_of(batch, "ngram_quadgrams", "a[BS]bc"), 1)
		helpers.assert_eq(count_of(batch, "ngram_quadgrams", "[BS]bc[BS]"), 0,
			"a correction still ends no sequence longer than a trigram")
	end)
	it("linux-backspace-sequences: a pause after the correction breaks the sequence", function()
		local batch = Walker.walk({ key("a", 100), key("[BS]", 100), key("b", PAUSE_MS) },
			"2026-08-06", "app")
		helpers.assert_eq(count_of(batch, "ngram_bigrams", "a[BS]"), 1)
		helpers.assert_eq(count_of(batch, "ngram_bigrams", "[BS]b"), 0)
	end)
	it("linux-backspace-sequences: a pause before the correction breaks the sequence", function()
		local batch = Walker.walk({ key("a", 100), key("b", 100), key("[BS]", PAUSE_MS) },
			"2026-08-06", "app")
		helpers.assert_eq(count_of(batch, "ngram_chars", "[BS]"), 1, "the correction itself still counts")
		helpers.assert_eq(count_of(batch, "ngram_bigrams", "b[BS]"), 0)
		helpers.assert_eq(count_of(batch, "ngram_trigrams", "ab[BS]"), 0)
	end)
	it("linux-backspace-sequences: a pause before the character breaks the sequence", function()
		local batch = Walker.walk({ key("a", 100), key("b", PAUSE_MS), key("[BS]", 100) },
			"2026-08-06", "app")
		helpers.assert_eq(count_of(batch, "ngram_bigrams", "b[BS]"), 1)
		helpers.assert_eq(count_of(batch, "ngram_trigrams", "ab[BS]"), 0,
			"two characters either side of a pause are not one sequence")
	end)
	it("linux-backspace-sequences: synthetic deletions keep their source and chain through the output", function()
		local batch = Walker.walk({ key("b", 100), key("t", 100), key("w", 100),
			key("[BS]", 0, "hotstring"), key("[BS]", 0, "hotstring"),
			key("x", 0, "hotstring"), key("[BS]", 0, "llm") }, "2026-08-06", "app")
		local erase = item(batch, "ngram_bigrams", "w[BS]")
		helpers.assert_true(erase ~= nil, "the trigger the expansion erased is counted")
		helpers.assert_eq(erase.esrc.hotstring, 1)
		helpers.assert_eq(item(batch, "ngram_trigrams", "tw[BS]").esrc.hotstring, 1)
		helpers.assert_eq(item(batch, "ngram_trigrams", "w[BS][BS]").esrc.hotstring, 1)
		helpers.assert_eq(item(batch, "ngram_bigrams", "x[BS]").esrc.llm, 1,
			"generated text chains like typed text, as on Windows, and keeps its source")
		helpers.assert_eq(batch.errors["2026-08-06\1app"].bs_total, 0)
	end)
	it("linux-backspace-sequences: the writer receives the correction sequences", function()
		local batch = Walker.walk({ key("a", 100), key("b", 100), key("[BS]", 100) }, "2026-08-06", "app")
		local found = {}
		for _, group in ipairs(Walker.batches_for_writer(batch)) do
			for token in pairs(group.ngrams) do found[group.table_name .. ":" .. token] = true end
		end
		helpers.assert_true(found["ngram_bigrams:b[BS]"], "the bigram reaches the writer")
		helpers.assert_true(found["ngram_trigrams:ab[BS]"], "the trigram reaches the writer")
	end)
end)




-- ============================================================================
-- Across the flush boundary: one walk context per application
-- ============================================================================

-- A flush lands every few seconds, and each walk used to credit everything
-- still open at its end: every flush with typing became its own session, a
-- word cut by a flush became two words, and the bigram across the cut was
-- lost. Windows and macOS carry a per-application context between walks.
helpers.describe("aggregate walker: cross-flush context", function()
	local SESSION_GAP_MS = Fixture.SESSION_GAP_MS
	local DAY = "2026-08-06\1app"
	--- Walks `text` typed 100 ms apart from `start`, with real stamps.
	local function walk_typed(ctx, text, start, batch, day)
		local events, times = typed(text, 100), {}
		for index = 1, #events do times[index] = start + (index - 1) * 100 end
		return Walker.walk(events, day or "2026-08-06", "app", batch, { times = times, wall_offset_ms = 0 }, ctx),
			start + (#events - 1) * 100
	end
	it("linux-cross-flush-walk: a session cut by two flushes is one session", function()
		local ctx = {}
		local first, last = walk_typed(ctx, "hel", 1000)
		helpers.assert_nil(next(first.sessions), "an open session is not credited at the flush")
		local second
		second, last = walk_typed(ctx, "lo ", last + 100)
		helpers.assert_nil(next(second.sessions))
		local settled = Walker.settle(ctx, last + SESSION_GAP_MS + 1)
		local row = settled and settled.sessions[DAY]
		helpers.assert_true(row ~= nil, "the session is credited once its gap has passed")
		helpers.assert_eq(row.count_total, 1)
		helpers.assert_eq(row.longest_chars, 6)
		helpers.assert_eq(row.total_active_ms, 500)
	end)
	it("linux-cross-flush-walk: a word and a sequence continue across the flush", function()
		local ctx = {}
		local first, last = walk_typed(ctx, "hel", 1000)
		local second = walk_typed(ctx, "lo ", last + 100)
		helpers.assert_eq(count_of(first, "ngram_words", "hel"), 0, "the open word waits for its end")
		helpers.assert_eq(count_of(second, "ngram_words", "hello"), 1)
		helpers.assert_eq(count_of(second, "ngram_words", "lo"), 0)
		helpers.assert_eq(count_of(second, "ngram_bigrams", "ll"), 1, "the pair across the cut is counted")
		helpers.assert_eq(count_of(second, "ngram_trigrams", "ell"), 1)
	end)
	it("linux-cross-flush-walk: a correction ending a flush chains with the next", function()
		local ctx = {}
		local _, last = walk_typed(ctx, "ab", 1000)
		local bs = Walker.walk({ key("[BS]", 100), key("[BS]", 100) }, "2026-08-06", "app", nil,
			{ times = { last + 100, last + 200 }, wall_offset_ms = 0 }, ctx)
		helpers.assert_eq(count_of(bs, "ngram_bigrams", "b[BS]"), 1)
		local more = Walker.walk({ key("[BS]", 100), key("c", 100) }, "2026-08-06", "app", nil,
			{ times = { last + 300, last + 400 }, wall_offset_ms = 0 }, ctx)
		helpers.assert_eq(count_of(more, "ngram_trigrams", "[BS][BS][BS]"), 1)
		helpers.assert_eq(more.errors[DAY].cascade_count, 1, "three corrections across two flushes are one cascade")
		helpers.assert_eq(more.errors[DAY].recovery_count, 1)
	end)
	it("linux-cross-flush-walk: the stamps cut a session the capped delays cannot", function()
		local events = { key("a", 100), key("b", Fixture.PAUSE_MS) }
		local batch = Walker.walk(events, "2026-08-06", "app", nil,
			{ times = { 1000, 1000 + SESSION_GAP_MS + 1 }, wall_offset_ms = 0 })
		helpers.assert_eq(batch.sessions[DAY].count_total, 2,
			"a buffered delay never exceeds the pause cap, so only the stamps see the gap")
	end)
	it("linux-cross-flush-walk: settling credits only what its own gap has ended", function()
		local ctx = {}
		local _, last = walk_typed(ctx, "ab", 1000)
		helpers.assert_nil(Walker.settle(ctx, last + 100), "nothing has ended yet")
		local paused = Walker.settle(ctx, last + Fixture.PAUSE_MS)
		helpers.assert_eq(count_of(paused, "ngram_words", "ab"), 1, "a pause ends the word")
		helpers.assert_true(next(paused.bursts) ~= nil, "and the burst")
		helpers.assert_nil(next(paused.sessions), "but not the session")
		helpers.assert_nil(Walker.settle(ctx, last + Fixture.PAUSE_MS + 10), "a settled word is credited once")
		local after = walk_typed(ctx, "c", last + Fixture.PAUSE_MS + 100)
		helpers.assert_eq(count_of(after, "ngram_bigrams", "bc"), 0, "the pause broke the sequence")
	end)
	it("linux-cross-flush-walk: a new day credits the open context to the day it was typed on", function()
		local ctx = {}
		local _, last = walk_typed(ctx, "ab", 1000)
		local next_day = walk_typed(ctx, "c", last + 100, nil, "2026-08-07")
		helpers.assert_eq(next_day.sessions[DAY].count_total, 1, "the open session ends on its own day")
		helpers.assert_eq(count_of(next_day, "ngram_words", "ab"), 1)
		helpers.assert_nil(next_day.ngram.ngram_bigrams["2026-08-07\1app\1bc"], "nothing chains across midnight")
		local forced = Walker.settle(ctx, nil, nil, true)
		helpers.assert_eq(forced.sessions["2026-08-07\1app"].count_total, 1, "a forced settle ends everything")
		helpers.assert_nil(next(ctx), "and leaves nothing to continue")
	end)
end)





-- ============================================================================
-- The shared correction sequence corpus
-- ============================================================================

-- _shared/tests/corpus/keystats/correction_sequence_vectors.json is replayed by
-- the Windows and macOS walkers too, so the three drivers keep one definition of
-- the n-grams around a correction. Each flush is one walk over a carried context.
helpers.describe("aggregate walker: shared correction sequence corpus", function()
	local Json = require("json")
	local file = assert(io.open(assert(require("infra.paths").shared(
		"tests/corpus/keystats/correction_sequence_vectors.json")), "rb"))
	local data = Json.decode(assert(file:read("*a")))
	assert(file:close())
	it("corpus-correction-sequences: the corpus carries vectors", function()
		helpers.assert_true(type(data.vectors) == "table" and #data.vectors > 0)
	end)
	for _, vec in ipairs(data.vectors) do
		it("corpus-correction-sequences: " .. vec.id, function()
			local batch, ctx = nil, {}
			for _, flush in ipairs(vec.flushes) do
				local events = {}
				for _, ev in ipairs(flush) do events[#events + 1] = key(ev.char, ev.delay) end
				batch = Walker.walk(events, data.date, data.app, batch, nil, ctx)
			end
			local prefix = data.date .. "\1" .. data.app .. "\1"
			for family, expected in pairs(vec.expected) do
				local actual = {}
				for row_key, row in pairs(batch.ngram[family] or {}) do
					if row_key:sub(1, #prefix) == prefix and row.c > 0 then actual[row_key:sub(#prefix + 1)] = row.c end
				end
				for token, count in pairs(expected) do
					helpers.assert_eq(actual[token], count, vec.id .. ": " .. family .. " " .. token)
				end
				for token in pairs(actual) do
					helpers.assert_true(expected[token] ~= nil, vec.id .. ": " .. family .. " counts an unexpected " .. token)
				end
			end
		end)
	end
end)
