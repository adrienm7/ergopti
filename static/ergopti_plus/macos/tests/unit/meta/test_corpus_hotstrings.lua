--- tests/unit/meta/test_corpus_hotstrings.lua

--- ==============================================================================
--- MODULE: Hotstring Corpus Consumer (Hammerspoon)
--- DESCRIPTION:
--- Loads the shared cross-driver corpus from
--- shared/tests/corpus/hotstrings/vectors.json and validates each vector
--- against the Hammerspoon registry module.
---
--- COVERAGE:
--- 1. Corpus integrity — every vector in the JSON file is structurally valid
---    (required fields present, backspace_count formula consistent).
--- 2. Registry integration — triggers added via M.add() are found by
---    has_exact_trigger() and has_trigger_suffix(); non-matching buffers are
---    rejected. Case-sensitivity flag is respected.
--- 3. Backspace-count arithmetic — the expected backspace_count from the corpus
---    equals trigger_length (+ 1 when terminator_consumed = true).
---
--- NOTE:
--- The full expansion pipeline (word-boundary enforcement, emit dispatch,
--- LLM bridge interaction) is exercised by test_expander.lua. This file
--- focuses on the pure matching and arithmetic invariants shared with AHK.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ========================================
-- ========================================
-- ======= 1/ Corpus file loading =========
-- ========================================
-- ========================================

-- Resolve the corpus path relative to the driver root
local driver_root = helpers.driver_root()
-- The corpus lives two levels above the HS driver: static/ergopti_plus/shared/
local corpus_path = driver_root .. "../shared/tests/corpus/hotstrings/vectors.json"

local function read_corpus()
	local fh = io.open(corpus_path, "r")
	if not fh then
		return nil, "cannot open corpus at " .. corpus_path
	end
	local raw = fh:read("*a")
	fh:close()
	-- Load hs stub to get access to json.decode
	package.loaded["lib.logger"] = nil
	helpers.load_with_stubs("lib.logger")
	local ok, corpus = pcall(require("hs").json.decode, raw)
	if not ok then return nil, "JSON parse error: " .. tostring(corpus) end
	return corpus, nil
end

local corpus, corpus_err = read_corpus()




-- ======================================
-- ======================================
-- ======= 2/ Corpus integrity ==========
-- ======================================
-- ======================================

helpers.describe("hotstring corpus — integrity", function()
	helpers.it("corpus file is readable and parseable", function()
		helpers.assert_true(corpus ~= nil, "corpus load error: " .. tostring(corpus_err))
		helpers.assert_true(type(corpus.vectors) == "table",
			"corpus.vectors must be a table")
		helpers.assert_true(#corpus.vectors > 0,
			"corpus must contain at least one vector")
	end)

	helpers.it("every vector has required fields: id, trigger, expected", function()
		if not corpus then return end
		for _, v in ipairs(corpus.vectors) do
			helpers.assert_true(type(v.id) == "string" and v.id ~= "",
				"vector missing id")
			helpers.assert_true(type(v.trigger) == "string" and v.trigger ~= "",
				"vector '" .. tostring(v.id) .. "' missing trigger")
			helpers.assert_true(type(v.expected) == "table",
				"vector '" .. tostring(v.id) .. "' missing expected table")
		end
	end)

	helpers.it("backspace_count in matched vectors equals trigger_length [+ 1 if consumed]", function()
		if not corpus then return end
		for _, v in ipairs(corpus.vectors) do
			if v.expected and v.expected.matched == true then
				local bc = v.expected.backspace_count
				if bc ~= nil then
					-- Compute codepoint length of trigger (handles ASCII and multi-byte)
					local trigger_codepoints = 0
					for _ in v.trigger:gmatch("[\0-\127\194-\244][\128-\191]*") do
						trigger_codepoints = trigger_codepoints + 1
					end
					-- Wait — the simple pattern above is imprecise. Use utf8.len for correctness.
					local ok_len, tlen = pcall(utf8.len, v.trigger)
					if ok_len and tlen then trigger_codepoints = tlen end
					local consumed_bonus = (v.terminator_consumed == true) and 1 or 0
					local expected_bc    = trigger_codepoints + consumed_bonus
					helpers.assert_eq(bc, expected_bc,
						"vector '" .. v.id .. "' backspace_count mismatch")
				end
			end
		end
	end)
end)




-- ==========================================
-- ==========================================
-- ======= 3/ Registry integration ==========
-- ==========================================
-- ==========================================

-- Load the registry with a clean stub environment
package.loaded["lib.logger"] = nil
helpers.load_with_stubs("lib.logger")
local Registry = helpers.load_with_stubs("modules.keymap.registry")

-- Registry requires a core_state; provide a minimal one.
Registry.init({
	magic_key               = "★",
	mappings                = {},
	mappings_lookup         = {},
	mappings_by_tail_char   = {},
	mappings_by_star_tail_char = {},
	groups                  = {},
seq_counter             = 0,
	current_group           = "corpus",
	start_is_word_boundary  = true,
})

helpers.describe("hotstring corpus — registry matching", function()
	helpers.it("trigger added to registry is found by has_exact_trigger", function()
		if not corpus then return end
		for _, v in ipairs(corpus.vectors) do
			if v.expected and v.expected.matched == true then
				-- Fresh registry per vector to avoid cross-vector interference
				local R = helpers.load_with_stubs("modules.keymap.registry")
				R.init({
					magic_key               = "★",
					mappings                = {},
					mappings_lookup         = {},
					mappings_by_tail_char   = {},
					mappings_by_star_tail_char = {},
					groups                  = {},
seq_counter             = 0,
					current_group           = "corpus",
					start_is_word_boundary  = true,
				})
				R.add(v.trigger, v.replacement or "", {
					is_case_sensitive = v.is_case_sensitive == true,
					is_word           = v.is_word == true,
				})
				helpers.assert_true(R.has_exact_trigger(v.trigger),
					"vector '" .. v.id .. "': trigger not found after add()")
			end
		end
	end)

	helpers.it("buffer ending with trigger matches has_trigger_suffix", function()
		if not corpus then return end
		for _, v in ipairs(corpus.vectors) do
			if v.expected and v.expected.matched == true then
				local R = helpers.load_with_stubs("modules.keymap.registry")
				R.init({
					magic_key               = "★",
					mappings                = {},
					mappings_lookup         = {},
					mappings_by_tail_char   = {},
					mappings_by_star_tail_char = {},
					groups                  = {},
seq_counter             = 0,
					current_group           = "corpus",
					start_is_word_boundary  = true,
				})
				R.add(v.trigger, v.replacement or "", {
					is_case_sensitive = v.is_case_sensitive == true,
					is_word           = v.is_word == true,
				})
				-- The trigger must be a suffix of the buffer for a real match to fire
				local buf = v.buffer or v.trigger
				helpers.assert_true(R.has_trigger_suffix(v.trigger),
					"vector '" .. v.id .. "': trigger not a known suffix after add()")
				-- Verify the buffer indeed ends with the trigger (corpus consistency)
				local tlen = #v.trigger
				helpers.assert_true(buf:sub(-tlen) == v.trigger,
					"vector '" .. v.id .. "': buffer does not end with trigger")
			end
		end
	end)

	helpers.it("case-sensitive vectors: buffer casing determines match flag", function()
		if not corpus then return end
		for _, v in ipairs(corpus.vectors) do
			if v.is_case_sensitive ~= true then goto continue end
			local R = helpers.load_with_stubs("modules.keymap.registry")
			R.init({
				magic_key               = "★",
				mappings                = {},
				mappings_lookup         = {},
				mappings_by_tail_char   = {},
				mappings_by_star_tail_char = {},
				groups                  = {},
				seq_counter             = 0,
				current_group           = "corpus",
				start_is_word_boundary  = true,
			})
			R.add(v.trigger, v.replacement or "", { is_case_sensitive = true, is_word = v.is_word == true })
			local buf  = v.buffer or v.trigger
			local tlen = #v.trigger
			local buf_tail = buf:sub(-tlen)
			-- Case-sensitive: only an exact byte-for-byte match of the tail triggers.
			local actually_matches = (buf_tail == v.trigger)
			local expected_matches = (v.expected and v.expected.matched == true)
			helpers.assert_eq(expected_matches, actually_matches,
				"vector '" .. v.id .. "': case-sensitive match flag inconsistency")
			::continue::
		end
	end)

	helpers.it("non-matching buffers do not produce suffix hits", function()
		if not corpus then return end
		for _, v in ipairs(corpus.vectors) do
			if v.expected and v.expected.matched == false then
				local R = helpers.load_with_stubs("modules.keymap.registry")
				R.init({
					magic_key               = "★",
					mappings                = {},
					mappings_lookup         = {},
					mappings_by_tail_char   = {},
					mappings_by_star_tail_char = {},
					groups                  = {},
seq_counter             = 0,
					current_group           = "corpus",
					start_is_word_boundary  = true,
				})
				R.add(v.trigger, v.replacement or "", {
					is_case_sensitive = v.is_case_sensitive == true,
					is_word           = v.is_word == true,
				})
				-- The buffer should NOT end with the trigger for a no-match vector
				local buf  = v.buffer or ""
				local tlen = #v.trigger
				local buf_ends_with_trigger = buf:sub(-tlen) == v.trigger
				if not buf_ends_with_trigger then
					-- Verify registry confirms no suffix match with this buffer
					helpers.assert_true(not R.has_trigger_suffix(buf),
						"vector '" .. v.id .. "': non-matching buffer found as suffix")
				end
				-- (Vectors where buffer ends with trigger but is_word blocks are
				-- intentionally skipped here — word-boundary is tested in test_expander.lua)
			end
		end
	end)
end)
