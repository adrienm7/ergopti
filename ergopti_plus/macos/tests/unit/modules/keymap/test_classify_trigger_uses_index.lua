--- tests/unit/modules/keymap/test_classify_trigger_uses_index.lua

--- ==============================================================================
--- MODULE: classify_trigger — Index Equivalence
--- DESCRIPTION:
--- `registry.classify_trigger(str)` answers three questions about the corpus:
--- is `str` an exact trigger, is it a PREFIX of one, is it a SUFFIX of one. It
--- used to answer them by walking every registered mapping and building two
--- substrings per entry — ~10-15k entries in production — inside the keyDown
--- eventtap.
---
--- It now reads two buckets instead. A trigger that EQUALS `str` or ENDS WITH it
--- necessarily shares its last codepoint; one that STARTS WITH it shares its
--- first. Both indexes are keyed by the FOLDED codepoint and therefore hold a
--- superset of the candidates, so the byte-exact comparisons still decide — the
--- index narrows the search, it does not answer the question.
---
--- WHY THIS TEST IS A PROPERTY AND NOT A LIST OF CASES:
--- an index is exactly the kind of optimisation that is right on every example
--- someone thinks to write and wrong on the one they do not. The oracle here is
--- the linear scan the index replaced, implemented in the test, and the two are
--- compared over a corpus deliberately built to include the cases where a
--- careless index diverges: multi-byte first and last codepoints, case
--- differences (the buckets fold, the comparison does not), a trigger that is a
--- strict prefix of another, one that is a strict suffix, and queries longer
--- than any trigger.
---
--- WHAT IT ALSO PINS: classify_trigger must work between an M.add and the next
--- sort_mappings. The indexes are built by the sort, so the first version of
--- this optimisation answered "no" to everything until something happened to
--- sort — which two corpus tests caught and no unit test would have.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ==========================================
-- ==========================================
-- ======= 1/ The oracle ====================
-- ==========================================
-- ==========================================

--- The full-corpus scan classify_trigger used to be. This is the definition the
--- index must agree with, kept in the test so production has exactly one.
--- @param triggers table Array of registered trigger strings.
--- @param str string The query.
--- @return boolean exact, boolean prefix, boolean suffix
local function scan(triggers, str)
	local n, exact, pref, suff = #str, false, false, false
	for _, t in ipairs(triggers) do
		if t == str            then exact = true end
		if t:sub(1, n) == str  then pref  = true end
		if t:sub(-n)   == str  then suff  = true end
	end
	return exact, pref, suff
end

--- Builds a registry holding `triggers`.
--- @param triggers table Array of trigger strings.
--- @param sorted boolean Whether to sort (and so build the indexes) after adding.
--- @return table The registry module.
local function registry_with(triggers, sorted)
	local R = helpers.load_with_stubs("modules.keymap.registry")
	R.init({
		magic_key                  = "★",
		mappings                   = {},
		mappings_lookup            = {},
		mappings_by_tail_char      = {},
		mappings_by_star_tail_char = {},
		groups                     = {},
		seq_counter                = 0,
		current_group              = "idx",
		start_is_word_boundary     = true,
	})
	for _, t in ipairs(triggers) do
		-- is_case_sensitive_strict: registered exactly as written, so the corpus is
		-- the trigger list and not a cased family of it. This test is about the
		-- index, and a family would make the oracle disagree for reasons that have
		-- nothing to do with bucketing.
		R.add(t, "x" .. t, { is_case_sensitive = true, is_case_sensitive_strict = true, auto_expand = true })
	end
	if sorted then R.sort_mappings() end
	return R
end

-- Chosen for the ways an index can be wrong, not for coverage of ordinary words.
local CORPUS = {
	"btw", "btwx", "abtw",          -- strict prefix and strict suffix of each other
	"BTW",                          -- same folded bucket, different bytes
	"café", "écafe",                -- multi-byte last codepoint / multi-byte first
	"★star", "star★",               -- the magic key at each end
	"a",                            -- single codepoint
	"the", "lathe", "theatre",
}

local QUERIES = {
	"btw", "BTW", "Btw", "bt", "tw", "b", "w", "x",
	"café", "caf", "é", "écafe", "é" .. "cafe",
	"★", "★star", "star★", "star", "a", "the", "lathe", "theatre",
	"", "zzzzzzzzzzzzzzzzzzzz",     -- empty and longer than every trigger
}




-- ==========================================
-- ==========================================
-- ======= 2/ Equivalence ===================
-- ==========================================
-- ==========================================

helpers.describe("classify_trigger: the index agrees with the scan it replaced", function()

	helpers.it("gives the scan's answer for every query, sorted", function()
		local R = registry_with(CORPUS, true)
		local checked = 0
		for _, q in ipairs(QUERIES) do
			local we, wp, ws = scan(CORPUS, q)
			local ge, gp, gs = R.classify_trigger(q)
			if q == "" then
				-- The empty string is rejected up front; the scan would say every
				-- trigger both starts and ends with it, which is true and useless.
				helpers.assert_true(ge == false and gp == false and gs == false,
					"the empty query must be rejected, not answered")
			else
				helpers.assert_true(ge == we and gp == wp and gs == ws, string.format(
					"query %q: index says (%s,%s,%s), the scan says (%s,%s,%s) — the index "
						.. "must narrow the search, never change the answer",
					q, tostring(ge), tostring(gp), tostring(gs),
					tostring(we), tostring(wp), tostring(ws)))
			end
			checked = checked + 1
		end
		helpers.assert_true(checked == #QUERIES,
			"every query must be compared — a loop that asserts nothing passes for free")
	end)

	helpers.it("gives the same answers before the first sort", function()
		-- The indexes are built by sort_mappings. Between an M.add and the next
		-- sort there is nothing to read, and the first version of this optimisation
		-- answered "no" to everything in that window.
		local R = registry_with(CORPUS, false)
		for _, q in ipairs(QUERIES) do
			if q ~= "" then
				local we, wp, ws = scan(CORPUS, q)
				local ge, gp, gs = R.classify_trigger(q)
				helpers.assert_true(ge == we and gp == wp and gs == ws, string.format(
					"query %q answered differently with no index built yet — classify_trigger "
						.. "must not depend on something having sorted first", q))
			end
		end
	end)

	helpers.it("still answers after the corpus grows", function()
		-- The memo is dropped by sort_mappings, which is also what rebuilds the
		-- indexes. A memo that outlived a re-registration would answer for a corpus
		-- that no longer exists.
		local R = registry_with({ "btw" }, true)
		local before_e = R.classify_trigger("btwx")
		helpers.assert_true(before_e == false, "'btwx' is not yet a trigger")

		R.add("btwx", "xbtwx", { is_case_sensitive = true, is_case_sensitive_strict = true, auto_expand = true })
		R.sort_mappings()
		local e, p, s = R.classify_trigger("btwx")
		helpers.assert_true(e, "'btwx' must be exact once registered — a stale memo says otherwise")
		helpers.assert_true(p, "'btwx' is a prefix of itself")
		helpers.assert_true(s, "'btwx' is a suffix of itself")
	end)

end)
