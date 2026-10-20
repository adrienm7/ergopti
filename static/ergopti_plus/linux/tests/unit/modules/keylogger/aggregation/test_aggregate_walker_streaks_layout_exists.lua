--- tests/unit/modules/keylogger/aggregation/test_aggregate_walker_streaks_layout_exists.lua

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

package.loaded["tests.support.modules.keylogger.aggregation.aggregate_walker_fixture"] = nil
local Fixture = require("tests.support.modules.keylogger.aggregation.aggregate_walker_fixture")
local helpers, it, Walker, key, typed, count_of =
	Fixture.helpers, Fixture.it, Fixture.Walker, Fixture.key, Fixture.typed, Fixture.count_of




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
-- Canonical backspace unigrams without extending correction sequences
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
		helpers.assert_eq(count_of(batch, "ngram_words", "b"), 1)
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
		-- The sequences ending in a correction are counted (linux-backspace-sequences);
		-- nothing is chained after one.
		helpers.assert_eq(count_of(batch, "ngram_bigrams", "a[BS]"), 1)
		helpers.assert_eq(count_of(batch, "ngram_bigrams", "[BS]b"), 0)
		helpers.assert_eq(count_of(batch, "ngram_trigrams", "a[BS]b"), 0)
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
-- dashboard can show which sequences the user goes back over; this walker
-- counted the unigram only and left both tables without a single correction.
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
	it("linux-backspace-sequences: nothing chains after a correction", function()
		local batch = Walker.walk({ key("a", 100), key("[BS]", 100), key("b", 100), key("c", 100),
			key("[BS]", 100) }, "2026-08-06", "app")
		helpers.assert_eq(count_of(batch, "ngram_bigrams", "[BS]b"), 0)
		helpers.assert_eq(count_of(batch, "ngram_bigrams", "bc"), 1, "the run restarts at the next character")
		helpers.assert_eq(count_of(batch, "ngram_bigrams", "c[BS]"), 1)
		helpers.assert_eq(count_of(batch, "ngram_trigrams", "bc[BS]"), 1)
		helpers.assert_eq(count_of(batch, "ngram_trigrams", "[BS]bc"), 0)
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
	it("linux-backspace-sequences: synthetic deletions keep their source and skip the output", function()
		local batch = Walker.walk({ key("b", 100), key("t", 100), key("w", 100),
			key("[BS]", 0, "hotstring"), key("[BS]", 0, "hotstring"),
			key("x", 0, "hotstring"), key("[BS]", 0, "llm") }, "2026-08-06", "app")
		local erase = item(batch, "ngram_bigrams", "w[BS]")
		helpers.assert_true(erase ~= nil, "the trigger the expansion erased is counted")
		helpers.assert_eq(erase.esrc.hotstring, 1)
		helpers.assert_eq(item(batch, "ngram_trigrams", "tw[BS]").esrc.hotstring, 1)
		helpers.assert_eq(item(batch, "ngram_trigrams", "w[BS][BS]").esrc.hotstring, 1)
		helpers.assert_eq(count_of(batch, "ngram_bigrams", "x[BS]"), 0,
			"generated text is not a typed sequence, so nothing chains through it")
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

