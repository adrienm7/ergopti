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

_MM_WithCaptionLayout(Body) {
	global _SharedDir
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\inert_caption_layouts.json", "UTF-8"))
	Root := _MR_GetManifestRoot(), Key := "inert_layout_fixture"
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

_MM_CaptionLayoutRows() {
	for Code in ["en", "fr"]
		_LBMD_WithHardwareLocale(Code, _MM_WithCaptionLayout.Bind(_MM_CaptionLayoutRowsBody.Bind(Code)))
}

_MM_CaptionLayoutRowsBody(Code, Key, Corpus, Root) {
	Rows := MenuRenderer_TemplateRows(Key, Map(), Map("native_detail", (*) => Corpus["value"]), Map())
	AssertTrue(Rows is Array)
	AssertEqual(2, Rows.Length)
	AssertEqual(Corpus["expected"][Code][1], Rows[1]["label"], "independent whole English/French prefix image")
	AssertEqual(Corpus["expected"][Code][2], Rows[2]["label"], "independent whole English/French suffix image")
	Native := Menu(), OriginalHandle := Native.Handle
	try {
		AssertEqual(2, MenuRenderer_AppendTemplate(Native, Key, Map(), Map("native_detail", (*) => Corpus["value"]), Map()))
		AssertEqual(OriginalHandle, Native.Handle)
		AssertEqual(2, TrayMenuItemCount(Native))
		AssertEqual(StrReplace(Rows[1]["label"], "&", "&&"), _MUR_LabelAt(Native, 0))
		AssertEqual(StrReplace(Rows[2]["label"], "&", "&&"), _MUR_LabelAt(Native, 1))
		loop 2 {
			State := DllCall("GetMenuState", "ptr", Native.Handle, "uint", A_Index - 1, "uint", 0x400, "uint")
			Assert(State != 0xFFFFFFFF, "the actual native flags receipt succeeds before disabled-bit inspection")
			Assert((State & 0x3) != 0, "the actual native label stays inert and greyed")
		}
	} finally {
		Native.Delete()
		MenuDispatcher_PruneMenu(Native)
	}
}
Test("inert caption layout: exact translated affixes, literal value, real disabled native Menu", _MM_CaptionLayoutRows)

_MM_CaptionLayoutRefusals() {
	_MM_WithCaptionLayout(_MM_CaptionLayoutRefusalsBody)
}

_MM_CaptionLayoutRefusalsBody(Key, Corpus, Root) {
	Calls := Map("getters", 0)
	Getters := Map("native_detail", _MM_LayoutRead.Bind(Calls, Corpus["value"]))
	for Mutation in [Map("caption_layout", "infix"), Map("caption_layout", 7), Map("caption_joiner", 7),
		Map("caption_joiner", "`n"), Map("type", "section_header"), Map("i18n", "future.unowned_caption"),
		Map("i18n", "menu.llm.hw_header")] {
		Root[Key] := [Corpus["rows"][1].Clone()]
		for Field, Value in Mutation
			Root[Key][1][Field] := Value
		AssertFalse(MenuRenderer_TemplateRows(Key, Map(), Getters, Map()))
		AssertEqual(0, Calls["getters"], "malformed metadata refuses before native getter work")
	}
	Root[Key] := Corpus["rows"]
	AssertFalse(MenuRenderer_TemplateRows(Key, Map(), Map(), Map()))
	AssertFalse(MenuRenderer_TemplateRows(Key, Map(), Map("native_detail", (*) => false), Map()))
	AssertFalse(MenuRenderer_TemplateRows(Key, Map(), Map("native_detail", (*) => 7), Map()))
	AssertFalse(MenuRenderer_TemplateRows(Key, Map(), Map("native_detail", (*) => Map()), Map()))
	AssertTrue(MenuRenderer_TemplateRows(Key, Map(), Getters, Map()) is Array)
	AssertEqual(2, Calls["getters"], "same genuine declaration repair restores the two readers")
}

_MM_LayoutRead(Calls, Value, *) {
	Calls["getters"] += 1
	return Value
}
Test("inert caption layout: malformed declaration and invalid native receipts refuse, exact repair", _MM_CaptionLayoutRefusals)

; The complete declared append leaves the native destination and leading separator intact.
_MM_AppendTemplateAdmitsWholeTreeBeforeDrawing() {
	global _MenuDispatchCallbacks
	Native := Menu(), FirstChild := false, Released := Map(), Calls := Map("actions", 0, "foreign", 0)
	Callback := (*) => Calls["actions"] += 1
	First := Map("label", "Hand original child", "action", Callback, "checked", true)
	Children := [First]
	try {
		OriginalHandle := Native.Handle
		AssertEqual(1, RegisterMenuItem(Native, "Existing owned destination", Callback))
		AssertEqual(1, MenuRenderer_AppendTemplate(Native, "personal_shortcuts_frame", Map(), Map(),
			Map("personal_shortcuts_registered", Children)))
		AssertEqual(OriginalHandle, Native.Handle, "the declared append keeps the exact native object")
		AssertEqual(3, DllCall("GetMenuItemCount", "ptr", Native.Handle, "int"))
		AssertEqual("Existing owned destination", _MUR_LabelAt(Native, 0))
		AssertTrue(TrayMenuIsSeparatorAt(Native, 1), "existing leading-separator semantics remain literal")
		FirstChild := MenuFromHandle(DllCall("GetSubMenu", "ptr", Native.Handle, "int", 2, "ptr"))
		ChildId := DllCall("GetMenuItemID", "ptr", FirstChild.Handle, "int", 0, "uint")
		Assert(_MenuDispatchCallbacks.Has(ChildId) && _MenuDispatchCallbacks[ChildId] == Callback,
			"the existing generic dispatcher retains the exact native command")
		ChildState := DllCall("GetMenuState", "ptr", FirstChild.Handle, "uint", 0, "uint", 0x400, "uint")
		Assert(ChildState != 0xFFFFFFFF, "the actual checked child flags receipt succeeds before bit inspection")
		Assert((ChildState & 0x8) != 0, "the exact supplied checked state reaches the native child")
		AssertEqual(0, Calls["actions"], "admission and drawing do not execute child commands")
		Before := DllCall("GetMenuItemCount", "ptr", Native.Handle, "int")
		AssertEqual(0, MenuRenderer_AppendTemplate(Native, "personal_shortcuts_frame", Map(), Map(),
			Map("personal_shortcuts_registered", [First, false])), "later malformed child cannot publish earlier siblings")
		AssertEqual(Before, DllCall("GetMenuItemCount", "ptr", Native.Handle, "int"))
		AssertEqual(0, MenuRenderer_AppendTemplate(Native, "missing_shortcut_template", Map(), Map(), Map()))
		AssertEqual(Before, DllCall("GetMenuItemCount", "ptr", Native.Handle, "int"))
		Cyclic := [], Nested := Map("label", "Cyclic", "items", Cyclic)
		Cyclic.Push(Nested)
		AssertEqual(0, MenuRenderer_AppendTemplate(Native, "personal_shortcuts_frame", Map(), Map(),
			Map("personal_shortcuts_registered", Cyclic)))
		AssertEqual(Before, DllCall("GetMenuItemCount", "ptr", Native.Handle, "int"))
		NamedChildren := [First]
		NamedChildren.DefineProp("Length", {Get: _MM_ForeignTemplateRead.Bind(Calls)})
		AssertEqual(0, MenuRenderer_AppendTemplate(Native, "personal_shortcuts_frame", Map(), Map(),
			Map("personal_shortcuts_registered", NamedChildren)))
		NamedRow := Map("label", "Unadmitted row")
		NamedRow.DefineProp("Has", {Get: _MM_ForeignTemplateRead.Bind(Calls)})
		AssertEqual(0, MenuRenderer_AppendTemplate(Native, "personal_shortcuts_frame", Map(), Map(),
			Map("personal_shortcuts_registered", [NamedRow])))
		AssertEqual(0, Calls["foreign"], "intrinsic admission never invokes foreign container hooks")
		AssertEqual(Before, DllCall("GetMenuItemCount", "ptr", Native.Handle, "int"))
		AssertEqual(0, Calls["actions"])
		AssertEqual(1, MenuRenderer_AppendTemplate(Native, "personal_shortcuts_frame", Map(), Map(),
			Map("personal_shortcuts_registered", Children)), "same current declared data repairs the refusal")
		AssertEqual(Before + 1, DllCall("GetMenuItemCount", "ptr", Native.Handle, "int"),
			"the original native duplicate-label update replaces the group while adding its separator")
		_MenuDispatchCallbacks[ChildId].Call()
		AssertEqual(1, Calls["actions"], "the genuine retained dispatcher invokes only the original child callback")
	} finally {
		if FirstChild is Menu
			_CTC_ReleaseMenu(FirstChild, Released)
		_CTC_ReleaseMenu(Native, Released)
	}
}

_MM_ForeignTemplateRead(Calls, *) {
	Calls["foreign"] += 1
	throw Error("foreign native container property must not be read")
}
Test("shortcut template: complete native admission, same handle and leading separators", _MM_AppendTemplateAdmitsWholeTreeBeforeDrawing)

Test("declared parent: real and empty Menu children retain their native handles", _GR_NativeChildren)
Test("declared parent: checked predicates read once and keep the existing Boolean contract", _GR_CheckedPolicy)
Test("declared parent: withdrawn, foreign, ambiguous and nonnative children refuse", _GR_Refusals)

; Installs an independent declaration while retaining the actual physical manifest owner.
_GR_WithDeclaredParent(Body) {
	Root := _MR_GetManifestRoot(), Key := "_test_finished_group_parent"
	Present := Root.Has(Key), Previous := Present ? Root[Key] : false
	try {
		Root[Key] := [Map("type", "group", "id", "parent", "i18n", "menu.global.language",
			"checked_when", ["enabled"])]
		Body.Call(Key, Root)
	} finally {
		if Present
			Root[Key] := Previous
		else
			Root.Delete(Key)
	}
}

_GR_NativeChildren() {
	_GR_WithDeclaredParent((Key, Root) => _GR_CheckChildren(Key, Root))
}

_GR_CheckChildren(Key, Root) {
	Child := Menu(), Parent := Menu(), Calls := Map("count", 0)
	try {
		Child.Add("Native child", (*) => Calls["count"] += 1)
		Row := MenuRenderer_GroupRow(Key, "parent", Child, Map("enabled", () => false))
		AssertTrue(Row is Map, "the genuine declared group must project")
		AssertTrue(Row["submenu"] == Child, "the finished Menu is retained by identity")
		AssertEqual(t("menu.global.language"), Row["label"])
		AssertFalse(Row.Has("items"), "the finished subtree is not provider data")
		AssertEqual(1, _MR_RenderRows(Parent, [Row], Key, 1))
		AssertEqual(Child.Handle, DllCall("GetSubMenu", "ptr", Parent.Handle, "int", 0, "ptr"))
		AssertEqual(0, Calls["count"], "projection and rendering do not run the native child")
		Empty := Menu()
		try {
			EmptyRow := MenuRenderer_GroupRow(Key, "parent", Empty, Map("enabled", () => false))
			AssertTrue(EmptyRow["submenu"] == Empty, "a genuine empty native subtree remains valid")
			AssertEqual(0, TrayMenuItemCount(Empty))
		} finally Empty.Delete()
	} finally {
		try Parent.Delete()
		finally {
			MenuDispatcher_PruneMenu(Parent)
			Child.Delete()
		}
	}
}

_GR_CheckedPolicy() {
	_GR_WithDeclaredParent((Key, Root) => _GR_CheckStates(Key, Root))
}

_GR_CheckStates(Key, Root) {
	Child := Menu()
	try {
		for State in [true, false] {
			Reads := Map("count", 0)
			Getter := _GR_ReadState.Bind(Reads, State)
			Row := MenuRenderer_GroupRow(Key, "parent", Child, Map("enabled", Getter))
			AssertEqual(State, Row["checked"])
			AssertEqual(1, Reads["count"], "the declared singleton getter runs once")
			AssertEqual(State, MenuRenderer_ResolveCheckedWhen(Key, "parent", Map("enabled", Getter)))
		}
		Root[Key][1].Delete("checked_when")
		AssertFalse(MenuRenderer_GroupRow(Key, "parent", Child).Has("checked"))
	} finally Child.Delete()
}

_GR_ReadState(Reads, State) {
	Reads["count"] += 1
	return State
}

_GR_Refusals() {
	_GR_WithDeclaredParent((Key, Root) => _GR_CheckRefusals(Key, Root))
}

_GR_CheckRefusals(Key, Root) {
	Child := Menu(), Reads := Map("count", 0)
	Getters := Map("enabled", _GR_ReadState.Bind(Reads, true))
	try {
		AssertFalse(MenuRenderer_GroupRow(Key, "missing", Child, Getters))
		AssertFalse(MenuRenderer_GroupRow(Key, "parent", Map(), Getters))
		Root[Key][1]["platforms"] := ["hs"]
		AssertFalse(MenuRenderer_GroupRow(Key, "parent", Child, Getters))
		Root[Key][1].Delete("platforms")
		Root[Key].Push(Root[Key][1])
		AssertFalse(MenuRenderer_GroupRow(Key, "parent", Child, Getters))
		Root[Key].Pop()
		Root[Key][1]["type"] := "command"
		AssertFalse(MenuRenderer_GroupRow(Key, "parent", Child, Getters))
		Root[Key][1]["type"] := "GROUP"
		AssertFalse(MenuRenderer_GroupRow(Key, "parent", Child, Getters), "canonical group kind remains case-exact")
		AssertEqual(0, Reads["count"], "refused declarations never call state readers")
	} finally Child.Delete()
}

Test("declared parent: physical TapHold captions read once and retain EN/FR literal data", _GR_PhysicalCaptions)

_GR_PhysicalCaptions() {
	global _I18nCache, _I18nCacheLoaded, _SharedDir
	HadCache := IsSet(_I18nCache), PreviousCache := HadCache ? _I18nCache : false
	HadLoaded := IsSet(_I18nCacheLoaded), PreviousLoaded := HadLoaded ? _I18nCacheLoaded : false
	Child := Menu()
	try {
		for Code in ["en", "fr"] {
			_I18nCache := JsonParse(FileRead(_SharedDir . "\data\locales\" . Code . ".json", "UTF-8"))
			_I18nCacheLoaded := true
			Reads := Map("count", 0)
			Getters := Map("tap_hold_key_delay_caption", _GR_ReadCaption.Bind(Reads, "12% / 🦀"))
			Row := MenuRenderer_GroupRow("tap_hold_key_delay_tail", "tap_hold_key_delay", Child, Getters)
			AssertTrue(Row is Map, "the physical canonical caption group must project")
			AssertEqual(Code == "en" ? "Tap delay: 12% / 🦀" : "Délai de tap : 12% / 🦀", Row["label"])
			AssertEqual(1, Reads["count"])
			AssertTrue(Row["submenu"] == Child)
			AssertFalse(MenuRenderer_GroupRow("tap_hold_key_delay_tail", "tap_hold_key_delay", Child, Map()))
			AssertFalse(MenuRenderer_GroupRow("tap_hold_key_delay_tail", "tap_hold_key_delay", Child,
				Map("tap_hold_key_delay_caption", (*) => 17)))
			AssertTrue(MenuRenderer_GroupRow("tap_hold_key_delay_tail", "tap_hold_key_delay", Child, Getters) is Map,
				"explicit repair restores the genuine source-selected caption")
		}
		AssertFalse(MenuRenderer_GroupRow(Map(), "tap_hold_key_delay", Child, Map()))
		AssertFalse(MenuRenderer_GroupRow("tap_hold_key_delay_tail", Map(), Child, Map()))
	} finally {
		try Child.Delete()
		finally {
			if HadCache
				_I18nCache := PreviousCache
			else
				_I18nCache := unset
			if HadLoaded
				_I18nCacheLoaded := PreviousLoaded
			else
				_I18nCacheLoaded := unset
		}
	}
}

_GR_ReadCaption(Reads, Value) {
	Reads["count"] += 1
	return Value
}

Test("declared parent: authentic physical group captions retain getter and Menu identity", _GR_PhysicalCaptionPolicy)

_GR_PhysicalCaptionPolicy() {
	global _SharedDir, _I18nCache, _I18nCacheLoaded
	HadCache := IsSet(_I18nCache), PreviousCache := HadCache ? _I18nCache : false
	HadLoaded := IsSet(_I18nCacheLoaded), PreviousLoaded := HadLoaded ? _I18nCacheLoaded : false
	Child := Menu()
	try {
		for Language, Expected in Map("en", "Tap delay: 12% / 🦀", "fr", "Délai de tap : 12% / 🦀") {
			_I18nCache := JsonParse(FileRead(_SharedDir . "\data\locales\" . Language . ".json", "UTF-8"))
			_I18nCacheLoaded := true
			Calls := Map("count", 0)
			Getter := _MM_InertCaptionCount.Bind(Calls, "12% / 🦀")
			AssertFalse(MenuRenderer_GroupRow("tap_hold_key_delay_tail", "tap_hold_key_delay", Child, Map()),
				"the published caption requires its actual named native getter")
			Row := MenuRenderer_GroupRow("tap_hold_key_delay_tail", "tap_hold_key_delay", Child,
				Map("tap_hold_key_delay_caption", Getter))
			AssertTrue(Row is Map)
			AssertEqual(Expected, Row["label"], "handwritten complete caption with literal native percent")
			AssertEqual(1, Calls["count"], "the genuine physical caption getter is read once")
			AssertTrue(Row["submenu"] == Child, "the genuine empty Menu is not rebuilt")
			AssertFalse(MenuRenderer_GroupRow("tap_hold_key_delay_tail", "tap_hold_key_delay", Child,
				Map("tap_hold_key_delay_caption", (*) => 7)), "nonstrings cannot become parent captions")
		}
	} finally {
		try Child.Delete()
		finally {
			if HadCache
				_I18nCache := PreviousCache
			else
				_I18nCache := unset
			if HadLoaded
				_I18nCacheLoaded := PreviousLoaded
			else
				_I18nCacheLoaded := unset
		}
	}
}

Test("declared affixes: physical EN/FR source, current command and same native group", _DA_PhysicalRows)
Test("declared affixes: invalid source refuses before native child builder", _DA_InvalidGroupSource)

_DA_WithPhysicalFrame(Body) {
	global _SharedDir, _I18nCache, _I18nCacheLoaded
	Root := _MR_GetManifestRoot(), Key := "_test_command_group_affix"
	Present := Root.Has(Key), Previous := Present ? Root[Key] : false
	HadCache := IsSet(_I18nCache), PreviousCache := HadCache ? _I18nCache : false
	HadLoaded := IsSet(_I18nCacheLoaded), PreviousLoaded := HadLoaded ? _I18nCacheLoaded : false
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\command_group_caption_layouts.json", "UTF-8"))
	try {
		Root[Key] := Corpus["rows"]
		for Language in ["en", "fr"] {
			_I18nCache := JsonParse(FileRead(_SharedDir . "\data\locales\" . Language . ".json", "UTF-8"))
			_I18nCacheLoaded := true
			Body.Call(Key, Root, Corpus, Language)
		}
	} finally {
		try {
			if Present
				Root[Key] := Previous
			else
				Root.Delete(Key)
		} finally {
			if HadCache
				_I18nCache := PreviousCache
			else
				_I18nCache := unset
			if HadLoaded
				_I18nCacheLoaded := PreviousLoaded
			else
				_I18nCacheLoaded := unset
		}
	}
}

_DA_PhysicalRows() {
	_DA_WithPhysicalFrame(_DA_CheckRows)
}

_DA_CheckRows(Key, Root, Corpus, Language) {
	Counts := Map("caption", 0, "command", 0, "child", 0), Pause := Map("value", false)
	Child := Menu(), Parent := Menu()
	Getters := Map("personal_default_label", _DA_ReadCaption.Bind(Counts, Corpus["value"]),
		"personal_shortcut_label", _DA_ReadCaption.Bind(Counts, Corpus["value"]),
		"enabled", () => false, "not_paused", () => !Pause["value"])
	Action := _DA_RunCommand.Bind(Counts)
	Commands := Map("personal_legacy_shortcut", Action, "shortcut_suffix", Action)
	try {
		Group := MenuRenderer_GroupRow(Key, "personal_default_parent", Child, Getters)
		AssertTrue(Group is Map)
		AssertEqual(Corpus["expected"][Language][1], Group["label"])
		AssertTrue(Group["submenu"] == Child)
		AssertEqual(false, Group["checked"])
		Command := MenuRenderer_CommandRow(Key, "personal_legacy_shortcut", Commands, Getters)
		AssertEqual(Corpus["expected"][Language][2], Command["label"])
		AssertEqual(2, Counts["caption"], "selected actual data getters are evaluated once")
		AssertEqual(0, Counts["command"])
		Rows := MenuRenderer_TemplateRows(Key, Commands, Getters,
			Map("personal_default_parent", [], "default_suffix", []))
		for Index, Row in Rows
			AssertEqual(Corpus["expected"][Language][Index], Row["label"])
		AssertEqual(6, Counts["caption"], "template does not reevaluate an explicit command caption")
		AssertEqual(0, Counts["command"])
		AssertEqual("native-result", Command["action"].Call())
		Pause["value"] := true
		AssertFalse(Command["action"].Call(), "retained native callback rechecks the original pause readiness")
		AssertEqual(1, Counts["command"])
		Pause["value"] := false
		Counts["caption"] := 0
		MenuRenderer_Build(Key, "Hotstrings", Map(),
			Map("personal_default_parent", _DA_BuildChild.Bind(Counts, Child), "default_suffix", _DA_BuildChild.Bind(Counts, Child)),
			Map(), Commands, Getters, Parent)
		AssertEqual(4, Counts["caption"])
		AssertEqual(2, Counts["child"])
		AssertEqual(4, TrayMenuItemCount(Parent))
		AssertEqual(Child.Handle, DllCall("GetSubMenu", "ptr", Parent.Handle, "int", 0, "ptr"))
		AssertEqual(Child.Handle, DllCall("GetSubMenu", "ptr", Parent.Handle, "int", 2, "ptr"))
	} finally {
		try Parent.Delete()
		finally {
			MenuDispatcher_PruneMenu(Parent)
			Child.Delete()
		}
	}
}

_DA_ReadCaption(Counts, Value) {
	Counts["caption"] += 1
	return Value
}

_DA_RunCommand(Counts, *) {
	Counts["command"] += 1
	return "native-result"
}

_DA_BuildChild(Counts, Child) {
	Counts["child"] += 1
	return Child
}

_DA_InvalidGroupSource() {
	_DA_WithPhysicalFrame(_DA_CheckRefusedSource)
}

_DA_CheckRefusedSource(Key, Root, Corpus, Language) {
	Counts := Map("caption", 0, "child", 0), Child := Menu(), Parent := Menu()
	Rows := Root[Key], PreviousKey := Rows[1]["i18n"]
	try {
		Root[Key] := [Rows[1]]
		Rows[1]["i18n"] := "future.unowned_caption"
		Getters := Map("personal_default_label", _DA_ReadCaption.Bind(Counts, Corpus["value"]))
		AssertFalse(MenuRenderer_GroupRow(Key, "personal_default_parent", Child, Getters))
		MenuRenderer_Build(Key, "Hotstrings", Map(),
			Map("personal_default_parent", _DA_BuildChild.Bind(Counts, Child)), Map(), Map(), Getters, Parent)
		AssertEqual(0, Counts["caption"])
		AssertEqual(0, Counts["child"], "unowned source refuses before calling a genuine native child builder")
		AssertEqual(0, TrayMenuItemCount(Parent))
	} finally {
		Rows[1]["i18n"] := PreviousKey
		Root[Key] := Rows
		try Parent.Delete()
		finally {
			MenuDispatcher_PruneMenu(Parent)
			Child.Delete()
		}
	}
}

; The optional flag is preflight admission only. It does not certify dispatch publication.
_MM_PersonalAppendAdmissionSeparatesEmptyAndRefused() {
	global _MenuDispatchCallbacks
	Root := _MR_GetManifestRoot(), Key := "hotstring_personal_directory_frame"
	AssertTrue(Root is Map && Root.Has(Key), "the genuine complete directory declaration exists")
	SavedDefinition := Root[Key], Native := Menu(), Calls := Map("actions", 0)
	Callback := (*) => Calls["actions"] += 1
	try {
		AssertEqual(1, RegisterMenuItem(Native, "Existing personal destination", Callback))
		Handle := Native.Handle, Before := TrayMenuItemCount(Native)
		BeforeCallbacks := _MenuDispatchCallbacks.Clone()
		Getters := Map("personal_folder_file_boundary", (*) => false)
		EmptyChildren := Map("personal_folders", (*) => [], "personal_files", (*) => [])
		Admitted := "old caller value"
		AssertEqual(0, MenuRenderer_AppendTemplate(Native, Key, Map(), Getters, EmptyChildren, &Admitted))
		AssertTrue(Admitted, "a genuine complete empty provider tree is admitted without claiming native publication")
		AssertEqual(0, MenuRenderer_AppendTemplate(Native, Key, Map(), Getters, EmptyChildren), "the existing five-argument count remains zero")
		AssertEqual(Handle, Native.Handle)
		AssertEqual(Before, TrayMenuItemCount(Native), "an admitted empty directory changes no native item")
		Root.Delete(Key)
		Admitted := true
		AssertEqual(0, MenuRenderer_AppendTemplate(Native, Key, Map(), Getters, EmptyChildren, &Admitted))
		AssertFalse(Admitted, "withdrawal is distinguished from the same valid empty count")
		AssertEqual(Before, TrayMenuItemCount(Native))
		Root[Key] := SavedDefinition
		Child := Map("label", "Hand supplied child", "action", Callback)
		Admitted := true
		AssertEqual(0, MenuRenderer_AppendTemplate(Native, Key, Map(), Getters,
			Map("personal_folders", (*) => [], "personal_files", (*) => [Child, false]), &Admitted))
		AssertFalse(Admitted, "a malformed later child refuses the whole tree before earlier siblings draw")
		AssertEqual(Before, TrayMenuItemCount(Native))
		AssertEqual(Handle, Native.Handle)
		AssertEqual(0, Calls["actions"], "preflight and empty/refused append do not invoke callbacks")
		AssertEqual(BeforeCallbacks.Count, _MenuDispatchCallbacks.Count)
		for Id, Previous in BeforeCallbacks
			AssertTrue(_MenuDispatchCallbacks.Has(Id) && _MenuDispatchCallbacks[Id] == Previous,
				"all original native callback identities remain exact")
	} finally {
		Root[Key] := SavedDefinition
		try Native.Delete()
		finally MenuDispatcher_PruneMenu(Native)
	}
}
Test("personal directory: admitted empty versus withdrawn or malformed whole native tree", _MM_PersonalAppendAdmissionSeparatesEmptyAndRefused)

; Literal command decoration is admitted before native getters or menu publication.
_CLP_WithPhysicalFrame(Body) {
	global _SharedDir, _I18nCache, _I18nCacheLoaded
	Root := _MR_GetManifestRoot(), Key := "_test_command_literal_prefix", Legacy := Key . "_legacy"
	HadKey := Root.Has(Key), Previous := HadKey ? Root[Key] : false
	HadLegacy := Root.Has(Legacy), PreviousLegacy := HadLegacy ? Root[Legacy] : false
	HadCache := IsSet(_I18nCache), PreviousCache := HadCache ? _I18nCache : false
	HadLoaded := IsSet(_I18nCacheLoaded), PreviousLoaded := HadLoaded ? _I18nCacheLoaded : false
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\command_literal_prefixes.json", "UTF-8"))
	try {
		for Language in ["en", "fr"] {
			Root[Key] := Corpus["rows"]
			Root[Legacy] := [Corpus["legacy"]]
			_I18nCache := JsonParse(FileRead(_SharedDir . "\data\locales\" . Language . ".json", "UTF-8"))
			_I18nCacheLoaded := true
			Body.Call(Key, Legacy, Root, Corpus, Language)
		}
	} finally {
		try {
			if HadKey
				Root[Key] := Previous
			else if Root.Has(Key)
				Root.Delete(Key)
			if HadLegacy
				Root[Legacy] := PreviousLegacy
			else if Root.Has(Legacy)
				Root.Delete(Legacy)
		} finally {
			if HadCache
				_I18nCache := PreviousCache
			else
				_I18nCache := unset
			if HadLoaded
				_I18nCacheLoaded := PreviousLoaded
			else
				_I18nCacheLoaded := unset
		}
	}
}

_CLP_PhysicalRows() {
	_CLP_WithPhysicalFrame(_CLP_CheckRows)
}

_CLP_CheckRows(Key, Legacy, Root, Corpus, Language) {
	Counts := Map("caption", 0, "command", 0), Native := Menu(), SavedRows := Root[Key]
	Action := _DA_RunCommand.Bind(Counts), Commands := Map("legacy", Action)
	for Item in Corpus["rows"]
		Commands[Item["id"]] := Action
	Getters := Map("detail", _DA_ReadCaption.Bind(Counts, Corpus["value"]))
	try {
		for Index, Item in Corpus["rows"] {
			Row := MenuRenderer_CommandRow(Key, Item["id"], Commands, Getters)
			AssertTrue(Row is Map)
			AssertEqual(Corpus["expected"][Language][Index], Row["label"])
		}
		AssertEqual(2, Counts["caption"])
		AssertEqual(0, Counts["command"])
		Rows := MenuRenderer_TemplateRows(Key, Commands, Getters, Map())
		AssertEqual(7, Rows.Length, "all seven independent caption vectors remain in the canonical data tree")
		for Index, Row in Rows
			AssertEqual(Corpus["expected"][Language][Index], Row["label"])
		AssertEqual(4, Counts["caption"], "the final explicit caption is prefixed exactly once")
		LegacyRows := MenuRenderer_TemplateRows(Legacy, Commands, Getters, Map())
		AssertEqual(Corpus["legacy_expected"][Language], LegacyRows[1]["label"], "legacy caption overwrite keeps literal indentation")
		AssertEqual(5, Counts["caption"])
		Selected := MenuRenderer_CommandRow(Key, "indented", Commands, Getters)
		AssertEqual("native-result", Selected["action"].Call())
		AssertEqual(1, Counts["command"])
		; Equal labels update an existing AHK item. Isolate each unchanged hand vector.
		NativeCount := 0
		for Index, Caption in Corpus["expected"][Language] {
			Root[Key] := [Corpus["rows"][Index]]
			MenuRenderer_Build(Key, "Hotstrings", Map(), Map(), Map(), Commands, Getters, Native)
			AssertEqual(1, TrayMenuItemCount(Native), "each original declaration publishes exactly one native caption")
			NativeCount += TrayMenuItemCount(Native)
			AssertEqual(Caption, _CLP_NativeCaption(Native, 1))
			try Native.Delete()
			finally MenuDispatcher_PruneMenu(Native)
		}
		AssertEqual(7, NativeCount)
		AssertEqual(7, Counts["caption"])
		AssertEqual(1, Counts["command"], "native construction does not deliver commands")
	} finally {
		Root[Key] := SavedRows
		try Native.Delete()
		finally {
			try MenuDispatcher_PruneMenu(Native)
			finally Native := unset
		}
	}
}

_CLP_NativeCaption(Native, Position) {
	BufferValue := Buffer(1024, 0)
	Length := DllCall("GetMenuStringW", "ptr", Native.Handle, "uint", Position - 1,
		"ptr", BufferValue.Ptr, "int", 512, "uint", 0x400, "int")
	return StrGet(BufferValue.Ptr, Length, "UTF-16")
}

_CLP_Refusal() {
	_CLP_WithPhysicalFrame(_CLP_CheckRefusedPrefix)
}

_CLP_CheckRefusedPrefix(Key, Legacy, Root, Corpus, Language) {
	global JSON_NULL, _MenuDispatchCallbacks
	Native := Menu(), Counts := Map("caption", 0, "command", 0)
	Action := _DA_RunCommand.Bind(Counts), Commands := Map()
	for Item in Corpus["rows"]
		Commands[Item["id"]] := Action
	Getters := Map("detail", _DA_ReadCaption.Bind(Counts, Corpus["value"]))
	OriginalRows := Root[Key], OriginalPrefix := OriginalRows[6]["label_prefix"]
	try {
		AssertEqual(1, RegisterMenuItem(Native, "Existing caller-owned destination", Action))
		Handle := Native.Handle, Before := TrayMenuItemCount(Native), PreviousCallbacks := _MenuDispatchCallbacks.Clone()
		for Prefix in [false, 7, Map(), JSON_NULL, "`n", "`t", Chr(0x7F), Chr(0xD800), Chr(0xDC00)] {
			OriginalRows[6]["label_prefix"] := Prefix
			AssertFalse(MenuRenderer_CommandRow(Key, "affix", Commands, Getters))
			AssertFalse(MenuRenderer_TemplateRows(Key, Commands, Getters, Map()))
			Admitted := true
			AssertEqual(0, MenuRenderer_AppendTemplate(Native, Key, Commands, Getters, Map(), &Admitted))
			AssertFalse(Admitted, "malformed later command refuses the whole native append before drawing")
			AssertEqual(Before, TrayMenuItemCount(Native))
			AssertEqual(Handle, Native.Handle)
			AssertEqual(0, Counts["caption"])
			AssertEqual(0, Counts["command"])
		}
		OriginalRows[6]["label_prefix"] := OriginalPrefix
		for Kind in ["check", "group", "label", "section_header", "list", "---", "choice"] {
			Root[Key] := [Map("type", Kind, "id", "foreign", "i18n", "menu.hotstrings.magic_key_reset", "label_prefix", "")]
			AssertFalse(MenuRenderer_TemplateRows(Key, Commands, Getters, Map()))
		}
		Root.Delete(Key)
		AssertFalse(MenuRenderer_CommandRow(Key, "affix", Commands, Getters))
		Admitted := true
		AssertEqual(0, MenuRenderer_AppendTemplate(Native, Key, Commands, Getters, Map(), &Admitted))
		AssertFalse(Admitted)
		AssertEqual(Before, TrayMenuItemCount(Native))
		AssertEqual(PreviousCallbacks.Count, _MenuDispatchCallbacks.Count)
		for Id, Callback in PreviousCallbacks
			AssertTrue(_MenuDispatchCallbacks.Has(Id) && _MenuDispatchCallbacks[Id] == Callback)
	} finally {
		OriginalRows[6]["label_prefix"] := OriginalPrefix
		Root[Key] := OriginalRows
		try Native.Delete()
		finally MenuDispatcher_PruneMenu(Native)
	}
}

_CLP_DisabledStandIn() {
	_CLP_WithPhysicalFrame(_CLP_CheckDisabledStandIn)
}

_CLP_CheckDisabledStandIn(Key, Legacy, Root, Corpus, Language) {
	Native := Menu(), Counts := Map("caption", 0, "command", 0), SourceRow := Root[Key][6]
	HadDisabled := SourceRow.Has("disabled_when"), PreviousDisabled := HadDisabled ? SourceRow["disabled_when"] : false
	HadReason := SourceRow.Has("disabled_reason_key"), PreviousReason := HadReason ? SourceRow["disabled_reason_key"] : false
	try {
		Root[Key] := [SourceRow]
		SourceRow["disabled_when"] := ["ready"]
		SourceRow["disabled_reason_key"] := "menu.hotstrings.personal_file_unavailable"
		Getters := Map("detail", _DA_ReadCaption.Bind(Counts, Corpus["value"]), "ready", (*) => false)
		Commands := Map("affix", _DA_RunCommand.Bind(Counts))
		Row := MenuRenderer_CommandRow(Key, "affix", Commands, Getters)
		AssertEqual(Corpus["expected"][Language][6], Row["label"])
		AssertTrue(Row["disabled"])
		AssertFalse(Row.Has("action"))
		MenuRenderer_Build(Key, "Hotstrings", Map(), Map(), Map(), Commands, Getters, Native)
		AssertEqual(Corpus["disabled_expected"][Language], _CLP_NativeCaption(Native, 1))
		AssertEqual(0, Counts["command"])
	} finally {
		if HadDisabled
			SourceRow["disabled_when"] := PreviousDisabled
		else
			SourceRow.Delete("disabled_when")
		if HadReason
			SourceRow["disabled_reason_key"] := PreviousReason
		else
			SourceRow.Delete("disabled_reason_key")
		Root[Key] := Corpus["rows"]
		try Native.Delete()
		finally MenuDispatcher_PruneMenu(Native)
	}
}

Test("literal command prefixes: hand EN/FR selected, template, legacy and actual native images", _CLP_PhysicalRows)
Test("literal command prefixes: typed Unicode and whole-append refusal preserve exact native target", _CLP_Refusal)
Test("literal command prefixes: disabled-reason stand-ins retain final caption and no action", _CLP_DisabledStandIn)

_CLP_PlatformStandIn() {
	_CLP_WithPhysicalFrame(_CLP_CheckPlatformStandIn)
}

_CLP_CheckPlatformStandIn(Key, Legacy, Root, Corpus, Language) {
	Native := Menu(), Counts := Map("caption", 0, "command", 0), SourceRow := Root[Key][3]
	HadPlatforms := SourceRow.Has("platforms"), PreviousPlatforms := HadPlatforms ? SourceRow["platforms"] : false
	HadUnavailable := SourceRow.Has("unavailable"), PreviousUnavailable := HadUnavailable ? SourceRow["unavailable"] : false
	HadReason := SourceRow.Has("reason_key"), PreviousReason := HadReason ? SourceRow["reason_key"] : false
	try {
		Root[Key] := [SourceRow]
		SourceRow["platforms"] := ["hs"]
		SourceRow["unavailable"] := "grey"
		SourceRow["reason_key"] := "menu.hotstrings.personal_file_unavailable"
		Commands := Map("indented", _DA_RunCommand.Bind(Counts))
		MenuRenderer_Build(Key, "Hotstrings", Map(), Map(), Map(), Commands, Map(), Native)
		Expected := Corpus["expected"][Language][3] . " — " . (Language == "en" ? "Unavailable" : "Indisponible")
		AssertEqual(Expected, _CLP_NativeCaption(Native, 1))
		AssertEqual(1, TrayMenuItemCount(Native))
		AssertEqual(0, Counts["command"])
	} finally {
		if HadPlatforms
			SourceRow["platforms"] := PreviousPlatforms
		else
			SourceRow.Delete("platforms")
		if HadUnavailable
			SourceRow["unavailable"] := PreviousUnavailable
		else
			SourceRow.Delete("unavailable")
		if HadReason
			SourceRow["reason_key"] := PreviousReason
		else
			SourceRow.Delete("reason_key")
		Root[Key] := Corpus["rows"]
		try Native.Delete()
		finally MenuDispatcher_PruneMenu(Native)
	}
}
Test("literal command prefixes: platform-grey stand-in keeps the final native caption", _CLP_PlatformStandIn)

Test("shared Magic trigger rows retain native character and captions", _MTF_Captions)
Test("shared Magic trigger rows refuse withdrawn or malformed frame", _MTF_Refusal)

_MTF_Captions() {
	_CLP_WithPhysicalFrame(_MTF_CaptionRows)
}

_MTF_CaptionRows(Key, Legacy, Root, Corpus, Language) {
	global ScriptInformation
	HadInformation := IsSet(ScriptInformation)
	Prior := HadInformation ? ScriptInformation : false
	ScriptInformation := HadInformation ? Prior.Clone() : Map()
	try {
		for Character in ["★", "§"] {
			ScriptInformation["MagicKey"] := Character
			Rows := _HS_MagicKeyRows()
			AssertTrue(Rows is Array, "the actual Windows Magic provider returns row data")
			AssertEqual(Rows.Length, 1, "Windows retains one Magic editor row and no reset")
			Expected := Language = "en" ? "Magic key: " . Character : "Touche magique : " . Character
			AssertEqual(Rows[1]["label"], Expected, "actual native provider caption follows the independent image")
			AssertTrue(Rows[1].Get("action", false) is Func, "actual Magic editor callback remains bound")
			Built := Menu()
			try {
				AssertEqual(MenuRenderer_AppendRows(Built, "hotstrings_magic_trigger_frame", "magic_key_config_native", Rows), 1, "the real renderer consumes one genuine provider row")
				AssertEqual(DllCall("GetMenuItemCount", "Ptr", Built.Handle, "Int"), 1, "actual Win32 row count remains one")
				AssertEqual(_CLP_NativeCaption(Built, 1), Expected, "actual Win32 label retains exact translated character")
			} finally {
				try Built.Delete()
				finally MenuDispatcher_PruneMenu(Built)
			}
		}
	} finally {
		if HadInformation
			ScriptInformation := Prior
		else
			ScriptInformation := unset
	}
}

_MTF_Refusal() {
	_CLP_WithPhysicalFrame(_MTF_RefusedRows)
}

_MTF_RefusedRows(Key, Legacy, Root, Corpus, Language) {
	global ScriptInformation
	HadInformation := IsSet(ScriptInformation)
	Prior := HadInformation ? ScriptInformation : false
	try {
		ScriptInformation := HadInformation ? Prior.Clone() : Map()
		ScriptInformation["MagicKey"] := "★"
		Root := _MR_GetManifestRoot()
		Frame := Root.Get("hotstrings_magic_trigger_frame", false)
		AssertTrue(Frame is Array, "the genuine compiled Magic frame is present")
		Getter := Frame[1].Get("caption_getter", "")
		try {
			Root.Delete("hotstrings_magic_trigger_frame")
			AssertEqual(_HS_MagicKeyRows().Length, 0, "withdrawn source exposes no Magic editor action")
			Root["hotstrings_magic_trigger_frame"] := Frame
			Frame[1]["caption_getter"] := "unowned_magic_value"
			AssertEqual(_HS_MagicKeyRows().Length, 0, "missing genuine value getter refuses the entire provider")
			Frame[1]["caption_getter"] := Getter
			AssertEqual(_HS_MagicKeyRows().Length, 1, "exact source repair restores the original native provider")
		} finally {
			Root["hotstrings_magic_trigger_frame"] := Frame
			Frame[1]["caption_getter"] := Getter
		}
	} finally {
		if HadInformation
			ScriptInformation := Prior
		else
			ScriptInformation := unset
	}
}
