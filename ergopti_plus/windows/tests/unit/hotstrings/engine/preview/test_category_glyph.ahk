; tests/unit/hotstrings/engine/preview/test_category_glyph.ahk

; ==============================================================================
; MODULE: Category glyph in the hotstring preview
; DESCRIPTION:
; The preview tints sit at one lightness, so a colour-blind reader tells the
; categories apart by a glyph (the maintainer's decision of 2026-11-19). The
; glyph is drawn first, at the far left of the row, in a filled chip,
; so it reads as an annotation and not as text the expansion types (his request
; of the same day; a chip rather than a frame since 2026-11-20, one control per
; row). These cases pin the Windows side:
;
; 1. The resolver and the badge geometry answer the cross-driver vectors of
;    _shared/tests/corpus/hotstrings/category_glyph_vectors.json.
; 2. A magic-key row typed through the real prefix watcher carries its
;    category's glyph, and the built tooltip Gui draws it first, as one
;    chip control that ends before the output text; the trigger label
;    stays alone at the right.
; 3. The glyph switch off draws neither badge nor gap: the output keeps the
;    padding it had before the glyphs.
; 4. The AI tooltip's embedded hotstring rows draw the same badge.
; 5. The screen-reader notice names the category first.
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

_HCG_BadgeAnswersTheVectors() {
	Document := _HCG_Vectors()
	Layout := Document["badge_layout"]
	AssertTrue(Document["badge_vectors"].Length > 0, "sanity: the corpus holds badge vectors")
	for Vector in Document["badge_vectors"] {
		Badge := TooltipGlyphBadge(Vector["glyph_w"], Vector["glyph_h"], Layout["glyph_badge_pad_x"],
			Layout["glyph_badge_pad_y"], Layout["glyph_badge_gap"])
		AssertEqual(Vector["expected"]["w"], Badge.W, Vector["id"] . ": frame width")
		AssertEqual(Vector["expected"]["h"], Badge.H, Vector["id"] . ": frame height")
		AssertEqual(Vector["expected"]["zone"], Badge.Zone, Vector["id"] . ": output offset")
	}
}

Test("preview category glyph: the resolver answers the cross-driver vectors", _HCG_ResolverAnswersTheVectors)
Test("preview category glyph: the badge geometry answers the cross-driver vectors", _HCG_BadgeAnswersTheVectors)





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

; Runs Body with the tooltip's padding, label and badge style read from
; constants.toml: this headless harness does not run UiStyle_LoadSharedConst.
; The globals are restored afterwards.
; @param Body {Func}
_HCG_WithBadgeStyle(Body) {
	global _TOOLTIP_LABEL_COLOR_HEX, _TOOLTIP_GLYPH_BADGE_HEX, _TOOLTIP_GLYPH_BADGE_PAD_X
	global _TOOLTIP_GLYPH_BADGE_PAD_Y, _TOOLTIP_GLYPH_BADGE_GAP, _TOOLTIP_PADDING_X, _SharedDir
	Saved := [_TOOLTIP_LABEL_COLOR_HEX, _TOOLTIP_GLYPH_BADGE_HEX, _TOOLTIP_GLYPH_BADGE_PAD_X,
		_TOOLTIP_GLYPH_BADGE_PAD_Y, _TOOLTIP_GLYPH_BADGE_GAP, _TOOLTIP_PADDING_X]
	Constants := ParseTomlFile(_SharedDir . "\core\ui\data\tooltip\constants.toml")
	_TOOLTIP_LABEL_COLOR_HEX := _UiStyleRequireHex(Constants, "colors", "label_hex")
	_TOOLTIP_GLYPH_BADGE_HEX := UiStyle_GreyHex(_UiStyleRequire(Constants, "colors", "glyph_badge_white"))
	_TOOLTIP_GLYPH_BADGE_PAD_X := Integer(_UiStyleRequire(Constants, "layout", "glyph_badge_pad_x"))
	_TOOLTIP_GLYPH_BADGE_PAD_Y := Integer(_UiStyleRequire(Constants, "layout", "glyph_badge_pad_y"))
	_TOOLTIP_GLYPH_BADGE_GAP := Integer(_UiStyleRequire(Constants, "layout", "glyph_badge_gap"))
	_TOOLTIP_PADDING_X := Integer(_UiStyleRequire(Constants, "layout", "pad_x"))
	try Body()
	finally {
		_TOOLTIP_LABEL_COLOR_HEX := Saved[1]
		_TOOLTIP_GLYPH_BADGE_HEX := Saved[2]
		_TOOLTIP_GLYPH_BADGE_PAD_X := Saved[3]
		_TOOLTIP_GLYPH_BADGE_PAD_Y := Saved[4]
		_TOOLTIP_GLYPH_BADGE_GAP := Saved[5]
		_TOOLTIP_PADDING_X := Saved[6]
	}
}

; The text and rectangle of every control of a Gui.
; @param G {Gui}
; @returns {Array} Of { Text, X, Y, W, H }.
_HCG_Controls(G) {
	Controls := []
	for Ctrl in G {
		Ctrl.GetPos(&X, &Y, &W, &H)
		Controls.Push({ Text: Ctrl.Text, X: X, Y: Y, W: W, H: H })
	}
	return Controls
}

; The controls of a built, never shown hotstring tooltip Gui, which is then
; retired the way the renderer retires one.
; @param Rows {Array}
; @returns {Array} As _HCG_Controls.
_HCG_DrawnControls(Rows) {
	Controls := []
	_HCG_WithBadgeStyle(() => (
		Built := _TooltipBuildGui(Rows),
		Surface := _TooltipCreateDetachedSurface(Built, 1),
		_HCG_CollectAndRetire(Built, Surface, Controls)))
	return Controls
}

; Copies a built Gui's controls into Into, then retires its surface.
_HCG_CollectAndRetire(Built, Surface, Into) {
	try {
		for Control in _HCG_Controls(Built.Gui)
			Into.Push(Control)
	} finally _TooltipDisposeRetired(Surface)
}

; The controls the AI tooltip draws for its embedded hotstring rows
; (llm.trigger.while_hotstring_tooltip = "both"), in a Gui destroyed afterwards.
; @param Rows {Array}
; @returns {Array} As _HCG_Controls.
_HCG_SharedHeaderControls(Rows) {
	Controls := []
	_HCG_WithBadgeStyle(() => _HCG_DrawSharedHeader(Rows, Controls))
	return Controls
}

_HCG_DrawSharedHeader(Rows, Into) {
	G := Gui("-Caption +E0x80")
	try {
		Header := _LLM_TooltipMeasureHeader(Rows)
		_TooltipDrawSharedHotstringRows(G, Rows, Header, Header.W)
		for Control in _HCG_Controls(G)
			Into.Push(Control)
	} finally G.Destroy()
}

; The first control whose text is Wanted, or 0.
_HCG_Find(Controls, Wanted) {
	for Control in Controls
		if (Control.Text == Wanted)
			return Control
	return 0
}

; Asserts the row draws its glyph first, as one chip control that ends
; before the output, and the trigger label alone after the output.
; @param Controls {Array} As _HCG_Controls.
; @param Glyph {String}
; @param Output {String}
; @param Where {String} The surface, for the messages.
_HCG_AssertBadgeFirst(Controls, Glyph, Output, Where) {
	GlyphCtrl := _HCG_Find(Controls, Glyph)
	OutputCtrl := _HCG_Find(Controls, Output)
	LabelCtrl := _HCG_Find(Controls, ScriptInformation["MagicKey"])
	AssertTrue(IsObject(GlyphCtrl), Where . ": the glyph has a control of its own, not one shared with the trigger label")
	AssertTrue(IsObject(OutputCtrl), Where . ": sanity: the output is drawn")
	AssertTrue(IsObject(LabelCtrl), Where . ": the trigger label is drawn alone")
	AssertTrue(GlyphCtrl.X + GlyphCtrl.W <= OutputCtrl.X,
		Where . ": the glyph is drawn before the output, at the left of the row")
	for Control in Controls
		if (Control.Text != "" && Control != GlyphCtrl)
			AssertTrue(Control.X > GlyphCtrl.X, Where . ": nothing is drawn left of the glyph, « " . Control.Text . " » is")
	; One control is the chip: nothing but the row's full-width band lies under it.
	for Control in Controls
		if (Control != GlyphCtrl && Control.X > 0 && Control.X < GlyphCtrl.X + GlyphCtrl.W
				&& Control.X + Control.W > GlyphCtrl.X)
			AssertTrue(false, Where . ": the chip is one control; another lies at x " . Control.X)
	Size := _TooltipMeasureTextSize(Glyph, _TOOLTIP_LABEL_FONT_SIZE)
	AssertTrue(GlyphCtrl.W > Size.W, Where . ": the chip pads its glyph on both sides")
	AssertTrue(GlyphCtrl.X + GlyphCtrl.W < OutputCtrl.X,
		Where . ": the chip ends before the output, with a gap")
	AssertTrue(LabelCtrl.X > OutputCtrl.X, Where . ": the trigger label stays right of the output")
}

; Asserts the row draws no badge and no gap: the output starts at the padding.
_HCG_AssertNoBadge(Controls, Glyph, Output, PaddingX, Where) {
	AssertFalse(IsObject(_HCG_Find(Controls, Glyph)), Where . ": no glyph is drawn")
	OutputCtrl := _HCG_Find(Controls, Output)
	AssertTrue(IsObject(OutputCtrl), Where . ": sanity: the output is drawn")
	AssertEqual(PaddingX, OutputCtrl.X, Where . ": the output keeps the row's padding, with no gap left")
	AssertTrue(IsObject(_HCG_Find(Controls, ScriptInformation["MagicKey"])),
		Where . ": the bare trigger label is drawn")
}

_HCG_TheRowDrawsTheGlyphFirstOnAChip() {
	Expected := HotstringsResolve("magickey", "text_expansion_symbols").Glyph
	AssertTrue(Expected != "", "sanity: the magic-key category declares a glyph, or this case proves nothing")
	AssertTrue(Expected != Chr(0x2713), "sanity: the glyph differs from the output it annotates")
	_HCG_WithMagicKeyRows(true, (Rows) => (
		AssertEqual(Expected, Rows[1].Glyph, "the row carries its category's glyph"),
		_HCG_AssertBadgeFirst(_HCG_DrawnControls(Rows), Expected, Rows[1].Text, "hotstring tooltip")))
}

_HCG_TheSwitchHidesTheBadgeAndItsGap() {
	Expected := HotstringsResolve("magickey", "text_expansion_symbols").Glyph
	PaddingX := 0
	; The frame's left edge, with the glyph shown, is the row's padding in the
	; Gui's own units: the output must start there once the glyph is hidden.
	_HCG_WithMagicKeyRows(true, (Rows) => (
		Controls := _HCG_DrawnControls(Rows),
		PaddingX := _HCG_LeftmostX(Controls)))
	AssertTrue(PaddingX > 0, "sanity: the padding is measured")
	_HCG_WithMagicKeyRows(false, (Rows) => (
		AssertEqual("", Rows[1].Glyph, "the glyph switch off leaves the row without a glyph"),
		_HCG_AssertNoBadge(_HCG_DrawnControls(Rows), Expected, Rows[1].Text, PaddingX, "hotstring tooltip")))
}

; The left edge of the leftmost control that is not a full-width band.
_HCG_LeftmostX(Controls) {
	Left := 0
	for Control in Controls
		if (Control.X > 0 && (Left == 0 || Control.X < Left))
			Left := Control.X
	return Left
}

Test("preview category glyph: the row draws the glyph first, on a chip before the output", _HCG_TheRowDrawsTheGlyphFirstOnAChip)
Test("preview category glyph: the switch off draws no badge and leaves no gap", _HCG_TheSwitchHidesTheBadgeAndItsGap)





; ===========================================
; ===========================================
; ======= 3/ The AI tooltip's preview =======
; ===========================================
; ===========================================

_HCG_TheSharedHeaderDrawsTheSameBadge() {
	Expected := HotstringsResolve("magickey", "text_expansion_symbols").Glyph
	PaddingX := 0
	_HCG_WithMagicKeyRows(true, (Rows) => (
		Controls := _HCG_SharedHeaderControls(Rows),
		_HCG_AssertBadgeFirst(Controls, Expected, Rows[1].Text, "AI tooltip"),
		PaddingX := _HCG_LeftmostX(Controls)))
	_HCG_WithMagicKeyRows(false, (Rows) =>
		_HCG_AssertNoBadge(_HCG_SharedHeaderControls(Rows), Expected, Rows[1].Text, PaddingX, "AI tooltip"))
}

; The header geometry moves the text by the badge column and grows a row only
; when its badge is taller than its text.
_HCG_TheSharedHeaderLayoutMakesRoomForTheBadge() {
	Header := _LLM_TooltipHeaderLayout([{ W: 90, H: 18 }, { W: 140, H: 18 }],
		[{ W: 12, H: 14 }, { W: 0, H: 0 }], { PadX: 14, PadY: 7, LabelGap: 16 },
		{ W: 18, H: 20, Zone: 26 }, [Chr(0x2726), ""])
	AssertEqual(14 + 26, Header.TextX, "the output starts after the badge and its gap")
	AssertEqual(14 + 26 + 140 + 16 + 12 + 14, Header.W, "the panel widens by the badge column")
	AssertEqual(20, Header.ContentH[1], "a row whose badge is taller than its text grows to the badge")
	AssertEqual(18, Header.ContentH[2], "a row without a glyph keeps its text height")
	Bare := _LLM_TooltipHeaderLayout([{ W: 90, H: 18 }], [{ W: 12, H: 14 }], { PadX: 14, PadY: 7, LabelGap: 16 })
	AssertEqual(14, Bare.TextX, "without a glyph the output keeps the padding")
	AssertEqual(14 + 90 + 16 + 12 + 14, Bare.W, "and the panel its old width")
}

Test("preview category glyph: the AI tooltip's hotstring rows draw the same badge", _HCG_TheSharedHeaderDrawsTheSameBadge)
Test("preview category glyph: the AI tooltip's header makes room for the badge", _HCG_TheSharedHeaderLayoutMakesRoomForTheBadge)





; ====================================
; ====================================
; ======= 4/ The screen reader =======
; ====================================
; ====================================

_HCG_TheNoticeNamesTheCategoryFirst() {
	Name := t(HotstringsResolve("magickey", "text_expansion_symbols").GlyphNameKey)
	AssertTrue(Name != "", "sanity: the glyph has a name")
	_HCG_WithMagicKeyRows(true, (Rows) =>
		AssertEqual(Name . ", " . Chr(0x2713), _TooltipAnnouncementText(Rows, 0),
			"the screen reader hears the category first, as the badge comes first"))
	_HCG_WithMagicKeyRows(false, (Rows) =>
		AssertEqual(Chr(0x2713), _TooltipAnnouncementText(Rows, 0),
			"a hidden glyph is not announced"))
}

Test("preview category glyph: the screen-reader notice names the category first", _HCG_TheNoticeNamesTheCategoryFirst)
