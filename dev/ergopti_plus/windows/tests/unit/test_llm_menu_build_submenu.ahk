; tests/unit/test_llm_menu_build_submenu.ahk

; ==============================================================================
; MODULE: LLM Menu Inline Submenu Build Tests
; DESCRIPTION:
; The deferred boot IA population re-ran the entire initMenu (~109-156 ms
; wall on real boots) just to attach a 13-item submenu whose rows cost ~0 ms
; to construct. LLM_Menu_BuildSubmenu owns row construction alone (no
; publish, no root rebuild): initMenu builds IA inline at boot, and the boot
; projections arm only when the handle is still empty. The runtime
; RequestBuild path keeps its staged replacement and fail-closed contract.
; ==============================================================================

#Requires AutoHotkey v2.0

_LBMS_Fixture() {
	global _LLM_Menu
	Saved := _LLM_Menu
	_LLM_Menu := Map("enabled", true, "backend", "api", "model", "stale-tag",
		"profile_id", "basic", "n_predictions", 3, "auto_profile_for_model", true,
		"min_words", 3, "max_words", 15, "language", "fr", "debounce_ms", 500,
		"ctx_chars", 500, "temperature", "0.10", "instant_on_word_end", true,
		"after_hotstring", true, "reset_on_nav", true, "disable_url_bars", true,
		"disable_password_fields", true, "disabled_apps", [], "show_info_bar", true,
		"streaming", true, "show_all_at_once", true, "pred_indent", 0,
		"auto_raise_temp", true, "nav_modifiers", "", "val_modifiers", "alt",
		"inline_autotype", false,
		"ollama_port", 11434, "user_profiles", [], "api_entry_id", "e1",
		"api_entries", [Map("Id", "e1", "Name", "Cerebras",
			"Provider", "cerebras", "BaseUrl", "https://b.invalid/v1",
			"Token", "sekret", "Model", "qwen-3.8-27b")])
	return Saved
}

; The extractor exists and builds rows without publish side effects: the
; global handle keeps its identity and InTray is untouched.
_LBMS_BuildSubmenuBehavior() {
	global _LLM_Menu, _LLM_Menu_Handle, _LLM_Menu_InTray
	Assert(_DriverFuncBody("LLM_Menu_BuildSubmenu") != "",
		"LLM_Menu_BuildSubmenu must exist in menu_main.ahk")
	SavedMenu := _LBMS_Fixture()
	SavedHandle := (IsSet(_LLM_Menu_Handle) && IsObject(_LLM_Menu_Handle)) ? _LLM_Menu_Handle : ""
	SavedInTray := IsSet(_LLM_Menu_InTray) ? _LLM_Menu_InTray : false
	_LLM_Menu_Handle := Menu()
	Before := _LLM_Menu_Handle
	try {
		Sub := LLM_Menu_BuildSubmenu()
		Assert(Sub is Menu, "the builder must return the staged submenu")
		Assert(ObjPtr(_LLM_Menu_Handle) == ObjPtr(Before),
			"the builder must not repoint the global handle")
		NowInTray := IsSet(_LLM_Menu_InTray) ? _LLM_Menu_InTray : false
		Assert(NowInTray == SavedInTray,
			"the builder must not touch InTray")
		N := DllCall("GetMenuItemCount", "ptr", Sub.Handle, "int")
		Assert(N >= 10, "toggle+settings+about must stage, got " . N)
		Again := LLM_Menu_BuildSubmenu()
		Assert(DllCall("GetMenuItemCount", "ptr", Again.Handle, "int") == N,
			"row construction must be deterministic")
	} finally {
		_LLM_Menu := SavedMenu
		if (SavedHandle != "")
			_LLM_Menu_Handle := SavedHandle
		_LLM_Menu_InTray := SavedInTray
	}
}
Test("llm menu: submenu builder has no publish side effects (llm-menu-build-submenu)",
	_LBMS_BuildSubmenuBehavior)

; The text of every row of a native menu, top to bottom.
_LBMS_Labels(TargetMenu) {
	static MF_BYPOSITION := 0x400
	Labels := []
	Count := DllCall("GetMenuItemCount", "ptr", TargetMenu.Handle, "int")
	Assert(Count > 0, "the staged submenu must have rows to read")
	Loop Count {
		Position := A_Index - 1
		Length := DllCall("GetMenuStringW", "ptr", TargetMenu.Handle, "uint", Position,
			"ptr", 0, "int", 0, "uint", MF_BYPOSITION, "int")
		Text := Buffer((Max(Length, 0) + 1) * 2, 0)
		DllCall("GetMenuStringW", "ptr", TargetMenu.Handle, "uint", Position,
			"ptr", Text, "int", Max(Length, 0) + 1, "uint", MF_BYPOSITION, "int")
		Labels.Push(StrGet(Text, "UTF-16"))
	}
	return Labels
}

; ai-menu-no-clear. The drawn AI submenu keeps « Restaurer les valeurs
; conseillées » under its switch and no longer shows « Tout effacer
; (comportement du système) », whose row the maintainer retired.
_LBMS_NoClearRow() {
	global _LLM_Menu, _LLM_Menu_Handle
	SavedMenu := _LBMS_Fixture()
	SavedHandle := (IsSet(_LLM_Menu_Handle) && IsObject(_LLM_Menu_Handle)) ? _LLM_Menu_Handle : ""
	_LLM_Menu_Handle := Menu()
	try {
		Sub := LLM_Menu_BuildSubmenu()
		Labels := _LBMS_Labels(Sub)
		Restores := 0
		for Label in Labels {
			AssertFalse(Label == t("common.clear_to_system"), "the AI submenu draws no clear row")
			if (Label == t("common.restore_recommended"))
				Restores += 1
		}
		AssertEqual(1, Restores, "the AI submenu keeps its restore row")
		AssertEqual(t("common.restore_recommended"), Labels[2], "the restore row follows the switch")
		AssertEqual("", Labels[3], "a separator closes the switch's group")
	} finally {
		_LLM_Menu := SavedMenu
		if (SavedHandle != "")
			_LLM_Menu_Handle := SavedHandle
	}
}
Test("ai-menu-no-clear: the drawn AI submenu has a restore row and no clear row",
	_LBMS_NoClearRow)

; backend-row-selected-option. The drawn Backend row, the first after the
; switch's group, reads the selected option before its em dash.
_LBMS_BackendRowLabel() {
	global _LLM_Menu, _LLM_Menu_Handle
	SavedMenu := _LBMS_Fixture()
	SavedHandle := (IsSet(_LLM_Menu_Handle) && IsObject(_LLM_Menu_Handle)) ? _LLM_Menu_Handle : ""
	_LLM_Menu_Handle := Menu()
	try {
		; Off, so no install warning row sits between the group and the row.
		_LLM_Menu["enabled"] := false
		for Backend, Expected in Map("api", "API 🌐", "ollama", "Ollama 🦙") {
			_LLM_Menu["backend"] := Backend
			Labels := _LBMS_Labels(LLM_Menu_BuildSubmenu())
			AssertEqual(Expected, Labels[4], Backend . ": the Backend row names the selected option")
		}
	} finally {
		_LLM_Menu := SavedMenu
		if (SavedHandle != "")
			_LLM_Menu_Handle := SavedHandle
	}
}
Test("backend-row-selected-option: the drawn Backend row names the selected option",
	_LBMS_BackendRowLabel)

; LLM_Menu_Build must construct rows through the extractor — one row
; construction site, not two drifting copies.
_LBMS_BuildCallsExtractor() {
	Body := _StripFullLineComments(_DriverFuncBody("LLM_Menu_Build"))
	Assert(Body != "", "LLM_Menu_Build must remain source-visible")
	Assert(InStr(Body, "LLM_Menu_BuildSubmenu(") > 0,
		"LLM_Menu_Build must construct rows through the extractor")
}
Test("llm menu: build reuses the submenu extractor (llm-menu-build-submenu)",
	_LBMS_BuildCallsExtractor)

; LLM_Menu_Init (initMenu's LLM phase) builds IA inline instead of leaving
; an empty parent for a second full pass; on failure the empty parent stays
; staged and the boot projections recover it.
_LBMS_InitMenuBuildsInline() {
	Body := _StripFullLineComments(_DriverFuncBody("LLM_Menu_Init"))
	Assert(Body != "", "LLM_Menu_Init must remain source-visible")
	Assert(InStr(Body, "LLM_Menu_BuildSubmenu(") > 0,
		"LLM_Menu_Init must build the IA submenu inline in initMenu's LLM phase")
}
Test("llm menu: initMenu builds IA inline (llm-menu-build-submenu)",
	_LBMS_InitMenuBuildsInline)

; The boot projections arm only when the handle is still empty: an inline
; success skips the whole second initMenu, an inline failure still gets
; today's deferred recovery.
_LBMS_BootPredicate() {
	Assert(_DriverFuncBody("_TrayRootBootIaPopulationNeeded") != "",
		"_TrayRootBootIaPopulationNeeded must exist in menu_rebuild.ahk")
	global _LLM_Menu_Handle
	SavedHandle := (IsSet(_LLM_Menu_Handle) && IsObject(_LLM_Menu_Handle)) ? _LLM_Menu_Handle : ""
	try {
		_LLM_Menu_Handle := Menu()
		AssertTrue(_TrayRootBootIaPopulationNeeded(),
			"an empty handle still needs the deferred population")
		_LLM_Menu_Handle.Add("probe", (*) => 0)
		AssertFalse(_TrayRootBootIaPopulationNeeded(),
			"a populated handle skips the second pass")
	} finally {
		if (SavedHandle != "")
			_LLM_Menu_Handle := SavedHandle
	}
	Worker := _StripFullLineComments(_DriverFuncBody("_TrayRootBuildBoot"))
	Assert(Worker != "", "_TrayRootBuildBoot must remain source-visible")
	Assert(InStr(Worker, "_TrayRootBootIaPopulationNeeded()") > 0,
		"the boot worker must consult the population predicate before arming")
}
Test("llm menu: boot projections skip a populated handle (llm-menu-build-submenu)",
	_LBMS_BootPredicate)
