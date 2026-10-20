; tests/unit/modules/llm/menu/test_llm_menu_model_parent.ahk

; ==============================================================================
; MODULE: LLM Menu Model Parent
; DESCRIPTION:
; The model health parent keeps its original caption in every language,
; its native greying and emitter declaration, and retires owned
; descendants on a late withdrawal.
; ==============================================================================

#Requires AutoHotkey v2.0





; Independent original projections were frozen from the old native producer and physical locales before this declaration.
_LBMD_WithDeclaredModelPicker(Body) {
	global _LLM_Menu, LLM_Defaults, _LLM_Deps_State
	SavedMenu := _LLM_Menu
	HadDeps := IsSet(_LLM_Deps_State)
	if HadDeps
		SavedDeps := _LLM_Deps_State
	HadDefaults := IsSet(LLM_Defaults)
	if HadDefaults
		SavedDefaults := LLM_Defaults
	Native := false
	try {
		_LLM_Menu := Map("backend", "ollama", "model", "", "enabled", false)
		LLM_Defaults := Map("llm_model", "")
		_LLM_Deps_State := "pending"
		Assert(LLM_GetModelPresets().Length > 0, "the completed picker owns the actual nonempty catalogue")
		Native := LLM_Menu_BuildModelMenu()
		Assert(DllCall("GetMenuItemCount", "ptr", Native.Handle, "int") > 0, "the actual native model child must exist")
		return Body.Call(Native)
	} finally {
		if Native is Menu
			_CTC_ReleaseMenu(Native)
		_LLM_Menu := SavedMenu
		if HadDeps
			_LLM_Deps_State := SavedDeps
		else
			_LLM_Deps_State := unset
		if HadDefaults
			LLM_Defaults := SavedDefaults
		else
			LLM_Defaults := unset
	}
}

_LBMD_ModelParentOriginalLocale(Code) {
	return _LBMD_WithHardwareLocale(Code, _LBMD_WithDeclaredModelPicker.Bind(_LBMD_ModelParentOriginalCurrent.Bind(Code)))
}

_LBMD_ModelParentOriginalCurrent(Code, Child) {
	global _SharedDir
	Expected := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\windows_llm_model_health_parent_original.json", "UTF-8"))
	Receive := MenuRenderer_GroupReceiver("llm_model_parent_ahk", "llm_model")
	AssertTrue(_MR_DeclaredParentCallable(Receive), "the genuine canonical model receiver must be admitted")
	ChildCount := DllCall("GetMenuItemCount", "ptr", Child.Handle, "int")
	for Health in Expected["health"] {
		for Index, Model in Expected["models"] {
			Rows := _LLM_Menu_ModelParentRows(Receive, Child, Health["prefix"], Model, false)
			AssertEqual(1, Rows.Length)
			AssertEqual(Expected["locales"][Code]["titles"][Health["id"]][Index], Rows[1]["label"])
			Assert(Rows[1]["submenu"] == Child, "the canonical parent retains the completed native Menu by identity")
			AssertFalse(Rows[1].Get("disabled", false))
			Target := Menu()
			try {
				MenuRenderer_AppendRows(Target, "llm_menu", "llm_model_parent_ahk", Rows)
				AssertEqual(1, DllCall("GetMenuItemCount", "ptr", Target.Handle, "int"))
				AssertEqual(Child.Handle, DllCall("GetSubMenu", "ptr", Target.Handle, "int", 0, "ptr"))
				Label := Buffer(2048, 0)
				DllCall("GetMenuStringW", "ptr", Target.Handle, "uint", 0, "ptr", Label, "int", 1024, "uint", 0x400)
				AssertEqual(StrReplace(Expected["locales"][Code]["titles"][Health["id"]][Index], "&", "&&"), StrGet(Label, "UTF-16"), "native mnemonic escaping preserves the literal declared caption")
			} finally {
				Target.Delete()
				MenuDispatcher_PruneMenu(Target)
			}
		}
	}
	AssertEqual(ChildCount, DllCall("GetMenuItemCount", "ptr", Child.Handle, "int"), "caption/native parent construction preserves every original model callback row")
}

_LBMD_ModelParentGreyed(Disabled) {
	return _LBMD_WithHardwareLocale("en", _LBMD_WithDeclaredModelPicker.Bind(_LBMD_ModelParentGreyedCurrent.Bind(Disabled)))
}

_LBMD_ModelParentGreyedCurrent(Disabled, Child) {
	Receive := MenuRenderer_GroupReceiver("llm_model_parent_ahk", "llm_model")
	Rows := _LLM_Menu_ModelParentRows(Receive, Child, "", "qwen2.5:7b", Disabled)
	AssertEqual(Disabled, Rows[1].Get("disabled", false))
	Target := Menu()
	try {
		MenuRenderer_AppendRows(Target, "llm_menu", "llm_model_parent_ahk", Rows)
		AssertEqual(1, DllCall("GetMenuItemCount", "ptr", Target.Handle, "int"), "greyed settings remain present at the same native position")
		Flags := DllCall("GetMenuState", "ptr", Target.Handle, "uint", 0, "uint", 0x400, "uint")
		Assert(Flags != 0xFFFFFFFF)
		AssertEqual(Disabled, (Flags & 0x3) != 0, "the real native parent applies the resolved shared disabled policy")
		AssertEqual(Child.Handle, DllCall("GetSubMenu", "ptr", Target.Handle, "int", 0, "ptr"))
	} finally {
		Target.Delete()
		MenuDispatcher_PruneMenu(Target)
	}
}

_LBMD_ModelParentRefuses(Kind) {
	return _LBMD_WithHardwareLocale("en", _LBMD_WithDeclaredModelPicker.Bind(_LBMD_ModelParentRefusesCurrent.Bind(Kind)))
}

_LBMD_ModelParentRefusesCurrent(Kind, Child) {
	Root := _MM_GetManifestRoot(), Definition := _MR_GetMenuDef("llm_model_parent_ahk")
	Original := Definition[1]
	Receive := MenuRenderer_GroupReceiver("llm_model_parent_ahk", "llm_model")
	Failed := false
	try {
		if Kind == "withdrawn"
			Root.Delete("llm_model_parent_ahk")
		else if Kind == "mutated"
			Original["i18n"] := "menu.llm.model_label"
		else if Kind == "replaced"
			Root["llm_model_parent_ahk"] := [Original.Clone()]
		else if Kind != "wrong-scalar"
			throw Error("Unknown actual model-parent refusal case")
		try _LLM_Menu_ModelParentRows(Receive, Child, "", Kind == "wrong-scalar" ? false : "qwen2.5:7b", false)
		catch
			Failed := true
		AssertTrue(Failed, "the retained actual receiver refuses withdrawn/replaced/mutated declarations or non-string captions")
	} finally {
		Original["i18n"] := "menu.llm.model_parent_with_health"
		Root["llm_model_parent_ahk"] := Definition
	}
	Rows := _LLM_Menu_ModelParentRows(MenuRenderer_GroupReceiver("llm_model_parent_ahk", "llm_model"), Child, "", "qwen2.5:7b", false)
	AssertEqual(1, Rows.Length, "repair needs a freshly admitted real receiver")
	Assert(Rows[1]["submenu"] == Child)
	AssertFalse(Rows[1].Get("disabled", false))
}
for Code in ["da", "de", "en", "es", "fr", "it", "nl", "no", "pl", "pt", "sv", "tr", "cs", "ru", "uk", "he", "ar", "hi", "zh", "ja", "ko"]
	Test("actual model health/native parent preserves original caption in " . Code, _LBMD_ModelParentOriginalLocale.Bind(Code))
for Disabled in [false, true]
	Test("actual model parent native greying resolved=" . Disabled, _LBMD_ModelParentGreyed.Bind(Disabled))
for Kind in ["withdrawn", "mutated", "replaced", "wrong-scalar"]
	Test("actual retained model parent refuses " . Kind . " and repairs", _LBMD_ModelParentRefuses.Bind(Kind))

_LBMD_ModelParentActualEmission(Withdrawn) {
	return _LBMD_WithHardwareLocale("en", _LBMD_WithDeclaredModelPicker.Bind(_LBMD_ModelParentActualEmissionCurrent.Bind(Withdrawn)))
}

_LBMD_ModelParentActualEmissionCurrent(Withdrawn, ExistingChild) {
	global _LLM_Menu, _LLM_Menu_Handle, _DriverInputInitPending, _SharedDir
	HadHandle := IsSet(_LLM_Menu_Handle)
	if HadHandle
		SavedHandle := _LLM_Menu_Handle
	HadPending := IsSet(_DriverInputInitPending)
	if HadPending
		SavedPending := _DriverInputInitPending
	Root := _MM_GetManifestRoot(), Declaration := Root["llm_model_parent_ahk"]
	Target := Menu(), Failed := false
	try {
		_LLM_Menu_Handle := Target
		; Preserve real probe functions; an actual cold-input prerequisite makes them inert.
		_DriverInputInitPending := true
		_LLM_Menu["last_health_status"] := "ok"
		if Withdrawn
			Root.Delete("llm_model_parent_ahk")
		; The emitter returns its rows; MenuRenderer_Build draws them.
		try MenuRenderer_AppendRows(Target, "llm_menu", "llm_model", _LLM_Menu_EmitRow(_LLM_Menu_Handle, "llm_model", false, true, true))
		catch
			Failed := true
		AssertEqual(Withdrawn, Failed)
		AssertEqual(Withdrawn ? 0 : 1, DllCall("GetMenuItemCount", "ptr", Target.Handle, "int"),
			"the actual emitter publishes only an admitted completed model parent")
		if !Withdrawn {
			Expected := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\windows_llm_model_health_parent_original.json", "UTF-8"))
			Label := Buffer(2048, 0)
			DllCall("GetMenuStringW", "ptr", Target.Handle, "uint", 0, "ptr", Label, "int", 1024, "uint", 0x400)
			AssertEqual(Expected["locales"]["en"]["titles"]["ok"][1], StrGet(Label, "UTF-16"))
			ChildHandle := DllCall("GetSubMenu", "ptr", Target.Handle, "int", 0, "ptr")
			Assert(ChildHandle && ChildHandle != ExistingChild.Handle, "the actual emitter constructs its genuine model picker")
			Assert(DllCall("GetMenuItemCount", "ptr", ChildHandle, "int") > 0)
		}
		AssertEqual("", _LLM_Menu["model"], "parent construction/refusal preserves the actual model setting")
		AssertFalse(_LLM_Menu["enabled"])
	} finally {
		Root["llm_model_parent_ahk"] := Declaration
		_CTC_ReleaseMenu(Target)
		_LLM_Menu_Handle := HadHandle ? SavedHandle : unset
		if HadPending
			_DriverInputInitPending := SavedPending
		else
			_DriverInputInitPending := unset
	}
}
for Withdrawn in [false, true]
	Test("actual model emitter declaration withdrawn=" . Withdrawn, _LBMD_ModelParentActualEmission.Bind(Withdrawn))

; The genuine cached-health read occurs only after the actual picker and both probe calls.
; This controlled Map method delegates all ordinary reads and withdraws only that declaration.
_LBMD_WithdrawModelParentAfterChild(Root, Observation, Store, Key) {
	global _MenuDispatchCallbacks, _MenuDispatchOwnerHandles
	if Key == "last_health_status" && !Observation["withdrawn"] {
		Observation["withdrawn"] := true
		for Id in _MenuDispatchCallbacks
			if !Observation["callbacks_before"].Has(Id)
				Observation["owned_ids"].Push(Id)
		for Handle in _MenuDispatchOwnerHandles
			if !Observation["handles_before"].Has(Handle)
				Observation["owned_handles"].Push(Handle)
		Root.Delete("llm_model_parent_ahk")
	}
	return Map.Prototype.Has.Call(Store, Key)
}

_LBMD_ModelParentLateRefusal() {
	return _LBMD_WithHardwareLocale("en", _LBMD_WithDeclaredModelPicker.Bind(_LBMD_ModelParentLateRefusalCurrent))
}

_LBMD_ModelParentLateRefusalCurrent(ExistingChild) {
	global _LLM_Menu, _LLM_Menu_Handle, _DriverInputInitPending
	global _MenuDispatchCallbacks, _MenuDispatchTokens, _MenuDispatchOwnerHandles
	HadHandle := IsSet(_LLM_Menu_Handle)
	if HadHandle
		SavedHandle := _LLM_Menu_Handle
	HadPending := IsSet(_DriverInputInitPending)
	if HadPending
		SavedPending := _DriverInputInitPending
	Root := _MM_GetManifestRoot(), Declaration := Root["llm_model_parent_ahk"]
	Target := Menu(), Foreign := Menu()
	try {
		AssertEqual(1, RegisterMenuItem(Foreign, "foreign detached model owner", _CTC_OwnedMenuProbe.Bind(Foreign, Foreign)))
		ForeignId := DllCall("GetMenuItemID", "ptr", Foreign.Handle, "int", 0, "uint")
		Observation := Map("withdrawn", false, "callbacks_before", _MenuDispatchCallbacks.Clone(),
			"handles_before", _MenuDispatchOwnerHandles.Clone(), "owned_ids", [], "owned_handles", [])
		_LLM_Menu.DefineProp("Has", {Call: _LBMD_WithdrawModelParentAfterChild.Bind(Root, Observation)})
		_LLM_Menu["last_health_status"] := "ok"
		_LLM_Menu_Handle := Target
		_DriverInputInitPending := true
		Failed := false
		try _LLM_Menu_EmitRow(_LLM_Menu_Handle, "llm_model", false, true, true)
		catch
			Failed := true
		_LLM_Menu.DeleteProp("Has")
		AssertTrue(Observation["withdrawn"], "the genuine health read withdraws the declaration after actual native child construction")
		Assert(Observation["owned_ids"].Length > 0 && Observation["owned_handles"].Length > 1,
			"this fixture reaches real registered provider/model descendants, not an empty invented owner")
		AssertTrue(Failed, "the retained real receiver refuses the late declaration withdrawal")
		AssertEqual(0, DllCall("GetMenuItemCount", "ptr", Target.Handle, "int"))
		for Id in Observation["owned_ids"] {
			AssertFalse(_MenuDispatchCallbacks.Has(Id), "every refused actual picker callback is retired")
			AssertFalse(_MenuDispatchTokens.Has(Id), "every refused actual picker token is retired")
		}
		for Handle in Observation["owned_handles"]
			AssertFalse(_MenuDispatchOwnerHandles.Has(Handle), "only the unpublished owned handles are retired")
		Assert(_MenuDispatchCallbacks.Has(ForeignId) && _MenuDispatchTokens.Has(ForeignId),
			"the foreign detached native callback/token remains live")
		Assert(_MenuDispatchOwnerHandles.Has(Foreign.Handle))
		AssertEqual(1, DllCall("GetMenuItemCount", "ptr", Foreign.Handle, "int"))
		Assert(DllCall("GetMenuItemCount", "ptr", ExistingChild.Handle, "int") > 0,
			"the preceding genuine detached picker remains intact")
		Root["llm_model_parent_ahk"] := Declaration
		MenuRenderer_AppendRows(Target, "llm_menu", "llm_model", _LLM_Menu_EmitRow(_LLM_Menu_Handle, "llm_model", false, true, true))
		AssertEqual(1, DllCall("GetMenuItemCount", "ptr", Target.Handle, "int"), "fresh actual receiver repair publishes the genuine picker")
	} finally {
		if Object.Prototype.HasOwnProp.Call(_LLM_Menu, "Has")
			_LLM_Menu.DeleteProp("Has")
		Root["llm_model_parent_ahk"] := Declaration
		; A red predecessor/control must also release any still-detached observed owned tree.
		Seen := Map()
		if IsSet(Observation) {
			for Handle in Observation["owned_handles"] {
				if DllCall("GetMenuItemCount", "ptr", Handle, "int") < 0
					continue
				Owned := MenuFromHandle(Handle)
				if Owned is Menu
					_CTC_ReleaseMenu(Owned, Seen)
			}
		}
		_CTC_ReleaseMenu(Target, Seen)
		_CTC_ReleaseMenu(Foreign, Seen)
		_LLM_Menu_Handle := HadHandle ? SavedHandle : unset
		if HadPending
			_DriverInputInitPending := SavedPending
		else
			_DriverInputInitPending := unset
	}
}
Test("actual model parent late withdrawal retires owned descendants and preserves foreign native owners", _LBMD_ModelParentLateRefusal)
