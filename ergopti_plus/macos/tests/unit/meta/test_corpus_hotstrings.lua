--- tests/unit/meta/test_corpus_hotstrings.lua

--- ==============================================================================
--- MODULE: Hotstring Corpus Consumer (Hammerspoon)
--- DESCRIPTION:
--- Loads the shared cross-driver corpus from
--- _shared/tests/corpus/hotstrings/vectors.json and validates each vector
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
-- The corpus lives two levels above the HS driver: static/ergopti_plus/_shared/
local corpus_path = helpers.shared("tests/corpus/hotstrings/vectors.json")

local function read_corpus()
	local fh = io.open(corpus_path, "r")
	if not fh then
		return nil, "cannot open corpus at " .. corpus_path
	end
	local raw = fh:read("*a")
	fh:close()
	-- Load hs stub to get access to json.decode
	package.loaded["infra.logger"] = nil
	helpers.load_with_stubs("infra.logger")
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
					-- Codepoint length of the trigger. A hand-rolled UTF-8 scan used to run
					-- here first and was then overwritten by utf8.len two lines down — its own
					-- comment said "the simple pattern above is imprecise", so it had been dead
					-- since the day it was written.
					local ok_len, tlen = pcall(utf8.len, v.trigger)
					helpers.assert_true(ok_len and tlen ~= nil,
						"corpus trigger must be valid UTF-8: " .. tostring(v.trigger))
					local trigger_codepoints = tlen
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
package.loaded["infra.logger"] = nil
helpers.load_with_stubs("infra.logger")
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
				-- Verify the buffer indeed ends with the trigger (corpus consistency),
				-- compared the way the vector says the trigger is matched. A
				-- case-SENSITIVE vector must end with it exactly; the default mode
				-- folds case, so "BTW" ending a buffer for trigger "btw" is the fold
				-- working rather than a malformed vector. Asserting the sensitive
				-- form for both held only while no vector exercised the fold — the
				-- same assumption sat in all three drivers' harnesses.
				local tlen = #v.trigger
				local tail = buf:sub(-tlen)
				-- Only is_case_sensitive_STRICT makes the comparison exact.
				-- is_case_sensitive alone selects literal registration and still folds,
				-- so "Adn" ending a buffer for trigger "adn" is a valid matched vector.
				local ends_with
				if v.is_case_sensitive_strict == true then
					ends_with = (tail == v.trigger)
				else
					ends_with = (tail:lower() == v.trigger:lower())
				end
				helpers.assert_true(ends_with,
					"vector '" .. v.id .. "': buffer does not end with trigger")
			end
		end
	end)

	-- Every per-entry flag a vector may declare, so the registration cannot quietly
	-- drop one. Naming them inline is how this harness came to ignore
	-- is_case_sensitive_strict entirely.
	local VECTOR_FLAGS = {
		"is_word", "auto_expand", "is_case_sensitive", "is_case_sensitive_strict", "final_result",
	}

	--- Registers one vector into a fresh registry and returns the state holding it.
	--- @param v table The corpus vector.
	--- @return table The core_state, whose .mappings holds every registered entry.
	local function register_vector(v)
		local R     = helpers.load_with_stubs("modules.keymap.registry")
		local state = {
			magic_key               = "★",
			mappings                = {},
			mappings_lookup         = {},
			mappings_by_tail_char   = {},
			mappings_by_star_tail_char = {},
			groups                  = {},
			seq_counter             = 0,
			current_group           = "corpus",
			start_is_word_boundary  = true,
		}
		R.init(state)
		local opts = {}
		for _, flag in ipairs(VECTOR_FLAGS) do opts[flag] = v[flag] == true end
		R.add(v.trigger, v.replacement or "", opts)
		return state
	end

	-- This replaces a check that decided the outcome ITSELF — it compared the
	-- buffer tail to the trigger byte-for-byte and asserted the vector's expected
	-- flag against its own answer, so it validated the harness's model of case
	-- rather than the driver's. Every one of the 29 vectors is auto_expand, and
	-- would_fire is the pure predicate the real engine and the tooltip both call,
	-- so the whole corpus can be replayed through it — outcome AND output text.
	helpers.describe("hotstring corpus — replay through the real matcher", function()
		helpers.it("every vector's matched flag and replacement come from would_fire", function()
			if not corpus then return end
			local checked, skipped = 0, 0
			for _, v in ipairs(corpus.vectors) do
				-- A vector may declare that its outcome hangs on a constant the drivers
				-- deliberately do not share — today only the rolling-buffer cap, which is
				-- 500 codepoints here and 256 in the shared Lua engine. Asserting it
				-- would pin the other driver's number to this one.
				if v.driver_specific ~= nil then
					skipped = skipped + 1
				elseif v.auto_expand ~= true then
					-- The non-star case, and it must NOT go through would_fire. That is a
					-- pure buffer-tail predicate: it never reads the flag, so replaying a
					-- non-star vector through it asserts something the function was never
					-- deciding. The flag is honoured one level up, in try_auto_expand —
					-- which is exactly where macOS turned out to have no gate at all, so a
					-- non-star trigger expanded the moment it was complete and rewrote the
					-- user's word as they typed it.
					local state = register_vector(v)
					local Expander = helpers.load_with_stubs("modules.keymap.expander")
					local Registry = helpers.load_with_stubs("modules.keymap.registry")
					Expander.init(state, Registry, {})
					state.buffer = v.buffer or v.trigger
					state.start_is_word_boundary = true
					local fired = false
					for _, m in ipairs(state.mappings) do
						if Expander.try_auto_expand(m, 1, false) then fired = true ; break end
					end
					helpers.assert_eq((v.expected and v.expected.matched == true), fired,
						"vector '" .. v.id .. "': the auto path disagrees with the corpus")
					checked = checked + 1
				elseif v.auto_expand == true then
					local state = register_vector(v)
					-- would_fire consults the expander's OWN state for
					-- start_is_word_boundary, so the expander has to be initialised with
					-- the same state the registry got. Left uninitialised it reads nil,
					-- which silently blocks every is_word trigger sitting at the start of
					-- the buffer — one vector's worth of false red, and it would have been
					-- false GREEN for a vector expecting no match.
					local Expander = helpers.load_with_stubs("modules.keymap.expander")
					local Registry = helpers.load_with_stubs("modules.keymap.registry")
					-- The LLM bridge is a hard requirement of init(), and would_fire never
					-- touches it; an empty table satisfies the guard without stubbing a
					-- module this replay has no opinion about.
					Expander.init(state, Registry, {})
					local buffer = v.buffer or v.trigger
					local fired, produced = false, nil
					for _, m in ipairs(state.mappings) do
						local eff = Expander.would_fire(m, buffer)
						if eff then fired, produced = true, eff ; break end
					end
					local want = (v.expected and v.expected.matched == true)
					helpers.assert_eq(want, fired,
						"vector '" .. v.id .. "': would_fire disagrees with the corpus")
					if want and v.expected.replacement then
						helpers.assert_eq(v.expected.replacement, produced,
							"vector '" .. v.id .. "': wrong replacement text")
					end
					checked = checked + 1
				end
			end
			helpers.assert_true(checked > 0,
				"no vector was replayed — the corpus shape changed and this test went vacuous")
			-- The skip is bounded so it cannot become a place to park failures: every
			-- vector but the declared driver-specific ones must have been replayed.
			helpers.assert_eq(#corpus.vectors - skipped, checked,
				"a vector was neither replayed nor declared driver_specific — silently "
					.. "dropping one is how a corpus reports coverage it does not have")
		end)
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




-- =================================================
-- =================================================
-- ======= 4/ Collision priority resolution ========
-- =================================================
-- =================================================

-- Drives the shared collision corpus through the REAL registry: each mapping is
-- added under its own source group (so cross-source same-trigger entries compete
-- rather than collapse), the list is sorted, and the winner for the buffer is the
-- first entry in the tail bucket whose trigger is an exact suffix. This mirrors
-- the expander's hot-path selection and must agree with the AHK engine on every
-- vector — the cross-driver collision contract (length > priority > first added).

--- Builds a fresh, initialized registry for a single collision vector so adds
--- never bleed across vectors.
--- @return table The registry module reference.
local function fresh_collision_registry()
	package.loaded["modules.keymap.registry"] = nil
	package.loaded["modules.keymap.terminators"] = nil
	package.loaded["infra.logger"] = nil
	helpers.load_with_stubs("infra.logger")
	local R = helpers.load_with_stubs("modules.keymap.registry")
	R.init({
		magic_key                  = "★",
		mappings                   = {},
		mappings_lookup            = {},
		mappings_by_tail_char      = {},
		mappings_by_star_tail_char = {},
		groups                     = {},
		seq_counter                = 0,
		current_group              = nil,
		start_is_word_boundary     = true,
	})
	return R
end

--- Returns the replacement that fires for `buffer`, or nil when nothing matches.
--- Collision mappings are case-sensitive, so the stored trigger is the exact
--- match string (no case variants are generated) and a byte-wise suffix test on
--- the sorted bucket reproduces the engine's winner.
--- @param R table The registry module reference.
--- @param buffer string The simulated input buffer (ASCII in the corpus).
--- @return string|nil The winning replacement, or nil.
local function collision_winner(R, buffer)
	if buffer == "" then return nil end
	local tail   = buffer:sub(-1):lower()  -- corpus collision buffers are ASCII
	local bucket = R.mappings_for_tail(tail)
	if not bucket then return nil end
	for _, m in ipairs(bucket) do
		local tl = #m.trigger
		if #buffer >= tl and buffer:sub(-tl) == m.trigger then
			return m.repl
		end
	end
	return nil
end

helpers.describe("hotstring corpus — collision priority", function()
	helpers.it("corpus exposes a non-empty collision_vectors array", function()
		helpers.assert_true(corpus ~= nil, "corpus load error: " .. tostring(corpus_err))
		helpers.assert_true(type(corpus.collision_vectors) == "table"
			and #corpus.collision_vectors > 0,
			"corpus.collision_vectors must be a non-empty table")
	end)

	helpers.it("every collision vector resolves to the expected winner", function()
		if not corpus or type(corpus.collision_vectors) ~= "table" then return end
		for _, v in ipairs(corpus.collision_vectors) do
			helpers.assert_true(type(v.id) == "string" and v.id ~= "",
				"collision vector missing id")
			helpers.assert_true(type(v.mappings) == "table" and #v.mappings > 0,
				"collision vector '" .. tostring(v.id) .. "' missing mappings")

			local R = fresh_collision_registry()
			for _, m in ipairs(v.mappings) do
				-- Register under the mapping's own source group so two entries for
				-- one trigger coexist and the priority sort can elect the winner.
				R.set_group_context(m.group or "g")
				R.add(m.trigger, m.replacement or "", {
					is_case_sensitive = m.is_case_sensitive == true,
					priority          = m.priority,
				})
			end
			R.set_group_context(nil)
			R.sort_mappings()

			local winner = collision_winner(R, v.buffer or "")
			if v.expected and v.expected.matched == true then
				helpers.assert_eq(winner, v.expected.winner,
					"collision vector '" .. v.id .. "': wrong winner")
			else
				helpers.assert_true(winner == nil,
					"collision vector '" .. v.id .. "': expected no match, got '" .. tostring(winner) .. "'")
			end
		end
	end)
end)
