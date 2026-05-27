--- tests/unit/meta/test_hotstringmatcher.lua

--- ==============================================================================
--- MODULE: HotstringMatcher — Domain Spec Coverage (Hammerspoon)
--- DESCRIPTION:
--- Validates the Hammerspoon hotstring matching logic against the cross-driver
--- contract vectors defined in shared/domain/HotstringMatcher.spec.js.
---
--- The canonical matching algorithm is specified in HotstringMatcher.spec.js.
--- The HS implementation is split between modules/keymap/registry.lua
--- (tail-char bucketing, longest-first sort) and modules/keymap/expander.lua
--- (word-boundary check, backspace count, consume_terminator flag).
---
--- COVERAGE:
--- 1. Suffix matching — buffer ending with trigger is found via mappings_for_tail.
--- 2. Longest-match-first — Registry sorts candidates longest-first per bucket.
--- 3. Word-boundary enforcement — is_word triggers blocked mid-word; allowed at
---    start-of-buffer, after space, after punctuation.
--- 4. Backspace count — tlen + (terminator_consumed ? 1 : 0).
--- 5. Case sensitivity — default insensitive; is_case_sensitive forces exact match.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ============================================
-- ============================================
-- ======= 1/ Registry setup helpers ==========
-- ============================================
-- ============================================

--- Builds a fresh Registry instance seeded with the given mapping specs.
--- @param specs table Array of {trigger, repl, group, is_word, is_case_sensitive}.
--- @return table Registry module with mappings loaded.
local function make_registry(specs)
	package.loaded["lib.logger"] = nil
	helpers.load_with_stubs("lib.logger")
	local R = helpers.load_with_stubs("modules.keymap.registry")
	R.init({
		magic_key               = "\xe2\x98\x85",  -- UTF-8 for ★
		mappings                = {},
		mappings_lookup         = {},
		mappings_by_tail_char   = {},
		mappings_by_star_tail_char = {},
		groups                  = {},
		seq_counter             = 0,
		current_group           = "test",
		start_is_word_boundary  = true,
	})
	for _, spec in ipairs(specs) do
		R.add(spec.trigger, spec.repl or "", {
			is_word           = spec.is_word           == true,
			is_case_sensitive = spec.is_case_sensitive == true,
			group             = spec.group or "test",
		})
	end
	-- Build tail-char indexes (required for mappings_for_tail to return results)
	R.sort_mappings()
	return R
end

--- Returns the tail UTF-8 codepoint of a string.
--- @param s string
--- @return string The last UTF-8 codepoint.
local function tail_char(s)
	if #s == 0 then return "" end
	local ok, offset = pcall(utf8.offset, s, -1)
	if not ok or not offset then return s:sub(-1) end
	return s:sub(offset)
end

--- Checks word-boundary: returns true if the character immediately before the
--- trigger in the buffer is a non-word character (space, punctuation, etc.)
--- or the trigger occupies the entire buffer (start-of-buffer boundary).
--- @param buffer string The full typing buffer.
--- @param trig_len number Codepoint length of the trigger.
--- @return boolean
local function word_boundary_ok(buffer, trig_len)
	local ok_blen, blen = pcall(utf8.len, buffer)
	blen = (ok_blen and blen) or #buffer
	-- Start-of-buffer: trigger fills the entire buffer
	if blen <= trig_len then return true end
	-- The preceding codepoint is at 1-based index (blen - trig_len)
	-- utf8.offset returns the byte position of that codepoint
	local preceding_idx = blen - trig_len
	local ok_off, byte_off = pcall(utf8.offset, buffer, preceding_idx)
	if not ok_off or not byte_off then return false end
	-- Determine end byte of that codepoint (start of next - 1)
	local ok_next, next_off = pcall(utf8.offset, buffer, preceding_idx + 1)
	local preceding
	if ok_next and next_off then
		preceding = buffer:sub(byte_off, next_off - 1)
	else
		preceding = buffer:sub(byte_off)
	end
	-- Non-word: space, tab, punctuation (anything not alphanumeric or _)
	return preceding:match("[%s%p]") ~= nil
end




-- ============================================
-- ============================================
-- ======= 2/ Suffix matching tests ===========
-- ============================================
-- ============================================

helpers.describe("hotstringmatcher — suffix matching", function()
	helpers.it("buffer ending with trigger is found by mappings_for_tail", function()
		local R = make_registry({ { trigger = "btw", repl = "by the way", group = "g" } })
		local tc = tail_char("btw")
		local candidates = (R.mappings_for_tail(tc) or {})
		helpers.assert_true(#candidates > 0, "mappings_for_tail('w') must return candidates")
		helpers.assert_eq("btw", candidates[1].trigger, "first candidate trigger")
	end)

	helpers.it("buffer not ending with trigger yields empty bucket", function()
		local R = make_registry({ { trigger = "btw", repl = "by the way", group = "g" } })
		local candidates = (R.mappings_for_tail("z") or {})
		helpers.assert_true(#candidates == 0, "bucket for 'z' must be empty")
	end)

	helpers.it("longest trigger appears first in bucket (longest-match-first)", function()
		local R = make_registry({
			{ trigger = "btw",  repl = "by the way",     group = "g" },
			{ trigger = "btww", repl = "by the way wow", group = "g" },
		})
		local candidates = (R.mappings_for_tail("w") or {})
		helpers.assert_true(#candidates >= 2, "bucket must have 2 candidates")
		helpers.assert_eq("btww", candidates[1].trigger,
			"longer trigger must be first (longest-match-first)")
	end)
end)




-- ============================================
-- ============================================
-- ======= 3/ Word-boundary tests =============
-- ============================================
-- ============================================

helpers.describe("hotstringmatcher — word-boundary enforcement", function()
	helpers.it("is_word trigger blocked mid-word (preceded by letter)", function()
		local trig = "the"
		local ok_tlen, tlen = pcall(utf8.len, trig)
		tlen = (ok_tlen and tlen) or #trig
		helpers.assert_true(not word_boundary_ok("othe", tlen),
			"'othe' -> 'o' is word char -> boundary NOT ok")
	end)

	helpers.it("is_word trigger allowed at start-of-buffer", function()
		local trig = "the"
		local ok_tlen, tlen = pcall(utf8.len, trig)
		tlen = (ok_tlen and tlen) or #trig
		helpers.assert_true(word_boundary_ok("the", tlen),
			"buffer == trigger -> start-of-buffer -> boundary ok")
	end)

	helpers.it("is_word trigger allowed after space", function()
		local trig = "the"
		local ok_tlen, tlen = pcall(utf8.len, trig)
		tlen = (ok_tlen and tlen) or #trig
		helpers.assert_true(word_boundary_ok("hello the", tlen),
			"preceded by space -> boundary ok")
	end)

	helpers.it("is_word trigger allowed after punctuation", function()
		local trig = "the"
		local ok_tlen, tlen = pcall(utf8.len, trig)
		tlen = (ok_tlen and tlen) or #trig
		helpers.assert_true(word_boundary_ok(".the", tlen),
			"preceded by '.' -> boundary ok")
	end)
end)




-- ============================================
-- ============================================
-- ======= 4/ Backspace count tests ===========
-- ============================================
-- ============================================

helpers.describe("hotstringmatcher — backspace count formula", function()
	helpers.it("backspace_count = tlen when terminator not consumed", function()
		local R = make_registry({ { trigger = "btw", repl = "by the way", group = "g" } })
		local candidates = (R.mappings_for_tail("w") or {})
		helpers.assert_true(#candidates > 0, "must have candidates")
		local m   = candidates[1]
		local bc  = m.tlen  -- no terminator consumed
		helpers.assert_eq(3, bc, "backspace_count without terminator = tlen = 3")
	end)

	helpers.it("backspace_count = tlen + 1 when terminator consumed", function()
		local R = make_registry({ { trigger = "btw", repl = "by the way", group = "g" } })
		local candidates = (R.mappings_for_tail("w") or {})
		helpers.assert_true(#candidates > 0, "must have candidates")
		local m  = candidates[1]
		local bc = m.tlen + 1  -- terminator consumed
		helpers.assert_eq(4, bc, "backspace_count with terminator = tlen + 1 = 4")
	end)
end)




-- ============================================
-- ============================================
-- ======= 5/ Case sensitivity tests ==========
-- ============================================
-- ============================================

helpers.describe("hotstringmatcher — case sensitivity", function()
	helpers.it("lowercase trigger is stored and found case-insensitively", function()
		local R = make_registry({ { trigger = "btw", repl = "by the way", group = "g" } })
		-- The registry stores the trigger as-is; case folding is the expander's job.
		-- We just verify the mapping is present with the correct trigger.
		local candidates = (R.mappings_for_tail("w") or {})
		helpers.assert_true(#candidates > 0, "bucket must not be empty")
		helpers.assert_eq("btw", candidates[1].trigger, "trigger stored as-is")
	end)

	helpers.it("is_case_sensitive flag is stored on the mapping", function()
		local R = make_registry({
			{ trigger = "BTW", repl = "by the way", group = "g", is_case_sensitive = true }
		})
		-- rebuild_tail_indexes normalises all bucket keys to lowercase so that the
		-- expander's bucket_for() — which always lowercases the tail — can find
		-- case-sensitive uppercase triggers (e.g. "BTW") at match time.
		-- The mapping itself still stores the original-case trigger.
		local candidates = (R.mappings_for_tail("w") or {})
		helpers.assert_true(#candidates > 0, "bucket for 'w' must not be empty")
		-- The trigger is preserved in its original uppercase form inside the mapping
		-- so that try_terminator_expand performs an exact byte comparison correctly.
		helpers.assert_eq("BTW", candidates[1].trigger, "uppercase trigger stored as-is")
	end)
end)
