--- tests/unit/modules/keylogger/test_unicode_character_classes.lua

--- ==============================================================================
--- MODULE: Shared Unicode Character Class Admission (Linux)
--- DESCRIPTION:
--- The native metrics walker must use the existing shared coarse character policy.
--- Literal codepoint cases protect counts without redefining Unicode categories.
--- ==============================================================================

local helpers = require("tests.helpers")
local it = require("tests.support.metrics_preferences_fixture").it
local Walker = helpers.load_module("modules.keylogger.aggregate_walker")

helpers.describe("linux-unicode-character-classes", function()
	local cases = {
		{ "ASCII and newline", "A1! \n", { 1, 1, 1, 2, 0 } },
		{ "accented multibyte letters", "éĀ", { 2, 0, 0, 0, 0 } },
		{ "Han character", "中", { 0, 0, 0, 0, 1 } },
		{ "non-BMP emoji", "🙂", { 0, 0, 0, 0, 1 } },
		{ "Unicode spaces and newline", "\194\160\226\128\175\n", { 0, 0, 0, 3, 0 } },
		{ "combining mark under existing coarse policy", "é", { 2, 0, 0, 0, 0 } },
	}
	for _, case in ipairs(cases) do
		it("linux-unicode-character-classes: " .. case[1], function()
			local events = {}
			for _, codepoint in utf8.codes(case[2]) do
				events[#events + 1] = { utf8.char(codepoint), 100, {} }
			end
			local batch = Walker.walk(events, "2026-10-05", "owned-unicode")
			local row = batch.chars_class["2026-10-05\1owned-unicode"]
			local total = 0
			for index, field in ipairs({ "letter", "digit", "punct", "space", "other" }) do
				helpers.assert_eq(row[field], case[3][index], "shared literal class " .. field)
				total = total + row[field]
			end
			helpers.assert_eq(total, #events, "each supplied Unicode codepoint counts once")
			local emitted = Walker.daily_rows(batch).chars_class
			helpers.assert_eq(#emitted, 1)
			for index, field in ipairs({ "letter", "digit", "punct", "space", "other" }) do
				helpers.assert_eq(emitted[1][field], case[3][index])
			end
		end)
	end
	for _, source in ipairs({ "llm", "clipboard" }) do
		it("linux-unicode-character-classes: " .. source .. " output remains excluded from manual classes", function()
			local events = {}
			for _, codepoint in utf8.codes("é中🙂\194\160\n") do
				events[#events + 1] = { utf8.char(codepoint), 0, { s = 1, st = source } }
			end
			local batch = Walker.walk(events, "2026-10-05", "owned-synthetic")
			local row = batch.chars_class["2026-10-05\1owned-synthetic"]
			for _, field in ipairs({ "letter", "digit", "punct", "space", "other" }) do
				helpers.assert_eq(row[field], 0)
			end
			local rows = batch.ngram.ngram_chars
			helpers.assert_eq(rows["2026-10-05\1owned-synthetic\1🙂"].c, 1)
			helpers.assert_eq(rows["2026-10-05\1owned-synthetic\1🙂"].esrc[source], 1)
		end)
	end
end)

helpers.describe("linux-unicode-character-controls", function()
	it("linux-unicode-character-controls: coarse CR/VT/FF classes preserve tab and LF spaces", function()
		local events = {
			{ "\r", 100, {} },
			{ "\11", 100, {} },
			{ "\12", 100, {} },
			{ "\t", 100, {} },
			{ "\n", 100, {} },
		}
		local batch = Walker.walk(events, "2026-10-05", "owned-controls")
		local row = batch.chars_class["2026-10-05\1owned-controls"]
		helpers.assert_eq(row.letter, 0)
		helpers.assert_eq(row.digit, 0)
		helpers.assert_eq(row.punct, 0)
		helpers.assert_eq(row.space, 2, "tab and LF retain their explicit space classification")
		helpers.assert_eq(row.other, 3, "CR, VT and FF follow the shared coarse other classification")
		helpers.assert_eq(row.space + row.other, #events, "all five supplied controls count once")
		local emitted = Walker.daily_rows(batch).chars_class
		helpers.assert_eq(#emitted, 1)
		helpers.assert_eq(emitted[1].space, 2)
		helpers.assert_eq(emitted[1].other, 3)
	end)
end)
