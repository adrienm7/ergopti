; tests/unit/infra/config/scope/test_personal_editor_menu_scope.ahk

; ==============================================================================
; MODULE: Personal Hotstrings Editor Menu Scope
; DESCRIPTION:
; Personal file admission, the shared personal editor command and its pause
; receipts, category file opening and the declared extension inventory
; replay the shared declarations through their native providers.
; ==============================================================================

#Requires AutoHotkey v2.0





; Every platform replays the same independent admission decisions.
_HSCS_PersonalAdmission(Vector) {
	Before := KL_JsonEncode(Vector)
	Admitted := PersonalScopeAdmit(Vector["inventory"], Vector["selected"], &Reason)
	if Vector.Has("refusal") {
		AssertFalse(Admitted)
		AssertEqual(Vector["refusal"], Reason)
	} else {
		Assert(Admitted is Map)
		AssertEqual("", Reason)
		AssertEqual(KL_JsonEncode(Vector["expected"]), KL_JsonEncode(Admitted))
		Assert(Admitted["source"] != Vector["selected"]["source"])
		Assert(Admitted["source"]["components"] != Vector["selected"]["source"]["components"])
	}
	AssertEqual(Before, KL_JsonEncode(Vector), "admission cannot mutate caller evidence")
}

for _HSCS_AdmissionVector in JsonParse(FileRead(_SharedDir . "\tests\corpus\hotstrings\personal_scope_admission.json", "UTF-8"))["vectors"]
	Test("personal-file-admission: " . _HSCS_AdmissionVector["name"], _HSCS_PersonalAdmission.Bind(_HSCS_AdmissionVector))


; A caller-owned native menu keeps its ordinary editor leaf and current pause
; owner. Callback observations are asserted after the dispatcher returns.
_HSCS_PersonalEditorDelivery(Vector) {
	global _MenuDispatchCallbacks
	if Vector["pause_receipt"] != "boolean" || !Vector["opener"]
		return
	State := Map("paused", Vector["initial_paused"], "calls", 0)
	Open(State, *) {
		State["calls"] += 1
		return true
	}
	Paused(State, *) => State["paused"]
	Built := Menu()
	try {
		Row := _HS_PersonalEditorRow(Open.Bind(State), Paused.Bind(State))
		Assert(Row is Map, "the canonical declaration must produce provider data")
		MenuRenderer_AppendRows(Built, "hotstrings_menu", "hotstring_personal", [Row])
		AssertEqual(1, TrayMenuItemCount(Built))
		AssertEqual(t("menu.hotstrings.open_editor"), _CTC_LabelAt(Built, 0))
		Flags := DllCall("GetMenuState", "Ptr", Built.Handle, "UInt", 0, "UInt", 0x400, "UInt")
		AssertEqual(!Vector["enabled"], (Flags & 0x3) != 0)
		Id := DllCall("GetMenuItemID", "Ptr", Built.Handle, "Int", 0, "UInt")
		Assert(_MenuDispatchCallbacks.Has(Id), "the real renderer must register the actual leaf callback")
		State["paused"] := Vector["delivered_paused"]
		_MenuDispatchCallbacks[Id].Call()
		AssertEqual(Vector["calls"], State["calls"], "the retained native callback obeys the live pause owner")
	} finally _CTC_ReleaseMenu(Built)
}

for _HSCS_EditorVector in JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\personal_editor_command.json", "UTF-8"))["vectors"] {
	if _HSCS_EditorVector["pause_receipt"] == "boolean" && _HSCS_EditorVector["opener"]
		Test("shared-personal-editor: " . _HSCS_EditorVector["name"], _HSCS_PersonalEditorDelivery.Bind(_HSCS_EditorVector))
}

_HSCS_PersonalEditorReadSite() {
	Body := _DriverFuncBody("_HS_PersonalRows")
	Assert(Body != "", "the actual personal provider must exist")
	AssertTrue(_HSCS_PersonalFrameDelegation(Body), "the actual captured editor row reaches the canonical whole-frame renderer")
	AssertContains(Body, "HS_TogglePersonalAllSections(Enabled, Options), PersonalMenu)",
		"the unchanged scope builder owns the still-empty native repaint target")
	Assert(!InStr(Body, 'Map("label", t("menu.hotstrings.open_editor")'), "the shared declaration owns the label")
}
Test("shared-personal-editor: the actual personal provider consumes its declaration", _HSCS_PersonalEditorReadSite)


_HSCS_PersonalEditorSharedLabel() {
	Root := _MR_GetManifestRoot()
	Assert(Root is Map)
	Declaration := Root["personal_hotstring_commands"]
	AssertEqual(1, Declaration.Length)
	Item := Declaration[1], Before := Item["i18n"], Built := Menu()
	try {
		Item["i18n"] := "menu.hotstrings.shortcut_none"
		Row := _HS_PersonalEditorRow((*) => true, (*) => false)
		MenuRenderer_AppendRows(Built, "hotstrings_menu", "hotstring_personal", [Row])
		AssertEqual(t("menu.hotstrings.shortcut_none"), _CTC_LabelAt(Built, 0), "the native row follows its shared label")
	} finally {
		Item["i18n"] := Before
		_CTC_ReleaseMenu(Built)
	}
}
Test("shared-personal-editor: the actual native provider follows a changed shared label", _HSCS_PersonalEditorSharedLabel)

_HSCS_PersonalEditorUnknownPause(Throws) {
	State := Map("calls", 0)
	Open(State, *) {
		State["calls"] += 1
		return true
	}
	Paused(Throws, *) {
		if Throws
			throw Error("injected native pause read failure")
		return Map("unconfirmed", true)
	}
	Built := Menu()
	try {
		Row := _HS_PersonalEditorRow(Open.Bind(State), Paused.Bind(Throws))
		AssertTrue(Row["disabled"], "a refused actual pause receipt cannot enable the editor")
		MenuRenderer_AppendRows(Built, "hotstrings_menu", "hotstring_personal", [Row])
		Id := DllCall("GetMenuItemID", "Ptr", Built.Handle, "Int", 0, "UInt")
		global _MenuDispatchCallbacks
		Assert(_MenuDispatchCallbacks.Has(Id))
		AssertFalse(_MenuDispatchCallbacks[Id].Call())
		AssertEqual(0, State["calls"])
	} finally _CTC_ReleaseMenu(Built)
}
for _HSCS_PauseThrows in [true, false]
	Test("shared-personal-editor: refused native pause owner " . _HSCS_PauseThrows,
		_HSCS_PersonalEditorUnknownPause.Bind(_HSCS_PauseThrows))


_HSCS_PersonalEditorUntypedPause(Value) {
	global _MenuDispatchCallbacks
	State := Map("calls", 0)
	Open(State, *) {
		State["calls"] += 1
		return true
	}
	Paused(Value, *) => Value
	Built := Menu()
	try {
		Row := _HS_PersonalEditorRow(Open.Bind(State), Paused.Bind(Value))
		AssertTrue(Row["disabled"], "only an actual native Integer pause receipt may enable the editor")
		MenuRenderer_AppendRows(Built, "hotstrings_menu", "hotstring_personal", [Row])
		Id := DllCall("GetMenuItemID", "Ptr", Built.Handle, "Int", 0, "UInt")
		Assert(_MenuDispatchCallbacks.Has(Id))
		AssertFalse(_MenuDispatchCallbacks[Id].Call())
		AssertEqual(0, State["calls"], "untyped zero cannot permit a retained callback")
	} finally _CTC_ReleaseMenu(Built)
}
for _HSCS_UntypedPause in ["0", "false", "", 0.0]
	Test("shared-personal-editor: untyped native pause receipt " . Type(_HSCS_UntypedPause) . ":" . _HSCS_UntypedPause,
		_HSCS_PersonalEditorUntypedPause.Bind(_HSCS_UntypedPause))


; Observe the native opening callback outside the renderer's caught delivery.
_HSCS_FileOpened(Observations, Path, Receipt, *) {
	Observations.Push(Path)
	return Receipt
}

_HSCS_FileCommand(Receipt) {
	global _MenuDispatchCallbacks
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\hotstring_file_command.json", "UTF-8"))
	Definition := _MR_GetMenuDef(Corpus["section"])
	AssertEqual(1, Definition.Length)
	Item := Definition[1]
	AssertEqual(Corpus["id"], Item["id"])
	AssertEqual(Corpus["i18n"], Item["i18n"])
	AssertEqual(Corpus["ready"], Item["disabled_when"][1])
	Label := Item["i18n"]
	Path := A_Temp . "\ergopti-category-command-" . A_TickCount . ".toml"
	Observations := [], Native := 0, Released := true
	try {
		Assert(FSWriteDurable(Path, "# owned category opening fixture`n"))
		AssertEqual(false, _HS_CategoryFileRow(Path, Map()), "an unknown supplied opening owner must refuse")
		Item["i18n"] := "menu.hotstrings.open_editor"
		Row := _HS_CategoryFileRow(Path, _HSCS_FileOpened.Bind(Observations, Path, Receipt))
		Assert(Row is Map, "the actual provider must admit the shared command")
		AssertEqual(t("menu.hotstrings.open_editor"), Row["label"],
			"native opening data comes from the declaration, not a private label")
		AssertEqual(Receipt, Row["action"].Call())
		AssertEqual(1, Observations.Length)
		AssertEqual(Path, Observations[1], "the actual opening owner receives its captured category source")
		Assert(Row["label"] != "", "the replacement declaration must name a native item")
		for Key in ["menu.hotstrings.scope_enable_all", "menu.hotstrings.scope_disable_all"]
			Assert(StrCompare(Row["label"], t(Key), false) != 0,
				"the file command must not replace an existing category caption")
		Native := _HS_CategoryMenu("Rolls", Path, [], (*) => false)
		AssertEqual(3, TrayMenuItemCount(Native), "two scope commands and the admitted file command are distinct native rows")
		AssertEqual(t("menu.hotstrings.scope_enable_all"), _SGM_LabelAt(Native, 0))
		AssertEqual(t("menu.hotstrings.scope_disable_all"), _SGM_LabelAt(Native, 1))
		EnableId := DllCall("GetMenuItemID", "Ptr", Native.Handle, "Int", 0, "UInt")
		DisableId := DllCall("GetMenuItemID", "Ptr", Native.Handle, "Int", 1, "UInt")
		FileId := DllCall("GetMenuItemID", "Ptr", Native.Handle, "Int", 2, "UInt")
		Assert(FileId != 0 && FileId != 0xFFFFFFFF && FileId != EnableId && FileId != DisableId,
			"the file command must own a separate native leaf identity")
		Assert(_MenuDispatchCallbacks.Has(FileId), "the real renderer must register that actual native command")
		AssertEqual(Row["label"], _SGM_LabelAt(Native, 2), "the actual category provider renders the same declaration")
		FileDelete(Path)
		AssertFalse(_MenuDispatchCallbacks[FileId].Call(), "the drawn native command rechecks its withdrawn category source")
		AssertEqual(false, Row["action"].Call(), "a held callback rechecks the native source before opening")
		AssertEqual(1, Observations.Length, "withdrawn source cannot launch its opening owner")
	} finally {
		Item["i18n"] := Label
		if Native is Menu {
			Released := false
			try {
				_CTC_ReleaseMenu(Native)
				Released := true
			}
		}
		if FileExist(Path)
			FileDelete(Path)
	}
	AssertTrue(Released, "the owned native category menu must be released without masking a primary failure")
}

for _HSCS_FileReceipt in [true, false]
	Test("shared category file: native opening receipt " . _HSCS_FileReceipt,
		_HSCS_FileCommand.Bind(_HSCS_FileReceipt))

; The actual boot owner must retain extension-bound categories after relocation.
_HSCS_DeclaredInventory() {
	_HSCS_WithDynamicBootState(Check)
	Check() {
		global _FLAT_HOTSTRING_V1_CATS, _V1CatToV2CatMap, _LegacyTopCategoryMap, HS_LANGUAGE_GATE_KEYS
		SavedLanguageKeys := HS_LANGUAGE_GATE_KEYS
		HS_LANGUAGE_GATE_KEYS := Map()
		HadFlat := IsSet(_FLAT_HOTSTRING_V1_CATS)
		SavedFlat := HadFlat ? _FLAT_HOTSTRING_V1_CATS : 0
		try {
			_FLAT_HOTSTRING_V1_CATS := [], _V1CatToV2CatMap := Map(), _LegacyTopCategoryMap := Map()
			_HS_RegisterLanguageMenuCategories()
			AssertEqual("hotstrings.french_distancesreduction", _LegacyTopCategoryMap.Get("FrenchDistancesReduction", ""),
				"the declared bound category must survive moving out of the language index")
			Inventory := _HotstringsCategoryScopeInventory(_LegacyTopCategoryMap)
			Assert(Inventory.Has("FrenchDistancesReduction"))
			AssertEqual(1, Inventory["FrenchDistancesReduction"].Length)
			AssertEqual("suffixes_a", Inventory["FrenchDistancesReduction"][1])
			Gates := Map("FrenchDistancesReduction", true)
			HotstringsSeedLanguageCategoryGates(Gates)
			AssertTrue(Gates["FrenchDistancesReduction"], "seeding preserves an explicit existing gate")
			AssertEqual("french_distancesreduction", _CategoryEnabledKey("FrenchDistancesReduction"))
			NeutralGates := Map()
			HotstringsSeedLanguageCategoryGates(NeutralGates)
			AssertEqual(ManifestDefaultFor("category_enabled.french_distancesreduction"), NeutralGates["FrenchDistancesReduction"])
			Groups := MenuManifest_LoadHotstringGroups(), Declared := _MG_LoadSubCategories()
			for Categories in [Groups.standard, Groups.ergopti]
				for Category in Categories {
					AssertEqual(Declared[Category], _V1CatToV2CatMap[Category])
					AssertEqual("hotstrings." . Declared[Category], _LegacyTopCategoryMap[Category])
				}
			Count := _FLAT_HOTSTRING_V1_CATS.Length, TopCount := _LegacyTopCategoryMap.Count
			_HS_RegisterLanguageMenuCategories()
			AssertEqual(Count, _FLAT_HOTSTRING_V1_CATS.Length, "a rebuild cannot duplicate flat categories")
			AssertEqual(TopCount, _LegacyTopCategoryMap.Count)
		} finally {
			HS_LANGUAGE_GATE_KEYS := SavedLanguageKeys
			_FLAT_HOTSTRING_V1_CATS := HadFlat ? SavedFlat : unset
		}
	}
}
Test("hotstring-extension-menu-owner: declared bound category inventory survives relocation", _HSCS_DeclaredInventory)

; Sparse persistence still proves the exact choice and deletion of neutral overrides.
_HSCS_AssertSparseSelection(Parsed, Section, Key, Path, Enabled) {
	Rows := Parsed.Get(Section, Map()), Neutral := ManifestDefaultFor(Path)
	AssertEqual(Enabled != Neutral, Rows.Has(Key), "only an explicit difference belongs in the cohort")
	AssertEqual(Enabled, Rows.Get(Key, Neutral), "every selected bound choice belongs to the cohort")
}


; Bind literal-bearing source matches to genuine executable owner tokens.
_HSCS_PersonalFrameStatement(Code, Pattern) {
	Masked := _DriverMaskNonCode(&Code)
	if !RegExMatch(Code, Pattern, &Found)
		return 0
	Position := Found.Pos(1), Token := Found[1]
	return SubStr(Masked, Position, StrLen(Token)) == Token ? Position : 0
}

; The same captured native editor row is supplied through both whole frames.
_HSCS_PersonalFrameDelegation(Body) {
	Capture := _HSCS_PersonalFrameStatement(Body,
		'm)^[ \t]*(EditorRow)[ \t]*:=[ \t]*_HS_PersonalEditorRow\(\(\*\)[ \t]*=>[ \t]*OpenPersonalEditor\(\)\)')
	Controls := _HSCS_PersonalFrameStatement(Body,
		'm)^[ \t]*(Controls)[ \t]*:=[ \t]*MenuRenderer_TemplateRows\("hotstring_personal_controls_frame",')
	Editor := _HSCS_PersonalFrameStatement(Body,
		'"personal_editor",[ \t]*\(\*\)[ \t]*=>[ \t]*(EditorRow)[ \t]+is[ \t]+Map[ \t]*\?[ \t]*\[EditorRow\][ \t]*:[ \t]*\[\]')
	Content := _HSCS_PersonalFrameStatement(Body,
		'm)^[ \t]*(PersonalRows)[ \t]*:=[ \t]*MenuRenderer_TemplateRows\("hotstring_personal_content_frame",')
	Binding := _HSCS_PersonalFrameStatement(Body,
		'"personal_controls",[ \t]*\(\*\)[ \t]*=>[ \t]*(Controls)(?:[ \t]*,)')
	Render := _HSCS_PersonalFrameStatement(Body,
		'm)^[ \t]*(_HS_CategoryMenu)\("Personal",[ \t]*"",[ \t]*PersonalRows,')
	return Capture && Controls && Editor && Content && Binding && Render
		&& Capture < Controls && Controls < Editor && Editor < Content && Content < Binding && Binding < Render
}

; Quote each actual source line separately: native PCRE masks short physical
; strings without the recursion depth of one whole-function continuation.
_HSCS_PersonalFrameQuotedData(Body) {
	Quoted := ""
	for Line in StrSplit(Body, "`n", "`r") {
		Escaped := StrReplace(Line, Chr(96), Chr(96) . Chr(96))
		Escaped := StrReplace(Escaped, "'", Chr(96) . "'")
		Quoted .= "QuotedData := '" . Escaped . "'`n"
	}
	return Quoted
}

_HSCS_PersonalFrameGuardRefuses(Kind) {
	Body := _DriverFuncBody("_HS_PersonalRows")
	Assert(Body != "")
	AssertTrue(_HSCS_PersonalFrameDelegation(Body), "the genuine native producer is admitted before mutation")
	if Kind == "capture"
		Mutant := StrReplace(Body, "EditorRow := _HS_PersonalEditorRow", "EditorRow := _HS_MissingEditorRow")
	else if Kind == "provider"
		Mutant := StrReplace(Body, '"personal_editor", (*) => EditorRow is Map ? [EditorRow] : []', '"personal_editor", (*) => []')
	else if Kind == "controls"
		Mutant := StrReplace(Body, 'MenuRenderer_TemplateRows("hotstring_personal_controls_frame",', 'MenuRenderer_TemplateRows("foreign_personal_controls",')
	else if Kind == "content"
		Mutant := StrReplace(Body, 'MenuRenderer_TemplateRows("hotstring_personal_content_frame",', 'MenuRenderer_TemplateRows("foreign_personal_content",')
	else if Kind == "binding"
		Mutant := StrReplace(Body, '"personal_controls", (*) => Controls,', '"personal_controls", (*) => [],')
	else if Kind == "render"
		Mutant := StrReplace(Body, '_HS_CategoryMenu("Personal", "", PersonalRows,', '_HS_CategoryMenu("Personal", "", [],')
	else if Kind == "quoted"
		Mutant := _HSCS_PersonalFrameQuotedData(Body)
	else
		Mutant := "/*`n" . Body . "`n*/"
	if Kind == "quoted" {
		; This non-anchored actual ownership pattern still matches the raw
		; quoted data. Only the canonical native mask removes its authority.
		Pattern := '"personal_controls",[ \t]*\(\*\)[ \t]*=>[ \t]*(Controls)(?:[ \t]*,)'
		Assert(RegExMatch(Mutant, Pattern), "the quoted actual owner still contains the original non-anchored binding")
		AssertEqual(0, _HSCS_PersonalFrameStatement(Mutant, Pattern), "physical quoted data must be masked even when its raw ownership pattern matches")
	}
	Assert(Mutant != Body, "the actual owner is changed by the independent source control")
	AssertFalse(_HSCS_PersonalFrameDelegation(Mutant), "missing or data-only frame delegation has no executable authority")
}
for _HSCS_PersonalFrameKind in ["capture", "provider", "controls", "content", "binding", "render", "quoted", "commented"]
	Test("shared-personal-frame: refuses " . _HSCS_PersonalFrameKind, _HSCS_PersonalFrameGuardRefuses.Bind(_HSCS_PersonalFrameKind))
