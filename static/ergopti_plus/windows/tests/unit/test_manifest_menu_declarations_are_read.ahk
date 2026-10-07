; static/ergopti_plus/windows/tests/unit/test_manifest_menu_declarations_are_read.ahk

; ==============================================================================
; MODULE: Regression — manifest declarations that nothing read
; DESCRIPTION:
; Two keys in menu_manifest.json were declared and then ignored, each with a
; copy of the same data living in AutoHotkey source. The manifest is meant to be
; the description of what the user sees, so a key nobody reads is a config that
; lies: editing it moves nothing, and the code copy is the real source.
;
;   * ``accented_letters_group`` listed four letter_picker ids, while
;     _MR_BuildBuiltinGroup built the submenu from a hardcoded array of the same
;     four paths.
;   * ``modifier_combos_group`` (now key_combinations_group) listed three
;     feature-section paths, while the same builder read them from a
;     _SHORTCUTS_SUBMAP_V1V2 Map in ui/menu/menu_shortcuts.ahk.
;
; None of this was visible as a bug: the menus rendered correctly, because the
; code copy was in sync. The failure mode is the next edit — adding a fourth
; accented letter to the manifest, or a fourth modifier combo, changes nothing
; at all and there is no error to read.
;
; These tests pin the reader side. They fail if a builder goes back to owning
; the data, because the manifest section is then no longer what drives the row.
; ==============================================================================




; ==========================================================
; ==========================================================
; ======= 1/ The built-in groups read their section ========
; ==========================================================
; ==========================================================

; _MR_BuildBuiltinGroup now resolves ``<id>_group`` and has no fallback data of
; its own, so an empty or renamed section renders an EMPTY submenu rather than
; the wrong one. That is the failure these two pin.

Test("manifest_menu: accented_letters_group carries the letter rows", () => (
	; The ids, not just the count — the builder turns each into a
	; "shortcuts.<id>" picker, so a renamed id points at a letter that does not
	; exist and the row goes missing while the count still looks right. A first
	; version of this test asserted only Length == 4 and a probe that renamed a
	; row passed it.
	AssertEqual(
		"e_grave,e_circ,e_acute,a_grave",
		_MM_RowValues("accented_letters_group", "id"),
		"the accented-letters submenu is built from these ids, in this order"
	)
))

Test("manifest_menu: every accented-letter row names a picker id", () => (
	AssertTrue(
		_MM_EveryRowHasKey("accented_letters_group", "id"),
		"each letter_picker row needs an id; the builder skips rows without one"
	)
))

Test("manifest_menu: key_combinations_group lists the pairs through its provider", () => (
	; The three fixed families were ``feature`` rows naming a section and a
	; group_label. Every ordered pair of tap-hold keys is listed now, as data the
	; driver supplies (KeyCombinationRows): a leftover feature row would draw a
	; submenu of toggles that no hotkey reads.
	AssertEqual(
		"key_combination_rows_left,key_combination_rows_right",
		_MM_AhkRowIds("key_combinations_group", "list"),
		"the key-combinations submenu lists its pairs through exactly these providers, one per hand"
	),
	AssertEqual(
		"",
		_MM_AhkRowIds("key_combinations_group", "feature"),
		"no fixed family row remains"
	)
))

Test("manifest_menu: the key-combinations group opens with its own switch", () => (
	AssertEqual(
		"key_combinations_toggle",
		_MR_Get(_MR_GetMenuDef("key_combinations_group")[1], "id"),
		"the first row of the group is its KeyCombinations switch"
	)
))

; Joins the ids (the paths, for ``feature`` rows) of the Windows rows of one type
; of a manifest section, in order.
_MM_AhkRowIds(SectionKey, RowType) {
	Joined := ""
	for Row in _MR_GetMenuDef(SectionKey) {
		if (_MR_Get(Row, "type") != RowType or !_MR_IsForAhk(Row))
			continue
		Joined .= (Joined == "" ? "" : ",") . _MR_Get(Row, RowType == "feature" ? "path" : "id")
	}
	return Joined
}





; ===============================================
; ===============================================
; ======= 2/ Shared row-inspection helper =======
; ===============================================
; ===============================================

; Returns true when every row of the named manifest section carries a non-empty
; value under ``Key``. Declared after use — AHK hoists function definitions, so
; the order here is presentation, not dependency.
_MM_EveryRowHasKey(SectionKey, Key) {
	Rows := _MR_GetMenuDef(SectionKey)
	if (Rows.Length == 0) {
		return false
	}
	for Row in Rows {
		if (_MR_Get(Row, Key) == "") {
			return false
		}
	}
	return true
}

; Joins one field of every row in a manifest section, in order. Comparing the
; joined string pins the values AND their order in a single AssertEqual, which a
; length check does not.
_MM_RowValues(SectionKey, Key) {
	Out := []
	for Row in _MR_GetMenuDef(SectionKey) {
		Out.Push(_MR_Get(Row, Key))
	}
	Joined := ""
	for Value in Out {
		Joined .= (Joined == "" ? "" : ",") . Value
	}
	return Joined
}





; ================================================
; ================================================
; ======= Rows declared greyed or hidden =========
; ================================================
; ================================================

; The text of a native menu row at a zero-based position.
_MUR_LabelAt(TargetMenu, Position) {
	static MF_BYPOSITION := 0x400
	Length := DllCall("GetMenuStringW", "ptr", TargetMenu.Handle, "uint", Position,
		"ptr", 0, "int", 0, "uint", MF_BYPOSITION, "int")
	Assert(Length >= 0, "GetMenuStringW must read row " . Position)
	Buffer_ := Buffer((Length + 1) * 2, 0)
	DllCall("GetMenuStringW", "ptr", TargetMenu.Handle, "uint", Position,
		"ptr", Buffer_, "int", Length + 1, "uint", MF_BYPOSITION, "int")
	return StrGet(Buffer_, "UTF-16")
}

; The maintainer's rule of 2026-09-30: a row declared `unavailable = "grey"`
; that this platform lacks is drawn disabled, labelled with its label and the
; short head of its reason; one declared "hide" is not drawn.
_MUR_GreyedAndHiddenRows() {
	static KEY := "_test_unavailable_menu", MF_BYPOSITION := 0x400, GREYED := 0x3
	Root := _MR_GetManifestRoot()
	Assert(Root is Map, "the shared menu manifest must load")
	Reason := "platform_reason.shortcuts_restore_is_composed_on_macos"
	Root[KEY] := [
		Map("type", "command", "id", "ported", "i18n", "common.restore_recommended"),
		Map("type", "command", "id", "not_yet", "i18n", "common.clear_to_system",
			"platforms", ["hs", "linux"], "unavailable", "grey", "reason_key", Reason),
		Map("type", "command", "id", "not_here", "i18n", "menu.gestures.enable",
			"platforms", ["hs"], "unavailable", "hide")]
	try {
		Rendered := MenuRenderer_Build(KEY, "Test", "", "", "",
			Map("ported", (*) => 0, "not_yet", (*) => 0, "not_here", (*) => 0))
	} finally Root.Delete(KEY)
	try {
		AssertEqual(2, TrayMenuItemCount(Rendered), "the ported row and the greyed stand-in, nothing hidden")
		AssertEqual(t("common.restore_recommended"), _MUR_LabelAt(Rendered, 0))
		Head := _MR_ReasonHead(t(Reason))
		Assert(Head != "" && !InStr(Head, ":"), "the stand-in carries the short head of its reason")
		AssertEqual(t("common.clear_to_system") . " — " . Head, _MUR_LabelAt(Rendered, 1))
		State := DllCall("GetMenuState", "ptr", Rendered.Handle, "uint", 1, "uint", MF_BYPOSITION, "uint")
		Assert((State & GREYED) != 0, "the stand-in is disabled")
	} finally {
		Rendered.Delete()
		MenuDispatcher_PruneMenu(Rendered)
	}
	AssertEqual("Not on macOS yet", _MR_ReasonHead("Not on macOS yet: its key combinations"))
	AssertEqual("暂不适用于 macOS", _MR_ReasonHead("暂不适用于 macOS：在"))
	AssertEqual("Catalogue reload — Linux only", _MR_ReasonHead("Catalogue reload — Linux only"))
}
Test("menu: a greyed row is drawn disabled with its reason, a hidden one is not (menu-unavailable-rows)",
	_MUR_GreyedAndHiddenRows)

Test("inert captions: genuine translated rows retain disabled posture and section decoration", _MM_InertCaptionRows)
Test("inert captions: independent percent vectors keep literal native values", _MM_InertCaptionFormats)
Test("inert captions: missing and nonstring receipts refuse the whole template", _MM_InertCaptionRefusals)

_MM_InertCaptionCorpus() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\inert_dynamic_captions.json", "UTF-8"))
}

_MM_WithInertCaption(Body) {
	Corpus := _MM_InertCaptionCorpus(), Root := _MR_GetManifestRoot()
	Key := "inert_caption_fixture"
	Present := Root.Has(Key), Previous := Present ? Root[Key] : false
	try {
		Root[Key] := Corpus["rows"]
		Body.Call(Key, Corpus, Root)
	} finally {
		if Present
			Root[Key] := Previous
		else
			Root.Delete(Key)
	}
}

_MM_InertCaptionRows() {
	_MM_WithInertCaption(_MM_InertCaptionRowsBody)
}

_MM_InertCaptionRowsBody(Key, Corpus, Root) {
	Rows := MenuRenderer_TemplateRows(Key, Map(), Map("native_detail", (*) => Corpus["value"]), Map())
	AssertTrue(Rows is Array)
	AssertEqual(2, Rows.Length)
	AssertEqual(StrReplace(t("menu.llm.model_backend"), "%s", Corpus["value"]), Rows[1]["label"])
	AssertEqual("— " . StrReplace(t("menu.llm.hw_header"), "%s", Corpus["value"]) . " —", Rows[2]["label"])
	for Row in Rows {
		AssertTrue(Row["disabled"])
		AssertFalse(Row.Has("action"))
		AssertFalse(Row.Has("items"))
	}
	AssertFalse(_MR_TemplateInertPresentation(Key, Map()), "dynamic getter rows never grant omission")
	Root[Key][1]["command"] := "foreign"
	try AssertFalse(MenuRenderer_TemplateRows(Key, Map(), Map("native_detail", (*) => Corpus["value"]), Map()))
	finally Root[Key][1].Delete("command")
}

_MM_InertCaptionFormats() {
	Corpus := _MM_InertCaptionCorpus()
	for Vector in Corpus["format_cases"] {
		Actual := _MR_CaptionFormat(Vector["format"], Corpus["value"], &HasSlot)
		AssertEqual(Vector["expected"], Actual, "handwritten full caption, including escaped percent")
		AssertEqual(Vector["slot"], HasSlot, "only a supported unescaped slot grants format admission")
	}
}

_MM_InertCaptionRefusals() {
	_MM_WithInertCaption(_MM_InertCaptionRefusalsBody)
}

_MM_InertCaptionRefusalsBody(Key, Corpus, Root) {
	AssertFalse(MenuRenderer_TemplateRows(Key, Map(), Map(), Map()))
	AssertFalse(MenuRenderer_TemplateRows(Key, Map(), Map("native_detail", (*) => 7), Map()))
	AssertFalse(MenuRenderer_TemplateRows(Key, Map(), Map("native_detail", (*) => false), Map()))
	AssertFalse(MenuRenderer_TemplateRows(Key, Map(), Map("native_detail", (*) => Map()), Map()))
	Root[Key][1]["caption_getter"] := ""
	try AssertFalse(MenuRenderer_TemplateRows(Key, Map(), Map(), Map()))
	finally Root[Key][1]["caption_getter"] := "native_detail"
	AssertTrue(MenuRenderer_TemplateRows(Key, Map(), Map("native_detail", (*) => Corpus["value"]), Map()) is Array,
		"repair restores the original native declaration")
}

Test("inert captions: raw static labels and headers refuse before native getter", _MM_InertCaptionSourceFormat)

_MM_InertCaptionSourceFormat() {
	_MM_WithInertCaption(_MM_InertCaptionSourceFormatBody)
}

_MM_InertCaptionSourceFormatBody(Key, Corpus, Root) {
	for Kind in ["label", "section_header"] {
		Calls := Map("count", 0)
		Root[Key] := [Map("type", Kind, "id", "static", "i18n", "button.ok", "caption_getter", "native_detail")]
		Getters := Map("native_detail", _MM_InertCaptionCount.Bind(Calls, Corpus["value"]))
		AssertFalse(MenuRenderer_TemplateRows(Key, Map(), Getters, Map()))
		AssertEqual(0, Calls["count"], "raw static translation refuses before the native caption getter")
		Root[Key][1]["i18n"] := "menu.llm.model_backend"
		AssertTrue(MenuRenderer_TemplateRows(Key, Map(), Getters, Map()) is Array,
			"restoring the genuine supported format repairs native admission")
		AssertEqual(1, Calls["count"])
	}
}

_MM_InertCaptionCount(Calls, Value) {
	Calls["count"] += 1
	return Value
}
