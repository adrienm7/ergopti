--- tests/unit/infra/text_and_paths/test_text_utils_case_fast_path.lua

--- ==============================================================================
--- MODULE: text_utils Case Fold Fast Path Tests
--- DESCRIPTION:
--- trig_lower runs for every registered hotstring at boot (tail, first char,
--- folded trigger, case body) and for every typed tail on the per-key path. It
--- used one Lua callback per character through gsub, about 11 % of a warm
--- four-pack hotstring load under Lua 5.4 (measured). ASCII-only input now
--- folds through string.lower directly. These cases pin that the shortcut
--- takes no gsub pass and gives the exact per-codepoint result everywhere.
--- ==============================================================================

local helpers = require("tests.helpers")
local tu = helpers.load_with_stubs("infra.text_utils")

local CODEPOINT = "[%z\1-\127\194-\244][\128-\191]*"

--- The per-codepoint fold every input must keep producing.
--- @param s string Input.
--- @return string folded
local function reference_lower(s)
	return (s:gsub(CODEPOINT, function(c) return tu.LOWER_LETTERS[c] or string.lower(c) end))
end

--- The per-codepoint upper case every input must keep producing.
--- @param s string Input.
--- @return string raised
local function reference_upper(s)
	return (s:gsub(CODEPOINT, function(c) return tu.UPPER_LETTERS[c] or string.upper(c) end))
end

--- Counts string.gsub calls while `body` runs.
--- @param body function Work to observe.
--- @return number calls
local function count_gsub_calls(body)
	local original, calls = string.gsub, 0
	string.gsub = function(...) calls = calls + 1; return original(...) end
	local ok, failure = pcall(body)
	string.gsub = original
	if not ok then error(failure, 0) end
	return calls
end

local SAMPLES = {
	"", "abc", "ABC Def_12", "a\0B", "É", "ÉCOLE", "Ça Va", "ŒUVRE", "naïve ÆON",
	"x\128y", "\255Z", "日本語A", "pr★", " -> ★", "Ü\194",
}

helpers.describe("text_utils case folds on ASCII input", function()
	helpers.it("folds ASCII-only text without a gsub pass", function()
		local calls = count_gsub_calls(function()
			helpers.assert_eq(tu.trig_lower("Hello World_42"), "hello world_42")
			helpers.assert_eq(tu.repl_upper("Hello World_42"), "HELLO WORLD_42")
		end)
		helpers.assert_eq(calls, 0, "ASCII text must not take the per-codepoint callback")
	end)

	helpers.it("keeps the exact per-codepoint result for every input shape", function()
		for _, sample in ipairs(SAMPLES) do
			helpers.assert_eq(tu.trig_lower(sample), reference_lower(sample), "trig_lower " .. sample)
			helpers.assert_eq(tu.repl_upper(sample), reference_upper(sample), "repl_upper " .. sample)
		end
	end)
end)
