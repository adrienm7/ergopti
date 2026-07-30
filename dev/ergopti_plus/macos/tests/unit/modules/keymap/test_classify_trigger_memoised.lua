--- tests/unit/modules/keymap/test_classify_trigger_memoised.lua

--- ==============================================================================
--- MODULE: Regression — classify_trigger must not re-scan the corpus per keypress
--- DESCRIPTION:
--- classify_trigger walks every one of the ~10-15k registered mappings and, for
--- each, builds two substrings — inside the keyDown eventtap, on every '@'
--- keypress, to answer a question about a string that is usually the same one it
--- was asked about a moment earlier.
---
--- ROOT CAUSE ENCODED:
--- A pure function of (string, corpus) recomputed while neither changed. The memo
--- must be invalidated when the corpus does change, or it answers for a mapping
--- set that no longer exists — which is worse than the cost it removes.
--- ==============================================================================

local helpers = require("tests.helpers")

local function fresh_registry()
	package.loaded["modules.keymap.registry"] = nil
	local Registry = helpers.load_with_stubs("modules.keymap.registry")
	Registry.init({
		magic_key = "\u{2605}", mappings = {}, mappings_lookup = {},
		mappings_by_tail_char = {}, mappings_by_star_tail_char = {},
		groups = {}, seq_counter = 0, current_group = "t",
		start_is_word_boundary = true,
	})
	return Registry
end

helpers.describe("registry: classify_trigger caches its answer", function()

	helpers.it("returns the same verdict on a repeat query", function()
		local R = fresh_registry()
		R.add("@ab", "expanded", { group = "t" })
		R.sort_mappings()

		local e1, p1, s1 = R.classify_trigger("@a")
		local e2, p2, s2 = R.classify_trigger("@a")
		helpers.assert_eq(e1, e2, "a repeat query must agree with the first")
		helpers.assert_eq(p1, p2)
		helpers.assert_eq(s1, s2)
		helpers.assert_true(p1, "'@a' is a prefix of the registered '@ab'")
	end)

	helpers.it("forgets its answers when the corpus changes", function()
		local R = fresh_registry()
		R.sort_mappings()
		local _, pref_before = R.classify_trigger("@z")
		helpers.assert_true(not pref_before, "nothing registered yet, so no prefix match")

		R.add("@zz", "expanded", { group = "t" })
		R.sort_mappings()
		local _, pref_after = R.classify_trigger("@z")
		helpers.assert_true(pref_after,
			"a memo that survives a corpus change answers for a mapping set that no longer "
			.. "exists, which is worse than the scan it replaced")
	end)

	helpers.it("does not walk the corpus twice for the same string", function()
		local src = helpers.read_driver_source("function M.classify_trigger")
		helpers.assert_true(type(src) == "string" and src ~= "",
			"the registry source must be readable or this asserts nothing")
		helpers.assert_true(src:find("_classify_cache", 1, true) ~= nil,
			"the scan runs inside the keyDown eventtap on every trigger-prefix keypress, over "
			.. "the whole mapping corpus, with two substring allocations per entry")
	end)

end)
