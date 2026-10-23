--- tests/unit/infra/config/test_toml_codec_scan_cost.lua

--- ==============================================================================
--- MODULE: TOML Codec Scan Cost
--- DESCRIPTION:
--- The decoder's lexical scanners (comment stripping, top-level comma splitting,
--- continuation depth, trimming) used to slice one character at a time, which
--- made decoding the 39 KB migration registry take ~100 ms on every boot. They
--- now copy runs of characters no state reacts to in one slice. The counts below
--- are counted string operations, not wall-clock, so they hold on a loaded
--- machine; the semantic cases pin that the shortcuts change no result.
--- ==============================================================================

local helpers = require("tests.helpers")
local codec = require("toml_codec")
local scanner = require("toml_codec.record_scanner")

--- Counts string.sub calls (the per-character allocation) while `body` runs.
--- @param body function
--- @return integer calls, any result
local function count_sub_calls(body)
	local original, calls = string.sub, 0
	string.sub = function(...) calls = calls + 1; return original(...) end
	local ok, result = pcall(body)
	string.sub = original
	if not ok then error(result, 0) end
	return calls, result
end

helpers.describe("toml codec scanners: cost is bounded by structure, not length", function()
	helpers.it("decodes a long plain array element with a handful of slices", function()
		local plain = string.rep("abcdefghij", 500)
		local document = 'list = ["' .. plain .. '", "' .. plain .. '"]\n'
		local calls, decoded = count_sub_calls(function() return codec.decode(document) end)
		helpers.assert_eq(decoded.list[1], plain)
		-- One slice per character cost over 10 000 calls here.
		helpers.assert_true(calls < 400, "decode sliced per character: " .. calls .. " sub calls")
	end)

	helpers.it("strips a comment only outside strings, over long plain runs", function()
		local plain = string.rep("x", 2000)
		local calls, stripped = count_sub_calls(function()
			return codec.strip_inline_comment('name = "' .. plain .. '#kept" # dropped')
		end)
		helpers.assert_eq(stripped, 'name = "' .. plain .. '#kept" ')
		helpers.assert_true(calls < 100, "strip_inline_comment sliced per character: " .. calls)
	end)

	helpers.it("advances nesting depth over a long line in few steps", function()
		local plain = string.rep("y", 3000)
		local calls, depth = count_sub_calls(function()
			local result = scanner.advance("[" .. plain .. "[" .. plain, 0, nil)
			return result
		end)
		helpers.assert_eq(depth, 2)
		helpers.assert_true(calls < 100, "advance sliced per character: " .. calls)
	end)
end)

helpers.describe("toml reader and string decoding: cost is bounded by structure", function()
	helpers.it("parses a long hotstring entry line with a handful of slices", function()
		local reader = require("toml_codec.reader")
		local trigger, output = string.rep("t", 800), string.rep("o", 800)
		local document = '[ok]\n"' .. trigger .. '" = { output = "' .. output .. '", is_word = true }\n'
		local calls, parsed = count_sub_calls(function() return reader.parse_text(document) end)
		local entries = parsed.sections.ok.entries
		helpers.assert_eq(entries[1].trigger, trigger)
		helpers.assert_eq(entries[1].output, output)
		helpers.assert_true(entries[1].is_word)
		helpers.assert_true(calls < 600, "reader sliced per character: " .. calls .. " sub calls")
	end)

	helpers.it("decodes a plain basic string without a pass over its bytes", function()
		local basic = require("toml_codec.basic_string")
		local original, chars = string.char, 0
		string.char = function(...) chars = chars + 1; return original(...) end
		local ok, decoded = pcall(basic.unescape_body, string.rep("plain text ", 400))
		string.char = original
		helpers.assert_true(ok)
		helpers.assert_eq(decoded, string.rep("plain text ", 400))
		helpers.assert_true(chars < 10, "plain body was rebuilt byte by byte: " .. chars .. " string.char calls")
	end)

	helpers.it("still rejects raw controls, a bare quote and a bad escape", function()
		local basic = require("toml_codec.basic_string")
		helpers.assert_nil(basic.unescape_body("a\1b"))
		helpers.assert_nil(basic.unescape_body("a\127b"))
		helpers.assert_nil(basic.unescape_body("a\0b"))
		helpers.assert_nil(basic.unescape_body('a"b'))
		helpers.assert_nil(basic.unescape_body("a\\qb"))
		helpers.assert_nil(basic.unescape_body("a\nb"))
		helpers.assert_nil(basic.unescape_body("a\rb", true))
		helpers.assert_eq(basic.unescape_body("a\nb", true), "a\nb")
		helpers.assert_eq(basic.unescape_body('a"b', true), 'a"b')
		helpers.assert_eq(basic.unescape_body("a\tb"), "a\tb")
		helpers.assert_eq(basic.unescape_body("caf\195\169 \\u0041\\n"), "caf\195\169 A\n")
	end)
end)

helpers.describe("toml codec scanners: the shortcuts change no result", function()
	helpers.it("keeps delimiters inside strings out of the split", function()
		local decoded = codec.decode('a = ["x,y", \'p]q\', "z\\"w,v"]\nb = { k = "1,2", m = [1, 2] }\n')
		helpers.assert_eq(decoded.a, { "x,y", "p]q", 'z"w,v' })
		helpers.assert_eq(decoded.b.k, "1,2")
		helpers.assert_eq(decoded.b.m, { 1, 2 })
	end)

	helpers.it("keeps hashes inside every string form and drops the real comment", function()
		helpers.assert_eq(codec.strip_inline_comment("a = 'x#y' # c"), "a = 'x#y' ")
		helpers.assert_eq(codec.strip_inline_comment('a = "x#y\\"#z" # c'), 'a = "x#y\\"#z" ')
		helpers.assert_eq(codec.strip_inline_comment("a = 1"), "a = 1")
	end)

	helpers.it("trims every kind of surrounding whitespace and nothing inside", function()
		local decoded = codec.decode("a =   \t  value with  spaces \t  \nb =  \"  kept  \"  \n")
		helpers.assert_eq(decoded.a, "value with  spaces")
		helpers.assert_eq(decoded.b, "  kept  ")
	end)

	helpers.it("tracks multiline string state across lines", function()
		local depth, quote = scanner.advance('x = """open [', 0, nil)
		helpers.assert_eq(depth, 0)
		helpers.assert_eq(quote, '"""')
		depth, quote = scanner.advance('still [ inside \\" """ ]', depth, quote)
		helpers.assert_nil(quote)
		helpers.assert_eq(depth, 0)
	end)
end)
