--- _shared/lua/test/text_helpers_contract.lua

--- ==============================================================================
--- MODULE: Text Helpers Contract
--- DESCRIPTION:
--- Pins text_utils.trim, text_utils.percent_encode and text_utils.shell_quote
--- to the inline copies they replace, on both Lua runners: the reference
--- functions below are those copies verbatim (shared-lua-helpers).
--- ==============================================================================

local M = {}

-- The inline spellings the drivers carried before the owner existed.
local INLINE_TRIMS = {
	match = function(s) return s:match("^%s*(.-)%s*$") end,
	gsub = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end,
	ascii_class = function(s) return (s:gsub("^[ \t\r\n\v\f]+", ""):gsub("[ \t\r\n\v\f]+$", "")) end,
	linear = function(s)
		local first = s:find("%S")
		if first == nil then return "" end
		local last = #s
		while s:find("^%s", last) do last = last - 1 end
		return s:sub(first, last)
	end,
}

local function inline_percent_encode(value)
	return (value:gsub("[^%w%-%._~]", function(ch) return string.format("%%%02X", ch:byte()) end))
end

local function inline_shell_quote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

-- Every whitespace byte of the %s class, alone and around text.
local TRIM_CORPUS = {
	"", " ", "\t", "\n", "\r\n", "\v\f", "   \t\n  ",
	"a", " a", "a ", " a ", "a b", "  a  b  ", "\ta\tb\t",
	"\v\fx\r\n", "x\0 ", " \0", "é ", " « guillemets » ",
	"line one\nline two\n", "trailing\r", "=", " = ",
}

-- Printable ASCII, a few controls and multibyte UTF-8.
local function percent_corpus()
	local ascii = {}
	for byte = 0, 127 do ascii[#ascii + 1] = string.char(byte) end
	return {
		"", table.concat(ascii), "AZaz09-._~", "a b&c=d?e#f/g",
		"!*'();:@&=+$,/?#[]", "100%", "é", "日本", "🙂", "\255\254",
	}
end

--- Registers the vectors in a driver suite.
--- @param helpers table Driver test API.
function M.register(helpers)
	local TextUtils = require("text_utils")

	helpers.describe("text_utils: trim, percent_encode and shell_quote own their idioms (shared-lua-helpers)", function()
		helpers.it("shared-lua-helpers: trim returns what every inline spelling returned", function()
			for _, text in ipairs(TRIM_CORPUS) do
				local trimmed = TextUtils.trim(text)
				for name, inline in pairs(INLINE_TRIMS) do
					helpers.assert_eq(trimmed, inline(text), name .. " trim of " .. string.format("%q", text))
				end
			end
		end)

		helpers.it("shared-lua-helpers: trim stays linear on a long value ending in spaces", function()
			local long = "x" .. string.rep(" ", 200000) .. "y" .. string.rep(" ", 200000)
			helpers.assert_eq(TextUtils.trim(long), long:sub(1, 200002))
		end)

		helpers.it("shared-lua-helpers: trim of a non-string raises like the method call it replaces", function()
			for _, value in ipairs({ false, 5, {} }) do
				local failure = helpers.assert_throws(function() TextUtils.trim(value) end)
				helpers.assert_contains(tostring(failure), "text_utils.trim expects a string, got " .. type(value))
			end
			local failure = helpers.assert_throws(function() TextUtils.trim(nil) end)
			helpers.assert_contains(tostring(failure), "text_utils.trim expects a string, got nil")
		end)

		helpers.it("shared-lua-helpers: percent_encode keeps only the unreserved set literal", function()
			for _, text in ipairs(percent_corpus()) do
				helpers.assert_eq(TextUtils.percent_encode(text), inline_percent_encode(text),
					"inline encoding of " .. string.format("%q", text))
			end
			helpers.assert_eq(TextUtils.percent_encode("!*'();:@&=+$,/?#[] "),
				"%21%2A%27%28%29%3B%3A%40%26%3D%2B%24%2C%2F%3F%23%5B%5D%20")
			helpers.assert_eq(TextUtils.percent_encode("AZaz09-._~"), "AZaz09-._~")
			helpers.assert_eq(TextUtils.percent_encode("100% é\0"), "100%25%20%C3%A9%00")
			helpers.assert_throws(function() TextUtils.percent_encode(nil) end, "nil is refused")
		end)

		helpers.it("shared-lua-helpers: shell_quote closes, escapes and reopens a single quote", function()
			for _, value in ipairs({ "", "plain", "it's", "''", "a'b'c", "$HOME `id` !x \\n", 42, "\n" }) do
				helpers.assert_eq(TextUtils.shell_quote(value), inline_shell_quote(value))
			end
			helpers.assert_eq(TextUtils.shell_quote("it's"), "'it'\\''s'")
			helpers.assert_eq(TextUtils.shell_quote(""), "''")
			helpers.assert_eq(TextUtils.shell_quote(nil), "'nil'", "tostring coercion, as documented")
		end)
	end)
end

return M
