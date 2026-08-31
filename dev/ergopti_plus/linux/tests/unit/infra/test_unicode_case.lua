--- tests/unit/infra/test_unicode_case.lua

--- ==============================================================================
--- MODULE: Unicode Case Conversion
--- DESCRIPTION:
--- Regression coverage for non-ASCII and multi-codepoint selection casing.
--- ==============================================================================

local helpers = require("tests.helpers")
local UnicodeCase = helpers.load_module("infra.unicode_case")

helpers.describe("Unicode case conversion", function()
	helpers.it("uses the pinned complete Unicode dataset", function()
		helpers.assert_eq(UnicodeCase.UNICODE_VERSION, "16.0")
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

	helpers.it("titlecases the first cased character after punctuation", function()
		helpers.assert_eq(
			UnicodeCase.title("«ÉTÉ» STRAẞE МОСКВА"),
			"«Été» Straße Москва"
		)
		helpers.assert_eq(UnicodeCase.title("ß foo-bar ǆungla"), "Ss Foo-bar ǅungla")
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
