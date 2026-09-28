--- tests/unit/lib/test_text_case.lua

--- ==============================================================================
--- MODULE: Unicode Text Case
--- DESCRIPTION:
--- Regression coverage for non-ASCII and multi-codepoint selection casing in the
--- shared unicode_case module the macOS and Linux drivers both load.
--- ==============================================================================

local helpers = require("tests.helpers")
local UnicodeCase = helpers.load_module("unicode_case")

helpers.describe("Unicode case conversion", function()
	helpers.it("uses the pinned complete Unicode dataset", function()
		helpers.assert_eq(UnicodeCase.UNICODE_VERSION, "17.0")
	end)

	helpers.it("uppercases accents, ligatures, Greek, and Cyrillic", function()
		helpers.assert_eq(
			UnicodeCase.upper("été Straße Москва ελληνικά"),
			"ÉTÉ STRASSE МОСКВА ΕΛΛΗΝΙΚΆ"
		)
	end)

	helpers.it("lowercases context-independent Unicode mappings", function()
		helpers.assert_eq(UnicodeCase.lower("İIıi STRAẞE"), "i̇iıi straße")
	end)

	helpers.it("applies the contextual Greek final-sigma rule", function()
		helpers.assert_eq(UnicodeCase.lower("ΟΣ ΟΣΑ ΟΣ'"), "ος οσα ος'")
		helpers.assert_eq(UnicodeCase.lower("ΑΣ́ ΑΣ́Α"), "ας́ ασ́α",
			"case-ignorable combining marks must not hide the surrounding letters")
	end)

	helpers.it("titlecases the first character after punctuation and hyphens", function()
		helpers.assert_eq(
			UnicodeCase.title("«ÉTÉ» STRAẞE МОСКВА"),
			"«Été» Straße Москва"
		)
		helpers.assert_eq(UnicodeCase.title("ß foo-bar ǆungla"), "Ss Foo-Bar ǅungla",
			"a hyphen starts a word, as in Jean-Pierre")
	end)

	helpers.it("detects whether uppercase toggle should promote or demote", function()
		helpers.assert_true(UnicodeCase.has_lowercase("Été ΜΟΣΧΑ"))
		helpers.assert_true(not UnicodeCase.has_lowercase("ÉTÉ МОСКВА"))
	end)

	helpers.it("recognizes complete UTF-8 characters and international boundaries", function()
		helpers.assert_true(UnicodeCase.is_single_character("é"))
		helpers.assert_true(not UnicodeCase.is_single_character("ab"))
		helpers.assert_true(UnicodeCase.is_word_boundary("—"), "em dash is punctuation")
		helpers.assert_true(UnicodeCase.is_word_boundary(" "), "non-breaking space is whitespace")
		helpers.assert_true(not UnicodeCase.is_word_boundary("é"), "letters stay inside a word")
	end)
end)
