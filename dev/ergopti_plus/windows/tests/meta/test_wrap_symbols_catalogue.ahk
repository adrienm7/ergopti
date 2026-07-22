; tests/meta/test_wrap_symbols_catalogue.ahk

; ==============================================================================
; MODULE: Wrap-Symbols Shared Catalogue Test
; DESCRIPTION:
; Validates the shared single source of truth for the wrap-selection catalogue
; (static/ergopti_plus/_shared/wrap_symbols.json), which both the AHK tray menu
; and the macOS menubar load instead of hardcoding the symbol list.
;
; ROOT CAUSE ENCODED:
; The catalogue + its grouping must live ONLY in the shared JSON. This test parses
; that file with the same JsonParse the driver uses and asserts:
;   1. It is a JSON object exposing a non-empty "groups" array of arrays.
;   2. Every pair carries a "left" and a "right" string.
;   3. The newly-added Unicode bracket families are present (checked via
;      Chr(0xNNNN) so this test file stays ASCII-only -- see the AHK encoding
;      gotcha in copilot-instructions).
; If the shared file is deleted, emptied, or loses the new symbols, this fails.
; ==============================================================================

#Requires AutoHotkey v2.0

_MetaWrapSymbolsCatalogue() {
	SplitPath(A_ScriptDir, , &DriverRootRaw)
	JsonPath := DriverRootRaw . "\..\_shared\modules\wrap_symbols\wrap_symbols.json"
	AssertTrue(FileExist(JsonPath) != "", "_shared/modules/wrap_symbols/wrap_symbols.json must exist at '" . JsonPath . "'")

	Content := FileRead(JsonPath, "UTF-8")
	AssertTrue(Content != "", "_shared/modules/wrap_symbols/wrap_symbols.json must not be empty")

	Root := JsonParse(Content)
	AssertTrue(Root is Map, "wrap_symbols.json root must be a JSON object")
	AssertTrue(Root.Has("groups"), "wrap_symbols.json must declare a 'groups' array")
	Groups := Root["groups"]
	AssertTrue(Groups is Array, "'groups' must be a JSON array")
	AssertTrue(Groups.Length >= 5, "expected several groups (got " . Groups.Length . ")")

	; Each group is a labelled object {i18n, pairs}. Flatten, validating each
	; pair's shape, and collect the opening chars.
	Lefts := Map()
	PairCount := 0
	for Group in Groups {
		AssertTrue(Group is Map, "each group must be a JSON object")
		AssertTrue(Group.Has("i18n") and Group["i18n"] is String and Group["i18n"] != "",
			"each group must carry a non-empty 'i18n' label key")
		AssertTrue(InStr(Group["i18n"], "menu.shortcuts.wrap_group_") == 1,
			"group 'i18n' must be a wrap_group_* key, got '" . Group["i18n"] . "'")
		AssertTrue(Group.Has("pairs") and Group["pairs"] is Array, "each group must carry a 'pairs' array")
		AssertTrue(Group["pairs"].Length > 0, "no group may be empty")
		for P in Group["pairs"] {
			AssertTrue(P is Map, "each pair must be a JSON object")
			AssertTrue(P.Has("left") and P.Has("right"), "each pair must carry 'left' and 'right'")
			AssertTrue(P["left"] is String and P["left"] != "", "pair 'left' must be a non-empty string")
			AssertTrue(P["right"] is String and P["right"] != "", "pair 'right' must be a non-empty string")
			Lefts[P["left"]] := P["right"]
			PairCount += 1
		}
	}
	AssertTrue(PairCount >= 30, "catalogue should carry the full symbol set (got " . PairCount . ")")

	; The newly-added Unicode bracket families (glyphs via Chr to stay ASCII-only).
	AngleOpen   := Chr(0x3008)  ; U+3008 left angle bracket
	AngleClose  := Chr(0x3009)  ; U+3009 right angle bracket
	CornerOpen  := Chr(0x300C)  ; U+300C left corner bracket
	WhiteOpen   := Chr(0x27E6)  ; U+27E6 left white square bracket
	GermanOpen  := Chr(0x201E)  ; U+201E double low-9 quotation mark
	OverBrace   := Chr(0x23B4)  ; U+23B4 top square bracket
	AssertTrue(Lefts.Has(AngleOpen),  "catalogue must include the U+3008 angle bracket pair")
	AssertEqual(AngleClose, Lefts[AngleOpen], "U+3008 must close with U+3009")
	AssertTrue(Lefts.Has(CornerOpen), "catalogue must include the U+300C CJK corner bracket pair")
	AssertTrue(Lefts.Has(WhiteOpen),  "catalogue must include the U+27E6 white square bracket pair")
	AssertTrue(Lefts.Has(GermanOpen), "catalogue must include the U+201E German low quote pair")
	AssertTrue(Lefts.Has(OverBrace),  "catalogue must include the U+23B4 over-bracket pair")
}

_MetaRunWrapSymbolsCatalogueTests() {
	Test("meta wrap-symbols catalogue: shared JSON parses with grouped pairs + new Unicode brackets",
		_MetaWrapSymbolsCatalogue)
}

_MetaRunWrapSymbolsCatalogueTests()
