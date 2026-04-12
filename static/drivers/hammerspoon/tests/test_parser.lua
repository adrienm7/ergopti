--- tests/test_parser.lua

--- ==============================================================================
--- MODULE: Parser Unit Tests
--- DESCRIPTION:
--- Validates the behavior of the weighted Wagner-Fischer diffing engine to ensure
--- spaces are correctly penalized and fragments are avoided.
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

--- ==============================
--- ==============================
--- ======= 1/ Test Runner =======
--- ==============================
--- ==============================

local function run_tests()
	print("🚀 Starting Weighted Diff tests...\n")
	local passed = 0
	local failed = 0

	local tests = {
		{
			name = "Simple substitution (no fragmentation)",
			orig = "étais",
			corr = "était",
			expected = "[=:étai][+:t]"
		},
		{
			name = "Word alignment test (Charles de Gaulle)",
			orig = "Charles de Gaulle étais le plus",
			corr = "Charles de Gaulle était le plus",
			expected = "[=:Charles de Gaulle étai][+:t][=: le plus]"
		},
		{
			name = "Sentence completely changed",
			orig = "jamais vu",
			corr = "jamais su",
			expected = "[=:jamais ][+:s][=:u]"
		},
		{
			name = "Apostrophe substitution",
			orig = "j'aime",
			corr = "j'adore",
			expected = "[=:j'][+:adore]"
		}
	}

	for _, t in ipairs(tests) do
		local chunks = parser.weighted_diff(t.orig, t.corr)
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
