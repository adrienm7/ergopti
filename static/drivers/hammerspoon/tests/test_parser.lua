--- tests/test_parser.lua

--- ==============================================================================
--- MODULE: Parser Unit Tests
--- DESCRIPTION:
--- Validates the smart 2-tier semantic diffing engine to ensure
--- character-level corrections are constrained inside words correctly.
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
			name = "Intra-word typing correction (étati -> était)",
			orig = "étati",
			corr = "était",
			expected = "[=:éta][+:it]"
		},
		{
			name = "Intra-word correction (étais -> était)",
			orig = "Charles de Gaulle étais",
			corr = "Charles de Gaulle était",
			expected = "[=:Charles de Gaulle étai][+:t]"
		},
		{
			name = "Sentence completely changed (jamais vu -> jamais su)",
			orig = "j'ai jamais vu",
			corr = "j'ai jamais su",
			expected = "[=:j'ai jamais ][+:su]"
		},
		{
			name = "Mid-word substitution (personage -> personnage)",
			orig = "un personage important",
			corr = "un personnage important",
			expected = "[=:un person][+:n][=:age important]"
		},
		{
			name = "Grammar context (ceci -> cela)",
			orig = "je pense que ceci",
			corr = "je pense que cela",
			expected = "[=:je pense que c][+:el][=:a]"
		},
		{
			name = "Apostrophe substitution",
			orig = "j'aime",
			corr = "j'adore",
			expected = "[=:j'][+:adore]" 
		}
	}

	for _, t in ipairs(tests) do
		local chunks = parser.smart_diff(t.orig, t.corr)
		local result = format_chunks(chunks)

		if result == t.expected then
			print(string.format("✅ PASS: %s", t.name))
			passed = passed + 1
		else
			print(string.format("❌ FAIL: %s", t.name))
			print(string.format("   Expected: %s", t.expected))
			print(string.format("   Got:      %s", result))
			failed = failed + 1
		end
	end

	print(string.format("\n🏁 Tests finished: %d passed, %d failed.", passed, failed))
end

run_tests()
