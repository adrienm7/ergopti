--- tests/test_parser.lua

--- ==============================================================================
--- MODULE: Parser Unit Tests
--- DESCRIPTION:
--- Validates the smart 2-tier semantic diffing engine to ensure
--- character-level corrections are cleanly extracted and new words separated.
--- ==============================================================================

local parser = require("modules.llm.parser")

--- Formats the diff chunks into a readable string for testing assertions.
--- @param chunks table The array of chunk objects.
--- @return string A concatenated representation of the diff.
local function format_chunks(chunks)
	local result = ""
	for _, c in ipairs(chunks) do
		local mark = (c.type == "equal") and "=" or "+"
		result = result .. string.format("[%s:%s]", mark, c.text)
	end
	return result
end





-- ==============================
-- ==============================
-- ======= 1/ Test Runner =======
-- ==============================
-- ==============================

local function run_tests()
	print("🚀 Starting 2-Tier Smart Diff tests...\n")
	local passed = 0
	local failed = 0

	local tests = {
		{
			name = "Intra-word typing correction with trailing nw (étati -> était le)",
			orig = "étati",
			corr = "était le",
			expected_chunks = "[=:éta][+:it]",
			expected_nw = " le"
		},
		{
			name = "Intra-word correction (étais -> était)",
			orig = "Charles de Gaulle étais",
			corr = "Charles de Gaulle était un personnage",
			expected_chunks = "[=:Charles de Gaulle étai][+:t]",
			expected_nw = " un personnage"
		},
		{
			name = "Sentence completely changed (jamais vu -> jamais su)",
			orig = "j'ai jamais vu",
			corr = "j'ai jamais su en fait",
			expected_chunks = "[=:j'ai jamais ][+:su]",
			expected_nw = " en fait"
		},
		{
			name = "Mid-word substitution (personage -> personnage)",
			orig = "un personage",
			corr = "un personnage important",
			expected_chunks = "[=:un person][+:n][=:age]",
			expected_nw = " important"
		},
		{
			name = "Typographic apostrophe substitution with NFD handling simulation",
			orig = "j'aime",
			corr = "j'adore les chats",
			expected_chunks = "[=:j'][+:adore]",
			expected_nw = " les chats"
		},
		{
			name = "NFD Normalization test (Decomposed é vs Composed é)",
			orig = "truc e\204\129tait bidule",
			corr = "truc était bidule suite",
			expected_chunks = "[=:truc était bidule]",
			expected_nw = " suite"
		}
	}

	for _, t in ipairs(tests) do
		local chunks, nw = parser.smart_diff(t.orig, t.corr)
		local res_chunks = format_chunks(chunks)

		if res_chunks == t.expected_chunks and nw == t.expected_nw then
			print(string.format("✅ PASS: %s", t.name))
			passed = passed + 1
		else
			print(string.format("❌ FAIL: %s", t.name))
			if res_chunks ~= t.expected_chunks then
				print(string.format("   Chunks Exp: %s", t.expected_chunks))
				print(string.format("   Chunks Got: %s", res_chunks))
			end
			if nw ~= t.expected_nw then
				print(string.format("   NW Expected: '%s'", t.expected_nw))
				print(string.format("   NW Got:      '%s'", nw))
			end
			failed = failed + 1
		end
	end

	print(string.format("\n🏁 Tests finished: %d passed, %d failed.", passed, failed))
end

run_tests()
