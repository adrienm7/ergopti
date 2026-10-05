--- tests/unit/meta/test_text_utils_byte_prefix.lua

--- ==============================================================================
--- MODULE: Shared UTF-8 Byte Prefix Contract
--- DESCRIPTION:
--- Valid scalar boundaries preserve the byte ceiling and maximal complete text.
--- Malformed source cases explicitly retain their previous raw byte prefixes.
--- These pure helper tests do not claim native transport or physical validation.
--- ==============================================================================

local helpers = require("tests.helpers")
local TextUtils = require("text_utils")
local Utf8 = require("compat.utf8")

helpers.describe("Shared UTF-8 byte prefix", function()
	helpers.it("retains ASCII short empty and exact-boundary bytes", function()
		for _, row in ipairs({ { "", 0, "" }, { "ascii", 0, "" }, { "ascii", 3, "asc" },
			{ "ascii", 5, "ascii" }, { "ascii", 20, "ascii" }, { "ascii", 1e100, "ascii" }, { "é", 2, "é" }, { "漢", 3, "漢" },
			{ "😀", 4, "😀" }, { "xé", 3, "xé" } }) do
			helpers.assert_eq(TextUtils.utf8_byte_prefix(row[1], row[2]), row[3])
		end
	end)

	helpers.it("repairs every partial boundary within a valid scalar", function()
		for _, glyph in ipairs({ "é", "漢", "😀" }) do
			for bytes = 1, #glyph - 1 do
				helpers.assert_eq(TextUtils.utf8_byte_prefix(glyph .. "tail", bytes), "")
				local before = string.rep("a", 200 - bytes)
				helpers.assert_eq(TextUtils.utf8_byte_prefix(before .. glyph .. "tail", 200), before)
			end
		end
	end)

	helpers.it("returns the independently declared maximal prefix for each mixed-text budget", function()
		local source = "aé漢😀z"
		local expected = { "", "a", "a", "aé", "aé", "aé", "aé漢", "aé漢", "aé漢", "aé漢", "aé漢😀", "aé漢😀z" }
		for budget = 0, #source do
			local actual = TextUtils.utf8_byte_prefix(source, budget)
			helpers.assert_eq(actual, expected[budget + 1])
			helpers.assert_true(#actual <= budget)
			helpers.assert_true(Utf8.len(actual) ~= nil)
		end
	end)

	helpers.it("preserves pre-existing malformed-source raw prefixes before and after the budget", function()
		for _, source in ipairs({ "a\255tail", "a\128tail", "a\192\175tail", "a\237\160\128tail",
			"a\244\144\128\128tail", "a\240\159", string.rep("a", 199) .. "é" .. "\255",
			string.rep("a", 201) .. "\255", "é" .. "\255" }) do
			helpers.assert_nil(Utf8.len(source))
			for _, budget in ipairs({ 0, 1, 2, 3, 4, 200, 999 }) do
				helpers.assert_eq(TextUtils.utf8_byte_prefix(source, budget), source:sub(1, budget))
			end
		end
	end)

	helpers.it("retains NUL and escaped-control codepoints as complete bytes", function()
		helpers.assert_eq(TextUtils.utf8_byte_prefix("a\0b\né", 4), "a\0b\n")
		helpers.assert_eq(TextUtils.utf8_byte_prefix("a\0b\né", 5), "a\0b\n")
	end)

	helpers.it("refuses invalid internal argument contracts", function()
		for _, value in ipairs({ false, 7, {}, function() end }) do
			helpers.assert_throws(function() TextUtils.utf8_byte_prefix(value, 200) end)
		end
		helpers.assert_throws(function() TextUtils.utf8_byte_prefix(nil, 200) end)
		for _, budget in ipairs({ -1, 0.5, "200", false, {}, math.huge, -math.huge, 0 / 0 }) do
			helpers.assert_throws(function() TextUtils.utf8_byte_prefix("valid", budget) end)
		end
		helpers.assert_throws(function() TextUtils.utf8_byte_prefix("valid", nil) end)
	end)
end)
