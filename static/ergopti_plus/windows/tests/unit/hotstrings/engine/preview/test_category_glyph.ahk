; tests/unit/hotstrings/engine/preview/test_category_glyph.ahk

; ==============================================================================
; MODULE: Category glyph in the hotstring preview
; DESCRIPTION:
; The preview tints sit at one lightness, so a colour-blind reader tells the
; categories apart by a glyph beside the trigger label (the maintainer's
; decision of 2026-11-19). These cases pin the Windows side:
;
; 1. The resolver answers the cross-driver vectors of
;    _shared/tests/corpus/hotstrings/category_glyph_vectors.json, and the row
;    label is the glyph, a space, then the trigger label.
; 2. A magic-key row typed through the real prefix watcher carries its
;    category's glyph, and the built tooltip Gui draws it beside the trigger.
; 3. The glyph switch off draws the bare trigger label.
; 4. The screen-reader notice names the category the glyph stands for.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ The shared contract =======
; ======================================
; ======================================

; The vectors every driver reads.
; @returns {Map}
_HCG_Vectors() {
	global _SharedDir
	return JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\hotstrings\category_glyph_vectors.json"))
}

; A vector's [_meta] as ParseTomlGroupConfig hands it over: a declared field is
; an own property, an absent one is not set.
; @param Vector {Map}
; @returns {Object}
_HCG_Meta(Vector) {
	Meta := {}
	if !Vector.Has("meta") || !(Vector["meta"] is Map)
		return Meta
	if Vector["meta"].Has("glyph")
		Meta.Glyph := Vector["meta"]["glyph"]
	if Vector["meta"].Has("glyph_name_key")
		Meta.GlyphNameKey := Vector["meta"]["glyph_name_key"]
	return Meta
}

_HCG_ResolverAnswersTheVectors() {
	Document := _HCG_Vectors()
	Defaults := Document["defaults"]
	AssertTrue(Document["vectors"].Length > 0, "sanity: the corpus holds vectors")
	global HOTSTRINGS_GLYPH_MAX_CODEPOINTS
	AssertEqual(Defaults["max_codepoints"], HOTSTRINGS_GLYPH_MAX_CODEPOINTS,
		"defaults.toml [glyphs] max_codepoints, as the vectors use it")
	for Vector in Document["vectors"] {
		Resolved := HotstringCategoryGlyphResolve(_HCG_Meta(Vector),
			Vector.Get("category_glyph", ""), Vector.Get("category_name_key", ""),
			Defaults["default_glyph"], Defaults["default_name_key"])
		Expected := Vector["expected"]
		AssertEqual(Expected["glyph"], Resolved.Glyph, Vector["id"] . ": glyph")
		AssertEqual(Expected["name_key"], Resolved.NameKey, Vector["id"] . ": name key")
		Rejected := Expected.Get("rejected", Map())
		AssertEqual(Rejected.Count, Resolved.Rejected.Count, Vector["id"] . ": refused fields")
		for Field, Value in Rejected
			AssertEqual(Value, Resolved.Rejected.Get(Field, "(none)"), Vector["id"] . ": refused " . Field)
	}
}

_HCG_RowLabelAnswersTheVectors() {
	for Vector in _HCG_Vectors()["row_label_vectors"]
		AssertEqual(Vector["expected"], TooltipRowLabel(Vector["glyph"], Vector["trigger_label"]), Vector["id"])
}

Test("preview category glyph: the resolver answers the cross-driver vectors", _HCG_ResolverAnswersTheVectors)
Test("preview category glyph: the row label answers the cross-driver vectors", _HCG_RowLabelAnswersTheVectors)





; ===================================
; ===================================
; ======= 2/ The real preview =======
; ===================================
; ===================================

; Types the magic-key symbol trigger "(v)" through the real prefix watcher with
; the glyph switch set to Shown, and hands Body the rows the bubble was asked to
; show.
; @param Shown {Boolean} The glyph switch.
; @param Body {Func} Called with the pending rows.
_HCG_WithMagicKeyRows(Shown, Body) {
	global HSE_PreviewSwitches
	SavedSwitches := HSE_PreviewSwitches
	Fresh := Map()
	for Key in HSE_PreviewSwitchKeys()
		Fresh[Key] := true
	Fresh[ConfigLeaf.PREVIEW_CATEGORY_GLYPHS] := Shown
	HSE_PreviewSwitches := Fresh
	Saved := _HPS_Setup()
	try {
		MK := ScriptInformation["MagicKey"]
		_HPS_RegisterDelayed("*C", "(v)" . MK, Chr(0x2713), 2, "magickey", "text_expansion_symbols")
		HSE_FeedReset(true)
		_HPS_ObserveTyped("(v)")
		_LookupAndRender()
		Rows := _HPS_PendingRows()
		AssertEqual(1, Rows.Length, "sanity: the magic-key row is shown")
		Body(Rows)
	} finally {
		_HPS_Teardown(Saved)
		HSE_PreviewSwitches := SavedSwitches
	}
}

; The texts of every control of a built, never shown tooltip Gui, which is then
; retired the way the renderer retires one.
; @param Rows {Array}
; @returns {Array}
_HCG_DrawnTexts(Rows) {
	global _TOOLTIP_LABEL_COLOR_HEX, _SharedDir
	; This headless harness does not run UiStyle_LoadSharedConst: seed the label
	; colour from the constants.toml it reads, as the label control is drawn in it.
	Saved := _TOOLTIP_LABEL_COLOR_HEX
	_TOOLTIP_LABEL_COLOR_HEX := _UiStyleRequireHex(
		ParseTomlFile(_SharedDir . "\core\ui\data\tooltip\constants.toml"), "colors", "label_hex")
	Texts := []
	try {
		Built := _TooltipBuildGui(Rows)
		Surface := _TooltipCreateDetachedSurface(Built, 1)
		try {
			for Ctrl in Built.Gui
				Texts.Push(Ctrl.Text)
		} finally _TooltipDisposeRetired(Surface)
	} finally _TOOLTIP_LABEL_COLOR_HEX := Saved
	return Texts
}

; Whether an array holds a value.
_HCG_Has(Values, Wanted) {
	for Value in Values
		if (Value == Wanted)
			return true
	return false
}

_HCG_TheRowDrawsTheCategoryGlyph() {
	Expected := HotstringsResolve("magickey", "text_expansion_symbols").Glyph
	AssertTrue(Expected != "", "sanity: the magic-key category declares a glyph, or this case proves nothing")
	_HCG_WithMagicKeyRows(true, (Rows) => (
		AssertEqual(Expected, Rows[1].Glyph, "the row carries its category's glyph"),
		AssertTrue(_HCG_Has(_HCG_DrawnTexts(Rows), Expected . " " . ScriptInformation["MagicKey"]),
			"the tooltip draws the glyph beside the trigger label, in the label's control")))
}

_HCG_TheSwitchHidesTheGlyph() {
	_HCG_WithMagicKeyRows(false, (Rows) => (
		AssertEqual("", Rows[1].Glyph, "the glyph switch off leaves the row without a glyph"),
		AssertTrue(_HCG_Has(_HCG_DrawnTexts(Rows), ScriptInformation["MagicKey"]),
			"the glyph switch off draws the bare trigger label")))
}

_HCG_TheNoticeNamesTheCategory() {
	Name := t(HotstringsResolve("magickey", "text_expansion_symbols").GlyphNameKey)
	AssertTrue(Name != "", "sanity: the glyph has a name")
	_HCG_WithMagicKeyRows(true, (Rows) =>
		AssertEqual(Chr(0x2713) . ", " . Name, _TooltipAnnouncementText(Rows, 0),
			"the screen reader hears the category the glyph stands for"))
	_HCG_WithMagicKeyRows(false, (Rows) =>
		AssertEqual(Chr(0x2713), _TooltipAnnouncementText(Rows, 0),
			"a hidden glyph is not announced"))
}

Test("preview category glyph: the preview row draws its category's glyph beside the trigger", _HCG_TheRowDrawsTheCategoryGlyph)
Test("preview category glyph: the switch off draws the bare trigger label", _HCG_TheSwitchHidesTheGlyph)
Test("preview category glyph: the screen-reader notice names the category", _HCG_TheNoticeNamesTheCategory)
