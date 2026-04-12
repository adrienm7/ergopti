--- tests/test_parser.lua

--- ==============================================================================
--- MODULE: Parser Unit Tests
--- DESCRIPTION:
--- Validates the fully decoupled 2-tier semantic parser to ensure
--- accurate NW extraction, correct anchor words, and absolute safety limits.
--- ==============================================================================

local parser = require("modules.llm.parser")

--- Dummy mock for settings required by the parser
_G.hs = {
	settings = { get = function(k) return (k == "llm_min_words" and 1 or 5) end },
}
package.loaded["modules.llm.init"] = { DEFAULT_STATE = { llm_min_words = 1, llm_max_words = 5 } }

--- Formats the diff chunks into a readable string for testing assertions.
--- @param chunks table The array of chunk objects.
--- @return string A concatenated representation of the diff.
local function format_chunks(chunks)
	local result = ""
	if not chunks then return result end
	for _, c in ipairs(chunks) do
		local mark = (c.type == "equal") and "=" or "+"
		result = result .. string.format("[%s:%s]", mark, c.text)
	end
	return result
end

--- Mock test runner block structure
local function format_llm_block(tc, nw)
	return string.format("TAIL_CORRECTED: %s\nNEXT_WORDS: %s\n", tc, nw)
end





-- ==============================
-- ==============================
-- ======= 1/ Test Runner =======
-- ==============================
-- ==============================

local function run_tests()
	print("🚀 Starting Parser End-to-End Tests...\n")
	local passed = 0
	local failed = 0

	local tests = {
		{
			name = "Duplication bug ('est un homme' -> perfectly appended)",
			orig = "Charles de Gaulle est un homme important de l'histoire",
			tc = "est un homme important de l'histoire",
			nw = "qui laisse une trace",
			expected_chunks = "",
			expected_nw = " qui laisse une trace",
			expected_deletes = 0
		},
		{
			name = "Intra-word typing correction (étati -> était le)",
			orig = "étati",
			tc = "était",
			nw = "le général",
			expected_chunks = "[=:éta][+:it]",
			expected_nw = " le général",
			expected_deletes = 2 -- "ti"
		},
		{
			name = "Intra-word with context (étais -> était un personnage)",
			orig = "Charles de Gaulle étais",
			tc = "Charles de Gaulle était",
			nw = "un personnage",
			expected_chunks = "[=:étai][+:t]",
			expected_nw = " un personnage",
			expected_deletes = 1 -- "s"
		},
		{
			name = "Complete word replacement (jamais vu -> jamais su)",
			orig = "j'ai jamais vu",
			tc = "j'ai jamais su",
			nw = "en fait",
			expected_chunks = "[=:jamais ][+:su]",
			expected_nw = " en fait",
			expected_deletes = 2 -- "vu"
		},
		{
			name = "Typographic apostrophe & NFD handling (e + ´)",
			orig = "truc e\204\129tait bidule",
			tc = "truc était bidule",
			nw = "suite",
			expected_chunks = "",
			expected_nw = " suite",
			expected_deletes = 0 -- Perfect NFC match after normalization
		},
		{
			name = "Strict Extraction (New words are ONLY orange)",
			orig = "le chien",
			tc = "le chien",
			nw = "noir et blanc",
			expected_chunks = "",
			expected_nw = " noir et blanc",
			expected_deletes = 0
		},
		{
			name = "Replacement with invented word (chiens -> chien noir)",
			orig = "le chiens",
			tc = "le chien",
			nw = "noir",
			expected_chunks = "[=:le ][+:chien]",
			expected_nw = " noir",
			expected_deletes = 6 -- "chiens"
		}
	}

	for _, t in ipairs(tests) do
		local norm_orig = t.orig:gsub("'", "’")
		local block = format_llm_block(t.tc, t.nw)
		
		local res = parser.process_prediction(norm_orig, norm_orig, block)
		
		if not res then
			print(string.format("❌ FAIL: %s (returned nil)", t.name))
			failed = failed + 1
		else
			local res_chunks = format_chunks(res.chunks)
			local res_nw = res.nw
			local res_del = res.deletes

			if res_chunks == t.expected_chunks and res_nw == t.expected_nw and res_del == t.expected_deletes then
				print(string.format("✅ PASS: %s", t.name))
				passed = passed + 1
			else
				print(string.format("❌ FAIL: %s", t.name))
				if res_chunks ~= t.expected_chunks then print(string.format("   Chunks Exp: '%s' | Got: '%s'", t.expected_chunks, res_chunks)) end
				if res_nw ~= t.expected_nw then print(string.format("   NW Exp: '%s' | Got: '%s'", t.expected_nw, res_nw)) end
				if res_del ~= t.expected_deletes then print(string.format("   Del Exp: %d | Got: %d", t.expected_deletes, res_del)) end
				failed = failed + 1
			end
		end
	end

	print(string.format("\n🏁 Tests finished: %d passed, %d failed.", passed, failed))
end

run_tests()
