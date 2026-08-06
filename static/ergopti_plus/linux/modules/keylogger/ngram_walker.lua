--- modules/keylogger/ngram_walker.lua

--- ==============================================================================
--- MODULE: N-gram Walker (Linux)
--- DESCRIPTION:
--- Replays a buffered character stream into the nine n-gram families the shared
--- schema declares, using the driver-agnostic accumulators in
--- _shared/lua/keylogger/aggregator_helpers.lua.
---
--- WHAT WAS THERE BEFORE:
--- One family. This driver counted single characters and nothing else, so eight
--- of the nine tables the dashboard reads were empty BY CONSTRUCTION — not by
--- accident, and not recoverable from the data already stored. The same-finger
--- bigram analysis, the word lists, the error analysis and the heatmap's
--- first/last counts each had nothing to read and rendered blank, on a driver
--- that had been collecting keystrokes the whole time.
---
--- FEATURES & RATIONALE:
--- 1. The accumulators are shared. `new_batch` already names all nine tables and
---    `push_ngram` already carries the delay, the error flag and the synthetic
---    source into each row. macOS was the only consumer; nothing here needed
---    writing except the walk itself.
--- 2. A long pause breaks continuity. Two characters either side of a coffee
---    break are not a bigram, and counting them as one puts a phantom pair into
---    the same-finger analysis that no hand ever typed. The threshold is the
---    cross-driver one from the shared timing canon.
--- 3. Synthetic output does not become a typing n-gram. A hotstring's expansion
---    is text the user did not type; folding it into the bigram counts would
---    make the layout look better the more expansions they use, which is exactly
---    backwards for a tool that measures typing effort.
--- 4. Pure. It takes a stream and returns a batch — no clock, no database, no
---    file. Everything it decides is decidable on a machine with no keyboard.
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

--- Replays one application's buffered stream into an n-gram batch.
---
--- @param events table Array of { char, delay_ms, meta } as the keylogger buffers them.
--- @param date_str string "YYYY-MM-DD".
--- @param app string Application identifier.
--- @param batch table|nil An existing batch to add to; a fresh one when absent.
--- @return table The batch.
function M.walk(events, date_str, app, batch)
	batch = batch or Helpers.new_batch()
	if type(events) ~= "table" then return batch end

	-- The tail of the current run, newest last. Cleared by a pause, a backspace
	-- or a switch to synthetic output, because each of those means the next
	-- character does not follow the previous one from the same hand.
	local run = {}
	local word, previous_word = "", nil

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

	for _, event in ipairs(events) do
		local char  = event[1]
		local delay = tonumber(event[2]) or 0
		local is_synthetic, source = synthetic_of(event)

		if char == BACKSPACE_MARKER then
			-- A correction. The run is broken because what follows continues from
			-- a different character than it appears to, and the partial word is
			-- abandoned rather than recorded — the user was not writing it.
			run = {}
			word = ""
		elseif is_synthetic then
			-- Counted so the source histogram stays honest about how much of the
			-- day's text the driver produced, but NOT chained: an expansion is not
			-- something the user's hands did, and letting it join the bigram counts
			-- would make the layout look better the more expansions they use.
			Helpers.push_ngram(batch, "ngram_chars", date_str, app, char, 0, false, source)
			run = {}
			word = ""
		else
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
	-- discarded.
	flush_word()
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

return M
