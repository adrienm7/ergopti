--- tests/unit/lib/test_toml_codec_edge_cases.lua

--- ==============================================================================
--- MODULE: TOML Codec Edge-Case Regression Tests
--- DESCRIPTION:
--- Regression tests for three codec bugs fixed together:
---
--- 1. F26 — Single-quote literal string with '#' inside was truncated.
---    The inline-comment stripper only tracked double-quoted regions, so
---    key = 'hello # world' was seen as key = 'hello (missing closing quote)
---    and rejected with PARSE_ERROR. Fix: track single-quoted regions too.
---
--- 2. F28 — \UXXXXXXXX escape with codepoint > 0x10FFFF caused utf8.char to
---    throw, crashing the decode. Fix: clamp invalid codepoints to U+FFFD.
---
--- 3. F51 — TOML special float literals inf / -inf / nan were treated as bare
---    strings instead of numbers. Fix: match them before the number patterns.
--- ==============================================================================

local helpers = require("tests.helpers")
local codec   = helpers.load_with_stubs("lib.toml.codec")


-- =====================================================================
-- =====================================================================
-- ======= 1/ Single-quoted strings with '#' inside ====================
-- =====================================================================
-- =====================================================================

helpers.describe("toml_codec: single-quoted string with hash character", function()

	helpers.it("preserves '#' inside a literal string value", function()
		local src = 'key = \'hello # world\'\n'
		local got = codec.decode(src)
		helpers.assert_true(got ~= nil, "decode must succeed for literal string with '#'")
		helpers.assert_eq(got.key, "hello # world",
			"'#' inside single-quoted value must not be treated as comment delimiter")
	end)

	helpers.it("still strips trailing '#' comments outside quoted strings", function()
		local src = "key = 42 # this is a comment\n"
		local got = codec.decode(src)
		helpers.assert_true(got ~= nil)
		helpers.assert_eq(got.key, 42, "comment outside string must be stripped")
	end)

	helpers.it("double-quoted strings with '#' still work", function()
		local src = 'key = "hello # world"\n'
		local got = codec.decode(src)
		helpers.assert_true(got ~= nil)
		helpers.assert_eq(got.key, "hello # world")
	end)

end)


-- =====================================================================
-- =====================================================================
-- ======= 2/ \U codepoint range validation ============================
-- =====================================================================
-- =====================================================================

helpers.describe("toml_codec: \\U codepoint range", function()

	helpers.it("valid \\U codepoint (U+1F600) decodes to the emoji", function()
		local src = 'key = "\\U0001F600"\n'
		local got = codec.decode(src)
		helpers.assert_true(got ~= nil, "decode must succeed for valid \\U codepoint")
		-- U+1F600 = 😀
		helpers.assert_eq(got.key, "\xF0\x9F\x98\x80",
			"\\U0001F600 must decode to the emoji glyph")
	end)

	helpers.it("out-of-range \\U codepoint (above U+10FFFF) decodes to replacement char", function()
		-- 0x00110000 is one past the maximum valid Unicode codepoint.
		-- The codec must not throw; it must substitute U+FFFD.
		local src = 'key = "\\U00110000"\n'
		local got = codec.decode(src)
		helpers.assert_true(got ~= nil, "decode must not throw for out-of-range \\U codepoint")
		-- U+FFFD replacement character = EF BF BD in UTF-8
		helpers.assert_eq(got.key, "\xEF\xBF\xBD",
			"out-of-range \\U codepoint must decode to U+FFFD replacement character")
	end)

end)


-- =====================================================================
-- =====================================================================
-- ======= 3/ Non-finite float literals ================================
-- =====================================================================
-- =====================================================================

helpers.describe("toml_codec: non-finite float literals", function()

	helpers.it("inf decodes to math.huge", function()
		local got = codec.decode("v = inf\n")
		helpers.assert_true(got ~= nil)
		helpers.assert_true(got.v == math.huge, "inf must decode to math.huge")
	end)

	helpers.it("+inf decodes to math.huge", function()
		local got = codec.decode("v = +inf\n")
		helpers.assert_true(got ~= nil)
		helpers.assert_true(got.v == math.huge, "+inf must decode to math.huge")
	end)

	helpers.it("-inf decodes to -math.huge", function()
		local got = codec.decode("v = -inf\n")
		helpers.assert_true(got ~= nil)
		helpers.assert_true(got.v == -math.huge, "-inf must decode to -math.huge")
	end)

	helpers.it("nan decodes to a number (NaN ~= NaN)", function()
		local got = codec.decode("v = nan\n")
		helpers.assert_true(got ~= nil)
		-- NaN is the only Lua value not equal to itself
		helpers.assert_true(type(got.v) == "number" and got.v ~= got.v,
			"nan must decode to a Lua NaN value")
	end)

	helpers.it("inf and nan are not returned as strings", function()
		local got = codec.decode("a = inf\nb = nan\n")
		helpers.assert_true(got ~= nil)
		helpers.assert_true(type(got.a) == "number", "inf must be a number, not a string")
		helpers.assert_true(type(got.b) == "number", "nan must be a number, not a string")
	end)

end)





-- ======================================================================
-- ======================================================================
-- ======= 4/ Duplicate-section detection via quoted-key spelling =======
-- ======================================================================
-- ======================================================================

helpers.describe("toml_codec: duplicate section detection (F-LOW-3)", function()

	helpers.it("rejects [a] re-opened as [\"a\"]", function()
		-- F-LOW-3: seen_sections used to key off the RAW un-normalized header text
		-- ("a" vs '"a"'), so re-opening the same table through its quoted-key
		-- spelling bypassed the duplicate-section check entirely even though
		-- split_section_path()/nav() resolve both headers to the exact same table.
		local src = "[a]\nx = 1\n[\"a\"]\ny = 2\n"
		local got = codec.decode(src)
		helpers.assert_true(got == nil,
			"[a] followed by [\"a\"] must be rejected as a duplicate section, not silently merged")
	end)

	helpers.it("rejects [\"a\"] re-opened as [a]", function()
		-- Symmetric case: the quoted spelling declared FIRST, re-opened via the
		-- bare spelling second. The dedup key must be direction-independent.
		local src = "[\"a\"]\nx = 1\n[a]\ny = 2\n"
		local got = codec.decode(src)
		helpers.assert_true(got == nil,
			"[\"a\"] followed by [a] must be rejected as a duplicate section")
	end)

	helpers.it("still allows two genuinely distinct sections", function()
		-- Sanity-check companion: the fix must not become over-eager and reject
		-- unrelated sections that merely share a substring.
		local src = "[a]\nx = 1\n[ab]\ny = 2\n"
		local got = codec.decode(src)
		helpers.assert_true(got ~= nil, "distinct sections [a] and [ab] must both decode fine")
		helpers.assert_eq(got.a.x, 1)
		helpers.assert_eq(got.ab.y, 2)
	end)

	helpers.it("still rejects a genuine unquoted duplicate ([a] then [a])", function()
		-- Regression companion: the pre-existing (already-working) case must
		-- keep working after switching the dedup key to the resolved segments.
		local src = "[a]\nx = 1\n[a]\ny = 2\n"
		local got = codec.decode(src)
		helpers.assert_true(got == nil, "[a] followed by [a] must still be rejected as a duplicate")
	end)

end)
