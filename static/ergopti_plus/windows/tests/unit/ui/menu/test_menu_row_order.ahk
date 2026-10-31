; tests/unit/ui/menu/test_menu_row_order.ahk

; ==============================================================================
; MODULE: Menu Row Order Vectors (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/menu/row_order_vectors.json through the Windows
; reader, as _shared/lua/test/menu_row_order_contract.lua does on macOS and Linux,
; and pins the two Windows readers of hotstring_config_categories to the rule.
; ==============================================================================

#Requires AutoHotkey v2.0

_TMRO_Corpus() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\menu\row_order_vectors.json", "UTF-8"))
}

_TMRO_AssertSame(Expected, Actual, What) {
	AssertEqual(Expected.Length, Actual.Length, What . ": length")
	for Index, Item in Expected
		AssertEqual(Item, Actual[Index], What . ": entry " . Index)
}

_TMRO_Vectors() {
	Corpus := _TMRO_Corpus()
	Assert(Corpus["sorts"].Length >= 5 && Corpus["lists"].Length >= 1 && Corpus["refusals"].Length >= 2,
		"the corpus holds its vectors")
	for Vector in Corpus["sorts"]
		_TMRO_AssertSame(Vector["sorted"], MenuRowOrderSorted(Vector["rule"], Vector["input"]), Vector["id"])
	for Vector in Corpus["lists"]
		_TMRO_AssertSame(Vector["order"], MenuRowOrderList(Vector["rule"]), Vector["id"])
	for Vector in Corpus["refusals"] {
		Rule := Vector["rule"]
		AssertThrows(() => MenuRowOrderList(Rule), Vector["id"])
		AssertThrows(() => MenuRowOrderRank(Rule), Vector["id"])
		AssertThrows(() => MenuRowOrderSorted(Rule, []), Vector["id"])
	}
}
Test("menu row order: the shared vectors (menu-row-order)", _TMRO_Vectors)

_TMRO_Detached() {
	First := MenuRowOrderList("menu_chord_modifiers")
	First[1] := "tampered"
	AssertEqual("shift", MenuRowOrderList("menu_chord_modifiers")[1], "a caller cannot reorder the rule")
	Rank := MenuRowOrderRank("menu_chord_modifiers")
	AssertEqual(1, Rank["shift"], "first rank")
	AssertEqual(4, Rank["ctrl"], "last rank")
}
Test("menu row order: hands out a detached list on every call (menu-row-order)", _TMRO_Detached)

_TMRO_WindowsReaders() {
	; Neither file is in the headless harness: their readers are pinned by source.
	Widget := _StripFullLineComments(_DriverFuncBody("_WPMWidget_SectionBaseCategory"))
	Assert(Widget != "", "_WPMWidget_SectionBaseCategory must exist in the driver source")
	Assert(InStr(Widget, 'MenuRowOrderList("hotstring_config_categories")') > 0,
		"the widget's base categories come from the rule")
	Body := _StripFullLineComments(_DriverFuncBody("_HCW_CommonCategories"))
	Assert(Body != "", "_HCW_CommonCategories must exist in the driver source")
	Assert(InStr(Body, 'MenuRowOrderList("hotstring_config_categories")') > 0,
		"the common categories of the configuration window come from the rule")
	AssertEqual("personal", MenuRowOrderList("hotstring_config_categories")[-1],
		"personal closes the rule: the window leaves it to its own group")
}
Test("menu row order: the configuration window and the widget read the rule (menu-row-order)", _TMRO_WindowsReaders)
