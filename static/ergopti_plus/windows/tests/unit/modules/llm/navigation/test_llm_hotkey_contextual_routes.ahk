; tests/unit/modules/llm/navigation/test_llm_hotkey_contextual_routes.ahk

; ==============================================================================
; MODULE: LLM Hotkey Contextual Routes
; DESCRIPTION:
; Contextual LLM hotkey owners keep their exact eligible routing, profile
; and navigation hotkeys arbitrate one physical native owner across
; layouts, and the policy compares canonical native identities.
; ==============================================================================

#Requires AutoHotkey v2.0





_LHCC_ContextualRoutesCore() {
	global _LLM_Menu, _LLM_Menu_Loaded
	global _LPHT_SelectedProfiles, _LPHT_AppOutput
	global _LNHT_AppOutput, _LNHT_TooltipActiveIdx
	global _LHCC_ContextualRoutingCompleted
	_LHCC_ContextualRoutingCompleted := false
	_LLM_Menu["nav_modifiers"] := "alt"
	_LLM_Menu["val_modifiers"] := "alt"
	_LLM_Menu_Loaded := true

	ProfileStatus := _LPHT_ProfileBindSelectPort()
	AssertTrue((ProfileStatus is Integer) && ProfileStatus == 1)
	NavStatus := LLM_Menu_BindNavHotkeys(_LLM_Menu, _LNHT_Hotkey,
		_LNHT_HotIf, _LNHT_Log, _LNHT_ForceHotIfReset)
	AssertTrue((NavStatus is Integer) && NavStatus == 1)

	ProfileEvent := Map("owner", "physical-profile-5")
	_LPHT_SelectedProfiles := []
	_LPHT_AppOutput := []
	ProfileOrder := LLM_Menu_GetHotkeyProfileOrder()
	ProfileNative5 := _LPHT_NativeSpec("^5")
	AssertEqual("hotkey", _LPHT_FirePhysical("^5", ProfileEvent,
		ProfileNative5, true))
	AssertEqual(1, _LPHT_SelectedProfiles.Length)
	AssertEqual(ProfileOrder[5], _LPHT_SelectedProfiles[1])
	AssertEqual(0, _LPHT_AppOutput.Length)

	_LLM_Menu["user_profiles"] := []
	PassEvent := Map("owner", "physical-profile-pass")
	AssertEqual("app", _LPHT_FirePhysical("^5", PassEvent,
		ProfileNative5))
	AssertEqual(1, _LPHT_AppOutput.Length)
	AssertTrue(_LPHT_AppOutput[1] == PassEvent,
		"an ineligible profile variant must preserve the exact physical event")

	_LNHT_AppOutput := []
	_LNHT_ShowTooltip(["one", "two", "three", "four", "five", "six",
		"seven"])
	AssertEqual("hotkey", _LNHT_FirePhysical("!7"))
	AssertEqual(7, _LNHT_TooltipActiveIdx)
	AssertEqual(0, _LNHT_AppOutput.Length)
	_LNHT_HideTooltip()
	AssertEqual("app", _LNHT_FirePhysical("!7"))
	AssertEqual(1, _LNHT_AppOutput.Length)
	AssertEqual("!7", _LNHT_AppOutput[1],
		"an ineligible navigation variant must reach the app exactly once")
	_LNHT_AppOutput := []
	_LNHT_ShowTooltip(["one", "two", "three", "four", "five", "six"])
	AssertEqual("app", _LNHT_FirePhysical("!7"))
	AssertEqual(1, _LNHT_AppOutput.Length)
	AssertEqual("!7", _LNHT_AppOutput[1],
		"an out-of-range visible nav digit must reach the app unchanged")
	_LHCC_ContextualRoutingCompleted := true
	return true
}

_LHCC_ContextualRoutesNavFixture() {
	return _LNHT_WithFixture(_LHCC_ContextualRoutesCore)
}

_LHCC_ContextualRoutes() {
	global _LHCC_ContextualRoutingCompleted
	Result := _LPHT_WithFixture(_LHCC_ContextualRoutesNavFixture)
	AssertTrue(_LHCC_ContextualRoutingCompleted,
		"the nested owner fixture must reach every terminal routing assertion")
	return Result
}
Test("[llm-hotkey-collision] contextual owners retain exact eligible routing",
	_LHCC_ContextualRoutes)

_LHCC_CrossLayoutProfileNavPriorityCore() {
	global _LLM_Menu, _LLM_Menu_Loaded, _LLM_PROFILE_HOTKEY_PRED
	global _LLM_Menu_NavActiveSlot, _LHCC_CrossLayoutPriorityCompleted
	_LHCC_CrossLayoutPriorityCompleted := false
	_LLM_Menu["nav_modifiers"] := "alt"
	_LLM_Menu["val_modifiers"] := "ctrl+shift"
	_LLM_Menu_Loaded := true
	ProfileStatus := LLM_Menu_BindProfileHotkeys(_LPHT_Hotkey,
		_LPHT_HotIf, _LPHT_Log, _LPHT_ForceReset, _LPHT_Select,
		_LHCC_FrenchPhysicalKey)
	AssertTrue((ProfileStatus is Integer) && ProfileStatus == 1)
	NavStatus := LLM_Menu_BindNavHotkeys(_LLM_Menu, _LNHT_Hotkey,
		_LNHT_HotIf, _LNHT_Log, _LNHT_ForceHotIfReset,
		_LHCC_UsPhysicalKey)
	AssertTrue((NavStatus is Integer) && NavStatus == 1)
	_LNHT_ShowTooltip(["one", "two", "three", "four", "five"])
	PermanentName := "+^VK35"
	AssertTrue(LLM_Menu_NavOwnsSpec(PermanentName))
	AssertTrue(_LLM_Menu_NavSlotPredicate(
		_LLM_Menu_NavActiveSlot).Call(PermanentName))
	AssertFalse(_LLM_PROFILE_HOTKEY_PRED.Call(PermanentName),
		"the profile owner must yield only to the exact physical nav variant")
	_LNHT_HideTooltip()
	try HiddenOwns := LLM_Menu_NavOwnsSpec(PermanentName)
	catch as Err {
		throw Error("hidden nav ownership raised: " . Err.Message, -1,
			Err.Extra)
	}
	AssertFalse(HiddenOwns)
	AssertTrue(_LLM_PROFILE_HOTKEY_PRED.Call(PermanentName))

	_LLM_Menu["val_modifiers"] := "ctrl"
	DistinctNavStatus := LLM_Menu_BindNavHotkeys(_LLM_Menu, _LNHT_Hotkey,
		_LNHT_HotIf, _LNHT_Log, _LNHT_ForceHotIfReset,
		_LHCC_UsPhysicalKey)
	AssertTrue((DistinctNavStatus is Integer) && DistinctNavStatus == 1)
	_LNHT_ShowTooltip(["one", "two", "three", "four", "five"])
	AssertFalse(LLM_Menu_NavOwnsSpec(PermanentName))
	AssertTrue(_LLM_PROFILE_HOTKEY_PRED.Call(PermanentName),
		"a physically distinct US nav digit must not disable the FR profile")
	_LHCC_CrossLayoutPriorityCompleted := true
	return true
}

_LHCC_CrossLayoutProfileNavPriorityNavFixture() {
	return _LNHT_WithFixture(_LHCC_CrossLayoutProfileNavPriorityCore)
}

_LHCC_CrossLayoutProfileNavPriority() {
	global _LHCC_CrossLayoutPriorityCompleted
	Result := _LPHT_WithFixture(_LHCC_CrossLayoutProfileNavPriorityNavFixture)
	AssertTrue(_LHCC_CrossLayoutPriorityCompleted,
		"the cross-layout priority fixture must reach exact predicate routing")
	return Result
}
Test("[llm-hotkey-collision] profile and nav arbitrate one physical native owner",
	_LHCC_CrossLayoutProfileNavPriority)

_LHCC_CanonicalIdentities() {
	AssertEqual("!7", LLM_Menu_ShortcutToAhk("ALT+7"))
	AssertEqual("^+7", LLM_Menu_ShortcutToAhk("CONTROL+SHIFT+7"))
	AssertEqual("^up", LLM_Menu_ShortcutToAhk("CONTROL+UP"))
	AssertEqual("^5", LLM_Menu_ShortcutToAhk("CONTROL+5"))
	AssertEqual("^l", LLM_Menu_ShortcutToAhk("CONTROL+L"))
	AssertEqual("tab", LLM_Menu_ShortcutToAhk("TAB"))
	AssertEqual("^+7", _LLM_Menu_NavNativeIdentity("~+^7"))
	AssertEqual("^up", _LLM_Menu_NavNativeIdentity("~^Up"))
	AssertFalse(_LLM_Menu_NavNativeIdentity("^0")
		== _LLM_Menu_NavNativeIdentity("^5"))
	AssertFalse(_LLM_Menu_NavNativeIdentity("^tab")
		== _LLM_Menu_NavNativeIdentity("tab"))
	PointerKeys := ["LButton", "RButton", "MButton", "XButton1", "XButton2",
		"WheelUp", "WheelDown", "WheelLeft", "WheelRight"]
	ModifierPrefixes := ["", "Ctrl+", "Alt+", "Shift+", "Cmd+",
		"Ctrl+Alt+", "Ctrl+Shift+", "Ctrl+Cmd+", "Alt+Shift+",
		"Alt+Cmd+", "Shift+Cmd+", "Ctrl+Alt+Shift+", "Ctrl+Alt+Cmd+",
		"Ctrl+Shift+Cmd+", "Alt+Shift+Cmd+", "Ctrl+Alt+Shift+Cmd+"]
	for Key in PointerKeys {
		for Prefix in ModifierPrefixes {
			AssertEqual("", LLM_Menu_ShortcutToAhk(Prefix . Key),
				"pointer observers must retain every modifier surface: "
				. Prefix . Key)
		}
	}
	AssertEqual("^up", LLM_Menu_ShortcutToAhk("Ctrl+Up"))
	AssertEqual("^f13", LLM_Menu_ShortcutToAhk("Ctrl+F13"))
	for RawText in [
		"VK09", "SC00F", "VK09SC00F",
		"Ctrl+VK35", "Ctrl+SC006", "Ctrl+VK35SC006",
		"Alt+VK37", "Alt+SC008", "Alt+VK37SC008",
		"Alt+VK26", "Alt+SC148", "Alt+VK26SC148",
		"*Tab", "Ctrl+*5", "Alt+*7", "Alt+*Up", "Ctrl+5 Up",
		"LButton", "RButton", "MButton", "XButton1", "XButton2",
		"WheelUp", "WheelDown", "WheelLeft", "WheelRight",
		"Ctrl+LButton", "Alt+XButton2", "Shift+WheelUp",
		"LCtrl", "LControl", "RCtrl", "RControl", "LAlt", "RAlt",
		"LShift", "RShift", "LWin", "RWin"
	] {
		AssertEqual("", LLM_Menu_ShortcutToAhk(RawText),
			"the LLM chord grammar must reject native AHK syntax " . RawText)
	}
}
Test("[llm-hotkey-collision] policy compares canonical native identities",
	_LHCC_CanonicalIdentities)
