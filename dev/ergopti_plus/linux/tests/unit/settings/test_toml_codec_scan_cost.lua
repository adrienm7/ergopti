--- tests/unit/settings/test_toml_codec_scan_cost.lua

--- ==============================================================================
--- MODULE: TOML Codec Scan Cost
--- DESCRIPTION:
--- The decoder's lexical scanners (comment stripping, top-level comma splitting,
--- continuation depth, trimming) used to slice one character at a time, which
--- made decoding the 39 KB migration registry take ~100 ms on every boot. They
--- now copy runs of characters no state reacts to in one slice. Each cost case
--- counts string operations, not wall-clock, so it holds on a loaded machine,
--- and runs its input at two run lengths: the count must not change when only
--- the length doubles. A fixed ceiling chose a number; the doubling states the
--- claim. The semantic cases pin that the shortcuts change no result.
--- ==============================================================================

local helpers = require("tests.helpers")
local codec = require("core.text.engine.toml_codec")
local scanner = require("core.text.engine.toml_codec.record_scanner")

--- Counts calls of `string[name]` while `body` runs.
--- @param name string The string function counted, such as "sub".
--- @param body function
--- @return integer calls, any result
local function count_string_calls(name, body)
	local original, calls = string[name], 0
	string[name] = function(...) calls = calls + 1; return original(...) end
	local ok, result = pcall(body)
	string[name] = original
	if not ok then error(result, 0) end
	return calls, result
end

--- Asserts that a scan costs the same at two run lengths: `run(length)` must
--- make as many counted calls as `run(2 * length)`. A scan that works one
--- character at a time doubles its count instead.
--- @param name string The string function counted.
--- @param run function The scan over runs of `length` characters; returns its result.
--- @param check function Asserts the result of one run, given its length.
--- @param length integer The shorter run length.
--- @param label string The scan, for the failure message.
local function assert_length_independent(name, run, check, length, label)
	local short, short_result = count_string_calls(name, function() return run(length) end)
	local long, long_result = count_string_calls(name, function() return run(2 * length) end)
	check(short_result, length)
	check(long_result, 2 * length)
	helpers.assert_true(short > 0, label .. ": no string." .. name .. " call was seen, so nothing was measured")
	helpers.assert_eq(long, short,
		label .. " grew with run length: " .. short .. " then " .. long .. " string." .. name .. " calls")
end

helpers.describe("toml codec scanners: cost is bounded by structure, not length", function()
	helpers.it("decodes a long plain array element with the same slices at any length", function()
		assert_length_independent("sub", function(length)
			local plain = string.rep("a", length)
			return codec.decode('list = ["' .. plain .. '", "' .. plain .. '"]\n')
		end, function(decoded, length)
			helpers.assert_eq(decoded.list[1], string.rep("a", length))
		end, 5000, "decode")
	end)

	helpers.it("strips a comment only outside strings, at any plain run length", function()
		assert_length_independent("sub", function(length)
			return codec.strip_inline_comment('name = "' .. string.rep("x", length) .. '#kept" # dropped')
		end, function(stripped, length)
			helpers.assert_eq(stripped, 'name = "' .. string.rep("x", length) .. '#kept" ')
		end, 2000, "strip_inline_comment")
	end)

	helpers.it("advances nesting depth over a long line in the same steps at any length", function()
		assert_length_independent("sub", function(length)
			local plain = string.rep("y", length)
			return scanner.advance("[" .. plain .. "[" .. plain, 0, nil)
		end, function(depth)
			helpers.assert_eq(depth, 2)
		end, 3000, "advance")
	end)
end)

helpers.describe("toml reader and string decoding: cost is bounded by structure", function()
	helpers.it("parses a long hotstring entry line with the same slices at any length", function()
		local reader = require("core.text.engine.toml_codec.reader")
		assert_length_independent("sub", function(length)
			local trigger, output = string.rep("t", length), string.rep("o", length)
			return reader.parse_text('[ok]\n"' .. trigger .. '" = { output = "' .. output .. '", is_word = true }\n')
		end, function(parsed, length)
			local entries = parsed.sections.ok.entries
			helpers.assert_eq(entries[1].trigger, string.rep("t", length))
			helpers.assert_eq(entries[1].output, string.rep("o", length))
			helpers.assert_true(entries[1].is_word)
		end, 800, "reader")
	end)

	helpers.it("decodes a plain basic string without a pass over its bytes", function()
		local basic = require("core.text.engine.toml_codec.basic_string")
		-- An escaped body takes the byte pass, so the counter is seen to reach
		-- the decoder; a plain body must then cost the same at both lengths.
		local escaped = count_string_calls("char", function() return basic.unescape_body("a\\u0041") end)
		helpers.assert_true(escaped > 0, "unescape_body: no string.char call was seen on an escape, so nothing is measured")
		local short, short_decoded = count_string_calls("char", function()
			return basic.unescape_body(string.rep("plain text ", 400))
		end)
		local long, long_decoded = count_string_calls("char", function()
			return basic.unescape_body(string.rep("plain text ", 800))
		end)
		helpers.assert_eq(short_decoded, string.rep("plain text ", 400))
		helpers.assert_eq(long_decoded, string.rep("plain text ", 800))
		helpers.assert_eq(long, short, "plain body was rebuilt byte by byte: " .. short .. " then " .. long .. " string.char calls")
	end)

	helpers.it("still rejects raw controls, a bare quote and a bad escape", function()
		local basic = require("core.text.engine.toml_codec.basic_string")
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
