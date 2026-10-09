--- tests/unit/meta/test_corpus_dynamic_hotstrings_prefix.lua

--- ==============================================================================
--- MODULE: Dynamic Hotstrings Prefix Corpus Consumer (Hammerspoon)
--- DESCRIPTION:
--- Loads the shared cross-driver corpus from
--- _shared/tests/corpus/dynamic_hotstrings/prefix_vectors.json and validates
--- it against the shared reference implementation itself
--- (_shared/lua/dynamic_hotstrings/init.lua) — the same module macOS's
--- rules_engine.lua delegates to at runtime. Pinning the corpus against the
--- reference (rather than a driver-local reimplementation) proves the corpus
--- itself is correct; the AHK half in
--- windows/tests/meta/test_corpus_dynamic_hotstrings_prefix.ahk pins its own
--- reimplementation (CountDynamicSection) against the same corpus.
--- ==============================================================================

local helpers = require("tests.helpers")
local DynamicHotstrings = require("dynamic_hotstrings")




-- ========================================
-- ========================================
-- ======= 1/ Corpus file loading =========
-- ========================================
-- ========================================

local corpus_path = helpers.shared("tests/corpus/dynamic_hotstrings/prefix_vectors.json")

local function read_corpus()
	local fh = io.open(corpus_path, "r")
	if not fh then
		return nil, "cannot open corpus at " .. corpus_path
	end
	local raw = fh:read("*a")
	fh:close()
	local ok, corpus = pcall(hs.json.decode, raw)
	if not ok then return nil, "JSON parse error: " .. tostring(corpus) end
	return corpus, nil
end

local corpus, corpus_err = read_corpus()




-- ============================================
-- ============================================
-- ======= 2/ Corpus integrity ================
-- ============================================
-- ============================================

helpers.describe("dynamic hotstrings prefix corpus (macOS): shared reference matches every vector", function()
	helpers.it("corpus file is readable and parseable", function()
		helpers.assert_true(corpus ~= nil, corpus_err or "corpus must parse")
		helpers.assert_true(type(corpus.prefix_count_vectors) == "table" and #corpus.prefix_count_vectors > 0,
			"corpus must contain at least one prefix_count_vector")
		helpers.assert_true(type(corpus.spaced_prefix_vectors) == "table" and #corpus.spaced_prefix_vectors > 0,
			"corpus must contain at least one spaced_prefix_vector")
	end)




	-- ============================================
	-- ======= 3/ compute_prefix_counts parity =====
	-- ============================================

	helpers.it("compute_prefix_counts matches every prefix_count_vector", function()
		if not corpus then return end
		for _, v in ipairs(corpus.prefix_count_vectors) do
			local result = DynamicHotstrings.compute_prefix_counts(v.phone, v.fphone, v.ssn_raw, v.iban_raw)
			helpers.assert_eq(result.phoneprefixes, v.expected.phoneprefixes,
				"[" .. v.id .. "] phoneprefixes")
			helpers.assert_eq(result.ssnprefixes, v.expected.ssnprefixes,
				"[" .. v.id .. "] ssnprefixes")
			helpers.assert_eq(result.ibanprefixes, v.expected.ibanprefixes,
				"[" .. v.id .. "] ibanprefixes")
		end
	end)




	-- ============================================
	-- ======= 4/ spaced_prefix parity =============
	-- ============================================

	helpers.it("spaced_prefix matches every spaced_prefix_vector", function()
		if not corpus then return end
		for _, v in ipairs(corpus.spaced_prefix_vectors) do
			local result = DynamicHotstrings.spaced_prefix(v.spaced, v.raw_count)
			helpers.assert_eq(result, v.expected, "[" .. v.id .. "] spaced_prefix")
		end
	end)
end)
