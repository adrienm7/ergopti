; tests/unit/modules/llm/menu/test_llm_menu_backend_child.ahk

; ==============================================================================
; MODULE: LLM Menu Windows Backend Child
; DESCRIPTION:
; The Windows backend child keeps its 21-language caption images, native
; port callbacks, catalogue order and whole-frame admission, and refuses a
; late canonical withdrawal.
; ==============================================================================

#Requires AutoHotkey v2.0





; Independent caption oracle and actual backend native entry subjects.
_WBC_WithState(Body) {
	global _I18nCache, _I18nCacheLoaded, _LLM_Menu, LLM_MENU_BACKEND_OPTIONS, LLM_Defaults
	Root := _MR_GetManifestRoot(), Previous := Map()
	for Key in ["llm_backend_option_caption_frame_ahk", "llm_backend_ollama_option_caption_ahk", "llm_backend_api_option_caption_ahk",
		"llm_backend_ollama_port_control_ahk", "llm_backend_ollama_port_frame_ahk", "llm_native_numeric_reset",
		"llm_backend_child_frame_ahk", "llm_backend_child_choices_ahk", "llm_backend_choice_boundary",
		"llm_backend_child_port_rows_ahk", "llm_backend_child_local_rows_ahk"] {
		AssertTrue(Root.Has(Key), "the actual backend child presentation owner exists: " . Key)
		Previous[Key] := Root[Key]
	}
	HadCache := IsSet(_I18nCache), HadLoaded := IsSet(_I18nCacheLoaded), HadMenu := IsSet(_LLM_Menu)
	SavedCache := HadCache ? _I18nCache : false, SavedLoaded := HadLoaded ? _I18nCacheLoaded : false
	SavedMenu := HadMenu ? _LLM_Menu : false, SavedOptions := LLM_MENU_BACKEND_OPTIONS
	HadDefaults := IsSet(LLM_Defaults)
	if HadDefaults
		SavedDefaults := LLM_Defaults
	try {
		; Numeric menu subjects need the same shared source the real boot loads.
		LLM_Defaults_Load()
		AssertTrue(LLM_Defaults is Map && LLM_Defaults.Has("llm_ollama_port"),
			"the genuine defaults loader publishes the native port prerequisite")
		Body.Call(Root)
	}
	finally {
		for Key, Value in Previous
			Root[Key] := Value
		_I18nCache := HadCache ? SavedCache : unset
		_I18nCacheLoaded := HadLoaded ? SavedLoaded : unset
		_LLM_Menu := HadMenu ? SavedMenu : unset
		LLM_MENU_BACKEND_OPTIONS := SavedOptions
		LLM_Defaults := HadDefaults ? SavedDefaults : unset
	}
}

_WBC_ReadCorpus() {
	global _SharedDir
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\windows_backend_child_captions.json", "UTF-8"))
	AssertEqual(21, Corpus.Count, "caption images were frozen from the old source in every supported language")
	return Corpus
}

_WBC_SetLanguage(Language) {
	global _SharedDir, _I18nCache, _I18nCacheLoaded
	_I18nCache := JsonParse(FileRead(_SharedDir . "\data\locales\" . Language . ".json", "UTF-8"))
	_I18nCacheLoaded := true
}

_WBC_Callback(Observed, *) {
	Observed["calls"] += 1
	return Observed["result"]
}

_WBC_FrozenCaptionImages(Root) {
	for Language, Subject in _WBC_ReadCorpus() {
		_WBC_SetLanguage(Language)
		AssertEqual(Subject["api"], _LLM_Menu_BackendOptionLabel("api"), "actual API brand and old translated suffix remain exact")
		AssertEqual(Subject["ollama"], _LLM_Menu_BackendOptionLabel("ollama"), "actual Ollama brand and old translated suffix remain exact")
		PromptSeen := Map("calls", 0, "result", Map("prompt", Language))
		ResetSeen := Map("calls", 0, "result", Map("reset", Language))
		Prompt := _WBC_Callback.Bind(PromptSeen), Reset := _WBC_Callback.Bind(ResetSeen)
		DefaultRows := _LLM_Menu_BackendPortRows(11434, 11434, Prompt, Reset)
		AssertEqual(1, DefaultRows.Length, "the original at-default reset is absent")
		AssertEqual(Subject["port_default"], DefaultRows[1]["label"])
		CustomRows := _LLM_Menu_BackendPortRows(11555, 11434, Prompt, Reset)
		AssertEqual(2, CustomRows.Length, "the original customized port retains its reset")
		AssertEqual(Subject["port_custom"], CustomRows[1]["label"])
		AssertEqual(Subject["reset_default"], CustomRows[2]["label"])
		LiteralRows := _LLM_Menu_BackendPortRows(Subject["literal_subject"], 11434, Prompt, Reset)
		AssertEqual(Subject["port_literal"], LiteralRows[1]["label"], "native percent, ampersand and Unicode data is not another format")
		PortCohort := _LLM_Menu_BackendChildFrameRows([], CustomRows, [])
		AssertTrue(PortCohort is Array && PortCohort.Length == 3, "the real child frame transports both guarded port records")
		AssertTrue(PortCohort[2]["action"] == CustomRows[1]["action"] && PortCohort[3]["action"] == CustomRows[2]["action"],
			"the complete child frame retains actual published guarded action identities")
		AssertFalse(CustomRows[1]["action"] == Prompt || CustomRows[2]["action"] == Reset,
			"the actual command publisher guards both supplied native business functions")
		AssertEqual(0, PromptSeen["calls"] + ResetSeen["calls"], "all admitted caption/frame construction is inert")
	}
}

_WBC_NativePortCallbacks(Root) {
	global _MenuDispatchCallbacks
	Subject := _WBC_ReadCorpus()["en"]
	_WBC_SetLanguage("en")
	PromptSeen := Map("calls", 0, "result", Map("prompt", true)), ResetSeen := Map("calls", 0, "result", false)
	Prompt := _WBC_Callback.Bind(PromptSeen), Reset := _WBC_Callback.Bind(ResetSeen)
	Rows := _LLM_Menu_BackendPortRows(Subject["literal_subject"], 11434, Prompt, Reset)
	Target := Menu(), Foreign := Menu(), ForeignAction := _WBC_Callback.Bind(Map("calls", 0, "result", true))
	try {
		RegisterMenuItem(Foreign, "foreign backend fixture", ForeignAction)
		ForeignId := _MenuItemIdAtPosition(Foreign, 0)
		AssertEqual(2, MenuRenderer_AppendRows(Target, "llm_menu", "llm_backend", Rows))
		Labels := _LBMS_Labels(Target)
		AssertEqual(StrReplace(Subject["port_literal"], "&", "&&"), Labels[1], "the actual Win32 label preserves literal native data")
		AssertEqual(StrReplace(Subject["reset_default"], "&", "&&"), Labels[2])
		PromptId := _MenuItemIdAtPosition(Target, 0), ResetId := _MenuItemIdAtPosition(Target, 1)
		AssertTrue(_MenuDispatchCallbacks[PromptId] == Rows[1]["action"] && _MenuDispatchCallbacks[ResetId] == Rows[2]["action"],
			"the actual native command IDs retain the published canonical guarded actions")
		AssertFalse(Rows[1]["action"] == Prompt || Rows[2]["action"] == Reset,
			"native publication preserves the genuine canonical readiness guard")
		AssertEqual(0, PromptSeen["calls"] + ResetSeen["calls"], "native menu construction never dispatches an action")
		AssertTrue(_MenuDispatchCallbacks[PromptId].Call() == PromptSeen["result"], "original prompt result identity survives registration")
		AssertFalse(_MenuDispatchCallbacks[ResetId].Call(), "original false reset result is not converted into success")
		AssertEqual(1, PromptSeen["calls"])
		AssertEqual(1, ResetSeen["calls"])
		_CTC_ReleaseMenu(Target)
		AssertTrue(_MenuDispatchCallbacks.Has(ForeignId) && _MenuDispatchCallbacks[ForeignId] == ForeignAction,
			"owned backend menu release preserves the foreign detached registration")
	} finally {
		try _CTC_ReleaseMenu(Target)
		finally _CTC_ReleaseMenu(Foreign)
	}
}

_WBC_ActualCatalogueAndNativeTree(Root) {
	global _LLM_Menu, LLM_MENU_BACKEND_OPTIONS
	Subject := _WBC_ReadCorpus()["en"]
	_WBC_SetLanguage("en")
	AssertEqual(11434, _LLM_DefaultFor("llm_ollama_port"), "the original frozen numeric default remains independent")
	for Order in [["api", "ollama"], ["ollama", "api"]] {
		LLM_MENU_BACKEND_OPTIONS := Order
		for Selected in Order {
			_LLM_Menu := Map("backend", Selected, "ollama_port", 11555)
			Rows := _LLM_Menu_BackendRows()
			for Index, Id in Order {
				AssertEqual(Subject[Id], Rows[Index]["label"], "the genuine existing catalogue, not the presentation declaration, owns choice order")
				AssertEqual(Id == Selected, Rows[Index]["checked"])
				AssertTrue(HasMethod(Rows[Index]["action"], "Call"))
			}
			AssertTrue(Rows[3]["separator"])
			AssertEqual(Subject["port_custom"], Rows[4]["label"])
			AssertEqual(Subject["reset_default"], Rows[5]["label"])
			Target := LLM_Menu_BuildBackendMenu()
			try {
				Labels := _LBMS_Labels(Target)
				AssertEqual(Subject[Order[1]], Labels[1])
				AssertEqual(Subject[Order[2]], Labels[2])
				AssertTrue(TrayMenuIsSeparatorAt(Target, 2))
				AssertEqual(Subject["port_custom"], Labels[4])
				AssertEqual(Subject["reset_default"], Labels[5])
				for Index, Id in Order {
					State := DllCall("GetMenuState", "ptr", Target.Handle, "uint", Index - 1, "uint", 0x400, "uint")
					AssertEqual(Id == Selected, !!(State & 8), "the genuine native checkbox retains the selected backend")
				}
				AssertEqual(Selected, _LLM_Menu["backend"], "building never changes backend selection")
				AssertEqual(11555, _LLM_Menu["ollama_port"], "building never changes native port state")
			} finally _CTC_ReleaseMenu(Target)
		}
	}
}

; Uses the unchanged original API; the predecessor ignores the new physical owner.
_WBC_OriginalOptionDeclaration(Root) {
	Subject := _WBC_ReadCorpus()["en"]
	_WBC_SetLanguage("en")
	Frame := Root["llm_backend_api_option_caption_ahk"], Original := Frame[1]
	try {
		Changed := Original.Clone(), Changed["caption_joiner"] := " :: "
		Frame[1] := Changed
		AssertEqual(StrReplace(Subject["api"], " — ", " :: "), _LLM_Menu_BackendOptionLabel("api"),
			"actual original API follows the genuine changed caption joiner")
		Frame[1] := Original
		AssertEqual(Subject["api"], _LLM_Menu_BackendOptionLabel("api"), "repair restores the independently frozen image")
		Root.Delete("llm_backend_option_caption_frame_ahk")
		Failure := ""
		try _LLM_Menu_BackendOptionLabel("api")
		catch as Err
			Failure := Err.Message
		AssertEqual("Declared backend option caption was refused.", Failure, "actual original API refuses its withdrawn caption owner")
	} finally Frame[1] := Original
}

; Whole-frame and both numeric declarations must admit before an absent native state read.
_WBC_OriginalBackendEarlyRefusal(Root) {
	global _LLM_Menu
	for Key in ["llm_backend_child_frame_ahk", "llm_backend_ollama_port_control_ahk", "llm_native_numeric_reset"] {
		Previous := Root[Key], Failure := "", Rows := false
		try {
			_LLM_Menu := unset
			AssertFalse(IsSet(_LLM_Menu), "the original native backend state datum is independently absent")
			Root.Delete(Key)
			try Rows := _LLM_Menu_BackendRows()
			catch as Err
				Failure := Err.Message
			AssertEqual("", Failure, "actual original provider admits presentation before absent state reads: " . Key)
			AssertTrue(Rows is Array)
			AssertEqual(0, Rows.Length, "the genuine withdrawn source exposes no partial backend data")
		} finally Root[Key] := Previous
	}
}

_WBC_CompleteFrameOrderAndIdentity(Root) {
	Observed := Map("calls", 0, "result", true), Action := _WBC_Callback.Bind(Observed)
	Choice := Map("label", "fixture choice transport receipt", "action", Action, "checked", true)
	Port := Map("label", "fixture port transport receipt", "action", Action)
	LocalReceipt := Map("label", "fixture local transport receipt", "action", Action)
	Frame := Root["llm_backend_child_frame_ahk"], Original := Frame.Clone()
	try {
		Rows := _LLM_Menu_BackendChildFrameRows([Choice], [Port], [LocalReceipt])
		AssertTrue(Rows[1] == Choice && Rows[3] == Port && Rows[4] == LocalReceipt, "the real typed ports retain complete native row identities")
		AssertTrue(Rows[2]["separator"])
		Root["llm_backend_child_frame_ahk"] := [Original[4], Original[3], Original[2], Original[1]]
		Rows := _LLM_Menu_BackendChildFrameRows([Choice], [Port], [LocalReceipt])
		AssertTrue(Rows[1] == LocalReceipt && Rows[2] == Port && Rows[4] == Choice, "the genuine canonical frame owns complete family order")
		AssertTrue(Rows[3]["separator"])
		AssertEqual(0, Observed["calls"], "shared composition never invokes a native callback")
		; A comma-only literal cannot supply the missing physical choice premise.
		EmptyLiteral := [,], SparseChoices := []
		AssertEqual(0, EmptyLiteral.Length, "the old comma-only choice input is empty")
		AssertFalse(EmptyLiteral.Has(1), "the old choice literal assigns no first row")
		SparseChoices.Length := 1
		AssertEqual(1, SparseChoices.Length, "the negative choice fixture has one physical slot")
		AssertFalse(SparseChoices.Has(1), "the negative choice fixture leaves that slot unassigned")
		AssertFalse(_LLM_Menu_BackendChildFrameRows(SparseChoices, [Port], [LocalReceipt]), "a sparse array is not a genuine native row cohort")
		AssertEqual(1, SparseChoices.Length, "whole-frame refusal preserves the borrowed choice length")
		AssertFalse(SparseChoices.Has(1), "whole-frame refusal never fills the borrowed choice hole")
		AssertFalse(_LLM_Menu_BackendChildFrameRows([false], [Port], [LocalReceipt]), "a nonrow cannot impersonate a native cohort")
	} finally Root["llm_backend_child_frame_ahk"] := Frame
}

Test("Windows backend child: all21 old brand/suffix/port/reset caption images remain exact", _WBC_WithState.Bind(_WBC_FrozenCaptionImages))
Test("Windows backend child: actual native port callbacks preserve identities/results and foreign owners", _WBC_WithState.Bind(_WBC_NativePortCallbacks))
Test("Windows backend child: original catalogue order and actual native state stay exact", _WBC_WithState.Bind(_WBC_ActualCatalogueAndNativeTree))
Test("Windows backend child: original label API obeys physical declaration changes and withdrawal", _WBC_WithState.Bind(_WBC_OriginalOptionDeclaration))
Test("Windows backend child: original provider admits whole frame and numeric controls before native data", _WBC_WithState.Bind(_WBC_OriginalBackendEarlyRefusal))
Test("Windows backend child: canonical whole-frame order and native receipt identities survive", _WBC_WithState.Bind(_WBC_CompleteFrameOrderAndIdentity))

; Published command records retain canonical late readiness; business bodies remain raw inputs.
_WBC_GuardedPortWithdrawal(Root) {
	global _MenuDispatchCallbacks
	_WBC_SetLanguage("en")
	PromptSeen := Map("calls", 0, "result", Map("prompt", "original-terminal"))
	ResetSeen := Map("calls", 0, "result", false)
	Prompt := _WBC_Callback.Bind(PromptSeen), Reset := _WBC_Callback.Bind(ResetSeen)
	Rows := _LLM_Menu_BackendPortRows(11555, 11434, Prompt, Reset)
	AssertTrue(Rows is Array && Rows.Length == 2)
	AssertFalse(Rows[1]["action"] == Prompt || Rows[2]["action"] == Reset,
		"both raw business callbacks enter the genuine declared command guard")
	Target := Menu()
	try {
		AssertEqual(2, MenuRenderer_AppendRows(Target, "llm_menu", "llm_backend", Rows))
		PromptId := _MenuItemIdAtPosition(Target, 0), ResetId := _MenuItemIdAtPosition(Target, 1)
		AssertTrue(_MenuDispatchCallbacks[PromptId] == Rows[1]["action"]
			&& _MenuDispatchCallbacks[ResetId] == Rows[2]["action"], "native transport never rebinds the published guarded records")
		PortDefinition := Root["llm_backend_ollama_port_control_ahk"]
		ResetDefinition := Root["llm_native_numeric_reset"]
		try {
			Root.Delete("llm_backend_ollama_port_control_ahk")
			Root.Delete("llm_native_numeric_reset")
			AssertFalse(_MenuDispatchCallbacks[PromptId].Call(), "late missing prompt declaration refuses the supplied business function")
			AssertFalse(_MenuDispatchCallbacks[ResetId].Call(), "late missing reset declaration refuses the supplied business function")
			AssertEqual(0, PromptSeen["calls"], "refused readiness never calls the original prompt body")
			AssertEqual(0, ResetSeen["calls"], "a false reset refusal is distinct from a false business terminal")
		} finally {
			Root["llm_backend_ollama_port_control_ahk"] := PortDefinition
			Root["llm_native_numeric_reset"] := ResetDefinition
		}
		AssertTrue(_MenuDispatchCallbacks[PromptId].Call() == PromptSeen["result"], "repair preserves the original prompt terminal object")
		AssertFalse(_MenuDispatchCallbacks[ResetId].Call(), "repair preserves the original false reset terminal")
		AssertEqual(1, PromptSeen["calls"])
		AssertEqual(1, ResetSeen["calls"])
	} finally _CTC_ReleaseMenu(Target)
}

; This unchanged provider entry must reject caption ownership before an absent native datum.
_WBC_CurrentProviderCaptionRefusal(Root) {
	global _LLM_Menu
	_LLM_Menu := Map()
	AssertFalse(_LLM_Menu.Has("backend"), "the actual missing backend datum arms the original provider ordering")
	AssertTrue(Root.Has("llm_backend_child_frame_ahk"), "the complete static frame remains declared")
	AssertTrue(Root.Has("llm_backend_ollama_port_control_ahk"), "the actual numeric command declaration remains present")
	Root.Delete("llm_backend_option_caption_frame_ahk")
	Failure := "", Rows := false
	try Rows := _LLM_Menu_BackendRows()
	catch as Err
		Failure := Err.Message
	AssertEqual("Declared backend option caption was refused.", Failure,
		"the original provider refuses missing option caption ownership before current backend state")
	AssertFalse(Rows is Array, "no native choice row cohort is published after the exact caption refusal")
}

Test("Windows backend child: published guarded records refuse late canonical withdrawal and preserve business terminals", _WBC_WithState.Bind(_WBC_GuardedPortWithdrawal))
Test("Windows backend child: original current provider admits option captions before absent backend data", _WBC_WithState.Bind(_WBC_CurrentProviderCaptionRefusal))


; Withdraw only after the wrapper has captured valid declarations and loaded defaults.
_WBC_CatalogueWithWithdrawnFrame(Root) {
	Root.Delete("llm_backend_child_frame_ahk")
	return _WBC_ActualCatalogueAndNativeTree(Root)
}

; The defaults prerequisite belongs to this fixture and must not escape its scope.
_WBC_DefaultFixtureRestoration() {
	global LLM_Defaults, _LLM_Menu, LLM_MENU_BACKEND_OPTIONS
	HadDefaults := IsSet(LLM_Defaults)
	if HadDefaults
		SavedDefaults := LLM_Defaults
	SavedMenu := _LLM_Menu, SavedOptions := LLM_MENU_BACKEND_OPTIONS
	Root := _MR_GetManifestRoot(), Section := "llm_backend_child_frame_ahk", Original := Root[Section]
	try {
		LLM_Defaults_Load()
		BorrowedDefaults := LLM_Defaults
		AssertEqual(11434, _LLM_DefaultFor("llm_ollama_port"), "the real source retains the independent numeric oracle")
		for Mode in ["absent", "false", "reference"] {
			LLM_Defaults := Mode == "absent" ? unset : Mode == "false" ? false : BorrowedDefaults
			if Mode != "reference"
				AssertEqual("", _LLM_DefaultFor("llm_ollama_port"), "missing native defaults remain honestly unavailable before fixture initialization")
			_WBC_WithState(_WBC_ActualCatalogueAndNativeTree)
			AssertEqual(Mode != "absent", IsSet(LLM_Defaults), "successful native backend fixture restores exact defaults presence")
			if Mode != "absent"
				AssertTrue(LLM_Defaults == (Mode == "false" ? false : BorrowedDefaults), "successful fixture restores the original defaults identity")
			AssertTrue(_LLM_Menu == SavedMenu, "successful fixture restores the original native menu state")
			AssertTrue(LLM_MENU_BACKEND_OPTIONS == SavedOptions, "successful fixture restores the real catalogue owner")
			AssertThrows(_WBC_WithState.Bind(_WBC_CatalogueWithWithdrawnFrame),
				"a genuinely withdrawn backend frame raises after real defaults initialization")
			AssertEqual(Mode != "absent", IsSet(LLM_Defaults), "withdrawal preserves the original defaults presence")
			if Mode != "absent"
				AssertTrue(LLM_Defaults == (Mode == "false" ? false : BorrowedDefaults), "withdrawal preserves the original defaults identity")
			AssertTrue(_LLM_Menu == SavedMenu, "withdrawal preserves the original native menu state")
			AssertTrue(LLM_MENU_BACKEND_OPTIONS == SavedOptions, "withdrawal preserves the real catalogue owner")
		}
	} finally {
		Root[Section] := Original
		_LLM_Menu := SavedMenu
		LLM_MENU_BACKEND_OPTIONS := SavedOptions
		LLM_Defaults := HadDefaults ? SavedDefaults : unset
	}
}
Test("Windows backend fixture: real defaults preserve absent/false/reference ownership on success and withdrawal",
	_WBC_DefaultFixtureRestoration)
