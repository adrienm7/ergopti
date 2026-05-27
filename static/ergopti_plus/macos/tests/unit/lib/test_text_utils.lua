--- tests/unit/lib/test_text_utils.lua

--- ==============================================================================
--- MODULE: text_utils Unit Tests
--- DESCRIPTION:
--- Comprehensive coverage of UTF-8 helpers, the diff_strings engine, the case
--- conversion routines, and the unescape_text decoder.
--- ==============================================================================

local helpers = require("tests.helpers")
local tu = helpers.load_with_stubs("lib.text_utils")




-- ===================================
--- ===================================
-- ======= 1/ utf8_chars / len =======
--- ===================================
-- ===================================

helpers.describe("text_utils.utf8_chars", function()
	helpers.it("splits ASCII into individual chars", function()
		local r = tu.utf8_chars("abc")
		helpers.assert_eq(r, { "a", "b", "c" })
	end)

	helpers.it("handles multi-byte sequences", function()
		local r = tu.utf8_chars("éà")
		helpers.assert_eq(#r, 2)
		helpers.assert_eq(r[1], "é") ; helpers.assert_eq(r[2], "à")
	end)

	helpers.it("returns empty for non-string input", function()
		helpers.assert_eq(tu.utf8_chars(nil), {})
		helpers.assert_eq(tu.utf8_chars(42), {})
	end)

	helpers.it("returns empty for empty string", function()
		helpers.assert_eq(tu.utf8_chars(""), {})
	end)
end)

helpers.describe("text_utils.utf8_len", function()
	helpers.it("counts ASCII codepoints", function()
		helpers.assert_eq(tu.utf8_len("hello"), 5)
	end)

	helpers.it("counts multi-byte codepoints", function()
		helpers.assert_eq(tu.utf8_len("éàü"), 3)
	end)

	helpers.it("returns 0 for non-string", function()
		helpers.assert_eq(tu.utf8_len(nil), 0)
	end)

	helpers.it("returns 0 for empty string", function()
		helpers.assert_eq(tu.utf8_len(""), 0)
	end)
end)

helpers.describe("text_utils.utf8_sub", function()
	helpers.it("extracts ASCII substring", function()
		helpers.assert_eq(tu.utf8_sub("hello", 2, 4), "ell")
	end)

	helpers.it("handles multi-byte", function()
		helpers.assert_eq(tu.utf8_sub("éàüî", 2, 3), "àü")
	end)

	helpers.it("supports negative end index", function()
		helpers.assert_eq(tu.utf8_sub("abcde", 1, -1), "abcde")
		helpers.assert_eq(tu.utf8_sub("abcde", 1, -2), "abcd")
	end)

	helpers.it("returns empty when range is reversed", function()
		helpers.assert_eq(tu.utf8_sub("abc", 3, 1), "")
	end)

	helpers.it("returns empty for non-string input", function()
		helpers.assert_eq(tu.utf8_sub(nil, 1, 1), "")
	end)
end)

helpers.describe("text_utils.get_common_prefix_utf8", function()
	helpers.it("returns common prefix length", function()
		helpers.assert_eq(tu.get_common_prefix_utf8("hello world", "hello there"), 6)
	end)

	helpers.it("handles multi-byte common prefix", function()
		helpers.assert_eq(tu.get_common_prefix_utf8("été chaud", "été froid"), 4)
	end)

	helpers.it("returns 0 when nothing matches", function()
		helpers.assert_eq(tu.get_common_prefix_utf8("foo", "bar"), 0)
	end)

	helpers.it("returns 0 for empty strings", function()
		helpers.assert_eq(tu.get_common_prefix_utf8("", "abc"), 0)
	end)

	helpers.it("returns 0 for non-string args", function()
		helpers.assert_eq(tu.get_common_prefix_utf8(nil, "abc"), 0)
	end)
end)

helpers.describe("text_utils.utf8_ends_with", function()
	helpers.it("matches ASCII suffix", function()
		helpers.assert_true(tu.utf8_ends_with("hello world", "world"))
	end)

	helpers.it("rejects non-suffix", function()
		helpers.assert_true(not tu.utf8_ends_with("hello", "lloo"))
	end)

	helpers.it("matches multi-byte suffix", function()
		helpers.assert_true(tu.utf8_ends_with("café", "fé"))
	end)

	helpers.it("false for empty inputs", function()
		helpers.assert_true(not tu.utf8_ends_with("", "x"))
		helpers.assert_true(not tu.utf8_ends_with("x", ""))
	end)
end)

helpers.describe("text_utils.contains_high_unicode", function()
	helpers.it("false for ASCII", function()
		helpers.assert_true(not tu.contains_high_unicode("plain text"))
	end)

	helpers.it("false for BMP multi-byte", function()
		helpers.assert_true(not tu.contains_high_unicode("café"))
	end)

	helpers.it("true for emoji (>0xFFFF)", function()
		helpers.assert_true(tu.contains_high_unicode("hi 🎉"))
	end)
end)

helpers.describe("text_utils.unescape_text", function()
	helpers.it("decodes \\uXXXX", function()
		helpers.assert_eq(tu.unescape_text("\\u00e9"), "é")
	end)

	helpers.it("decodes backslash escapes", function()
		helpers.assert_eq(tu.unescape_text("a\\nb"), "a\nb")
		helpers.assert_eq(tu.unescape_text("\\\"quoted\\\""), "\"quoted\"")
	end)

	helpers.it("decodes HTML entities", function()
		helpers.assert_eq(tu.unescape_text("&eacute;"), "é")
		helpers.assert_eq(tu.unescape_text("&amp;"), "&")
		helpers.assert_eq(tu.unescape_text("&rsquo;"), "’")
	end)

	helpers.it("returns empty for non-string input", function()
		helpers.assert_eq(tu.unescape_text(nil), "")
	end)
end)




-- ====================================
-- ====================================
-- ======= 2/ Case conversions ========
-- ====================================
-- ====================================

helpers.describe("text_utils case helpers", function()
	helpers.it("trig_lower lowercases ASCII", function()
		helpers.assert_eq(tu.trig_lower("ABC"), "abc")
	end)

	helpers.it("trig_lower handles French accents", function()
		-- Order is preserved by gsub iteration over UTF-8 chars
		helpers.assert_eq(tu.trig_lower("ÉÈ"), "éè")
		helpers.assert_eq(tu.trig_lower("À"), "à")
	end)

	helpers.it("repl_upper uppercases ASCII and accents", function()
		helpers.assert_eq(tu.repl_upper("abc"), "ABC")
		helpers.assert_eq(tu.repl_upper("éà"), "ÉÀ")
	end)

	helpers.it("repl_title capitalises only first char", function()
		helpers.assert_eq(tu.repl_title("hello world"), "Hello world")
		helpers.assert_eq(tu.repl_title("élan"), "Élan")
	end)

	helpers.it("trig_upper returns at least one variant", function()
		local variants = tu.trig_upper("abc")
		helpers.assert_true(#variants >= 1)
		helpers.assert_eq(variants[1], "ABC")
	end)

	helpers.it("trig_title returns at least one variant", function()
		local variants = tu.trig_title("hello")
		helpers.assert_true(#variants >= 1)
		helpers.assert_eq(variants[1], "Hello")
	end)

	helpers.it("clear_trig_case_caches resets memoized state", function()
		tu.trig_upper("foo")
		tu.clear_trig_case_caches()
		-- Should still produce identical output post-clear
		helpers.assert_eq(tu.trig_upper("foo")[1], "FOO")
	end)

	helpers.it("is_letter_char true for ASCII letters", function()
		helpers.assert_true(tu.is_letter_char("a"))
		helpers.assert_true(tu.is_letter_char("Z"))
	end)

	helpers.it("is_letter_char true for accented letters", function()
		helpers.assert_true(tu.is_letter_char("é"))
		helpers.assert_true(tu.is_letter_char("ç"))
	end)

	helpers.it("is_letter_char false for spaces / empty", function()
		-- The %w class accepts digits, so digits return true by design
		helpers.assert_true(not tu.is_letter_char(" "))
		helpers.assert_true(not tu.is_letter_char(""))
	end)

	helpers.it("is_letter_char false for apostrophes (word boundary)", function()
		-- Both apostrophes must be word-boundary chars: otherwise "ia" with
		-- is_word=true would refuse to fire after "l'" / "l’" (French
		-- contractions), which is the documented expectation.
		helpers.assert_true(not tu.is_letter_char("'"))
		helpers.assert_true(not tu.is_letter_char("’"))
	end)
end)





-- =============================
--- ==============================
--- ======= 3/ diff engine =======
--- ==============================
-- =============================

helpers.describe("text_utils.diff_strings", function()
	helpers.it("returns empty for identical strings", function()
		local chunks = tu.diff_strings("hello", "hello")
		helpers.assert_eq(chunks, {})
	end)

	helpers.it("emits insert chunks for pure additions", function()
		local chunks = tu.diff_strings("hello", "hello world")
		-- At minimum, an insert chunk should be present
		local has_insert = false
		for _, c in ipairs(chunks) do if c.type == "insert" then has_insert = true end end
		helpers.assert_true(has_insert, "expected at least one insert chunk")
	end)

	helpers.it("returns empty for non-string inputs", function()
		helpers.assert_eq(tu.diff_strings(nil, "x"), {})
	end)
end)
