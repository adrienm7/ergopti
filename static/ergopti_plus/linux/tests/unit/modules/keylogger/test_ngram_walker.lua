--- tests/unit/modules/keylogger/test_ngram_walker.lua

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

local Walker = helpers.load_module("modules.keylogger.ngram_walker")
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
		package.loaded[writer_name] = {
			open_db = function() return true end,
			register_device = function() return true end,
			is_available = function() return true end,
			bump_rev = function() return true end,
			insert_typing_events = function() return true end,
			insert_hotstring_events = function() return true end,
			insert_shortcut_events = function() return true end,
			insert_app_switch_events = function() return true end,
			upsert_app_day = function() return true end,
			upsert_scancodes = function() return true end,
			upsert_ngrams = function(_device, _date, _app, ngrams, table_name)
				calls[#calls + 1] = { table_name = table_name or "ngram_chars", ngrams = ngrams }
				return true
			end,
		}
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
