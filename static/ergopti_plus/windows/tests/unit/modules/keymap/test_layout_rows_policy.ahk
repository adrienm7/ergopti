; tests/unit/modules/keymap/test_layout_rows_policy.ahk

; ==============================================================================
; MODULE: Layout Rows Policy
; DESCRIPTION:
; The four row switches of the layout emulation (layout.emulate_<row>). The
; shared policy reads each row's keys from the physical-key registry and
; decides each row from its own switch; the hand-written corpus
; (tests/corpus/layouts/layout_rows.json) is replayed here and by the macOS and
; Linux contract tests. The Windows rows are the corpus scan codes, and a
; registry layout whose number row is switched off leaves the number-row
; ordering to the OS layout's row, « symbols first » included
; (layout-row-scopes).
; ==============================================================================

#Requires AutoHotkey v2.0




_LRP_Corpus() {
	global _SharedDir
	return JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\layouts\layout_rows.json"))
}

/** Replays the corpus rows and switches through the shared AHK policy. */
_LRP_SharedCorpus() {
	global _SharedDir, LAYOUT_ROWS_POLICY_IDS
	Corpus := _LRP_Corpus()
	Registry := JsonParse(FSReadUtf8Exact(_SharedDir . "\data\keycodes\physical_keys.json"))
	Rows := LayoutRowsPolicyKeys(Registry)
	AssertEqual(4, LAYOUT_ROWS_POLICY_IDS.Length, "four row switches")
	for Row in LAYOUT_ROWS_POLICY_IDS {
		Expected := Corpus["rows"][Row]
		AssertEqual(Expected.Length, Rows[Row].Length, Row . ": key count")
		for Index, Code in Expected
			AssertEqual(Code, Rows[Row][Index], Row . " key " . Index)
	}
	AssertThrows(() => LayoutRowsPolicyKeys(Map()), "a registry without keys is refused")
	AssertEqual(4, Corpus["switches"].Length, "every switch case is represented")
	for Vec in Corpus["switches"] {
		for Row in LAYOUT_ROWS_POLICY_IDS
			AssertEqual(Vec["emulated"][Row] ? true : false,
				LayoutRowsPolicyEmulates(Vec["layout"], Row), Vec["id"] . ": " . Row)
		AssertEqual(Vec["number_row_source"]["active"], LayoutRowsPolicyNumberRowSource(true, Vec["layout"]),
			Vec["id"] . ": the ordering's row under an active emulation")
		AssertEqual(Vec["number_row_source"]["inactive"], LayoutRowsPolicyNumberRowSource(false, Vec["layout"]),
			Vec["id"] . ": the ordering's row without an emulation")
	}
	for Invalid in Corpus["invalid"]
		AssertThrows(LayoutRowsPolicyEmulates.Bind(Invalid["layout"], Invalid["row"]), Invalid["id"] . " is refused")
}
Test("layout rows: the shared policy replays the corpus rows and switches (layout-row-scopes)", _LRP_SharedCorpus)

/** The Windows emulation's rows are the corpus scan codes, read from the registry. */
_LRP_WindowsRows() {
	global LAYOUT_ROWS_POLICY_IDS
	Corpus := _LRP_Corpus()
	Rows := LayoutEmulationRows()
	for Row in LAYOUT_ROWS_POLICY_IDS {
		Expected := Corpus["windows_scan_codes"][Row]
		AssertEqual(Expected.Length, Rows[Row].Length, Row . ": scan code count")
		for Index, Name in Expected {
			AssertEqual(Name, Rows[Row][Index], Row . " scan code " . Index)
			AssertEqual(Row, LayoutRowOf(Name), Name . " belongs to " . Row)
		}
	}
	AssertEqual("", LayoutRowOf("SC039"), "the space bar belongs to no row")
	AssertEqual("", LayoutRowOf("SC00F"), "Tab belongs to no row")
	; No driver source lists the rows' scan codes any more.
	Source := _DriverSourceNoComments()
	AssertEqual(0, InStr(Source, '"SC010", "SC011", "SC012"'), "no hand-written row table remains")
}
Test("layout rows: the Windows rows are read from the shared registry (layout-row-scopes)", _LRP_WindowsRows)

/**
 * A registry layout with its number row switched off: the ordering, its
 * availability and « symbols first » are the OS layout's row, typed by the
 * driver's own hotkeys, since the registry layout's action machine stands down
 * on that row.
 */
_LRP_RegistryNumberRowOff() {
	global Features, CategoryEnabled, LayerEnabled, _NumberRowAvailabilityCache
	State := MasterGateState()
	Saved := [Features, CategoryEnabled, LayerEnabled, State.Clone(), _NumberRowAvailabilityCache]
	try {
		Layout := Map("emulated_layout", "ergol", "ergopti_base", true, "ergopti_alt_gr", false,
			"ergopti_variant", "none", "direct_access_digits", "symbols", "emulate_number_row", true,
			"emulate_top_row", true, "emulate_home_row", true, "emulate_bottom_row", true)
		_NRP_UseLayout(Layout)
		_KLT_Load("ergol")
		_NumberRowAvailabilityCache := Map()
		_NRP_WithQwertyShapedForeground((Hkl) => (
			AssertTrue(NumberRowRegistryOwnsRow(), "Ergo-L types its own number row"),
			AssertEqual("emulated", _DigitRowEffectiveKey(0x02, Hkl, false)["source"]),
			Features["layout"]["emulate_number_row"] := false,
			AssertFalse(NumberRowRegistryOwnsRow(), "its number row switched off, the OS layout types it"),
			AssertEqual("native", _DigitRowEffectiveKey(0x02, Hkl, false)["source"], "the ordering reads the OS row"),
			AssertEqual("", NumberRowAvailability(Hkl, false)["symbols"], "symbols first can reorder the QWERTY row"),
			AssertTrue(NumberRowSymbolsCapable(false), "and the driver's own hotkeys type it"),
			AssertEqual("symbols", NumberRowEffectiveMode(), "the stored choice applies on the OS row"),
			AssertEqual("!", NumberRowSymbolsFirstText(0x02, false, Hkl, false), "the 1 key types its Shift symbol"),
			AssertFalse(_KLE_BaseCriterion("SC002", false), "the registry layout leaves the key")))
	} finally {
		Features := Saved[1]
		CategoryEnabled := Saved[2]
		LayerEnabled := Saved[3]
		State.Clear()
		for Key, Value in Saved[4]
			State[Key] := Value
		_NumberRowAvailabilityCache := Saved[5]
	}
}

Test("layout rows: a registry layout's number row switched off is reordered on the OS row (layout-row-scopes)",
	_KLT_WithEmulation.Bind(_LRP_RegistryNumberRowOff))
