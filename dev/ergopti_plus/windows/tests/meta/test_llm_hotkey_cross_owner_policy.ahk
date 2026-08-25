; tests/meta/test_llm_hotkey_cross_owner_policy.ahk

; ==============================================================================
; MODULE: LLM Cross-Owner Hotkey Policy Meta Test
; DESCRIPTION:
; Source guard for the static tooltip-Tab owner, the only contextual LLM hotkey
; which cannot be exercised through the injected profile/navigation registrars,
; for raw and wildcard pointer observers whose input surface overlaps trigger
; variants, and for the raw
; clipboard owner whose textual permanent name must remain visible after the
; registrar freezes character hotkeys to explicit VK specs.
; ==============================================================================

#Requires AutoHotkey v2.0

_LHCM_StaticTabMatchesCollisionPolicy() {
	PolicyBody := _DriverFuncBody("_LLM_Menu_BuildContextualHotkeyOwners")
	Assert(PolicyBody != "",
		"the contextual collision policy must remain reachable")
	Assert(InStr(PolicyBody, 'Owners, "Tab"') > 0
			&& InStr(PolicyBody, '"tooltip acceptance"') > 0,
		"the collision policy must reserve the static tooltip Tab identity")

	Source := _StripFullLineComments(_DriverDirConcat("ui/menu/menu_llm"))
	HotIfPos := RegExMatch(Source,
		'm)^\s*#HotIf\s+LLM_Tooltip_GetText\(\)\s*!=\s*""\s*$')
	Assert(HotIfPos > 0,
		"the physical Tab owner must remain gated by visible tooltip state")
	TabPos := RegExMatch(Source,
		'ms)^\s*Tab::\s*\{\s*(.*?)^\s*\}\s*$', &TabMatch, HotIfPos)
	DirectivePos := InStr(Source, "#HotIf", true, HotIfPos)
	NextHotIfPos := InStr(Source, "#HotIf", true, DirectivePos + 6)
	Assert(TabPos > HotIfPos
			&& (NextHotIfPos == 0 || TabPos < NextHotIfPos),
		"no intervening HotIf owner may repoint the reserved Tab variant")
	Assert(InStr(TabMatch[1], "LLM_Tooltip_FireTabOrAccept([], true)") > 0,
		"the reserved Tab identity must invoke the canonical acceptance owner")
}

_LHCM_RawPointerObserversMatchTriggerRefusal() {
	Source := _DriverSourceNoComments()
	Assert(Source != "",
		"the pointer-owner inventory source must remain readable")
	ObserverKeys := Map()
	WildcardCount := 0
	WildcardDownCount := 0
	ScanPos := 1
	while (CallPos := RegExMatch(Source,
			'is)HookDispatcher\._SafeHotkey\(\s*"~\*([^"]+)"\s*,',
			&CallMatch, ScanPos)) {
		Key := StrLower(CallMatch[1])
		WildcardCount += 1
		if !InStr(Key, " ") {
			WildcardDownCount += 1
			ObserverKeys[Key] := true
		}
		ScanPos := CallPos + StrLen(CallMatch[0])
	}
	AssertEqual(14, WildcardCount,
		"the complete wildcard pointer owner inventory must stay explicit")
	AssertEqual(9, WildcardDownCount,
		"the wildcard pointer-down owner inventory must stay complete")

	StartBody := _StripFullLineComments(
		_DriverFuncBody("_LLM_PointerWatch_Start"))
	Assert(StartBody != "",
		"the direct pointer watcher owner body must remain reachable")
	DirectCount := 0
	ScanPos := 1
	while (CallPos := RegExMatch(StartBody,
			'is)Hotkey\(\s*"~(xbutton[12])"\s*,\s*'
			. '_LLM_PointerWatch_ActivityFn\s*,\s*"On"\s*\)',
			&CallMatch, ScanPos)) {
		DirectCount += 1
		ObserverKeys[StrLower(CallMatch[1])] := true
		ScanPos := CallPos + StrLen(CallMatch[0])
	}
	AssertEqual(2, DirectCount,
		"the direct XButton watcher inventory must stay complete")

	Expected := ["lbutton", "rbutton", "mbutton", "xbutton1", "xbutton2",
		"wheelup", "wheeldown", "wheelleft", "wheelright"]
	AssertEqual(Expected.Length, ObserverKeys.Count,
		"every pointer-down observer must map to one reserved trigger key")
	ModifierPrefixes := ["", "Ctrl+", "Alt+", "Shift+", "Cmd+",
		"Ctrl+Alt+", "Ctrl+Shift+", "Ctrl+Cmd+", "Alt+Shift+",
		"Alt+Cmd+", "Shift+Cmd+", "Ctrl+Alt+Shift+", "Ctrl+Alt+Cmd+",
		"Ctrl+Shift+Cmd+", "Alt+Shift+Cmd+", "Ctrl+Alt+Shift+Cmd+"]
	for Key in Expected {
		Assert(ObserverKeys.Has(Key),
			"the pointer-owner inventory must contain " . Key)
		for Prefix in ModifierPrefixes {
			AssertEqual("", LLM_Menu_ShortcutToAhk(Prefix . Key),
				"the wildcard pointer owner must reject modifier surface: "
				. Prefix . Key)
		}
	}
}

_LHCM_TextualClipboardOwnerRemainsVisibleToFrozenAdmission() {
	ClipboardBody := _StripFullLineComments(_DriverFuncBody("KL_Clip_Start"))
	Assert(ClipboardBody != "",
		"the raw clipboard hotkey producer must remain reachable")
	Assert(RegExMatch(ClipboardBody,
		'is)Hotkey\(\s*"~\^v"\s*,\s*KL_Clip_OnPasteHK\s*,\s*"On"\s*\)') > 0,
		"the production inventory must retain the raw textual Ctrl+V owner")

	ReserveBody := _StripFullLineComments(
		_DriverFuncBody("_HotkeyRegistrarReserveOwned"))
	Assert(ReserveBody != "",
		"the registrar reservation boundary must remain reachable")
	ClaimPos := InStr(ReserveBody, "HOTKEY_REGISTRAR_SPECS[spec] := entry")
	DisplayProbePos := InStr(ReserveBody,
		"_HotkeyRegistrarNativeExists(DisplaySpec")
	FrozenProbePos := InStr(ReserveBody,
		"_HotkeyRegistrarNativeExists(spec")
	InstallPos := InStr(ReserveBody, "_HotkeyRegistrarInvoke(spec")
	Assert(ClaimPos > 0 && DisplayProbePos > ClaimPos
			&& FrozenProbePos > DisplayProbePos && InstallPos > FrozenProbePos,
		"a frozen character claim must probe its textual permanent name before "
		. "the explicit VK name and before any native install")
}

Test("[llm-hotkey-collision] static Tab owner matches the collision policy",
	_LHCM_StaticTabMatchesCollisionPolicy)

Test("[llm-hotkey-collision] pointer observers reject every overlapping trigger",
	_LHCM_RawPointerObserversMatchTriggerRefusal)

Test("[llm-hotkey-collision] frozen specs still see raw textual owners",
	_LHCM_TextualClipboardOwnerRemainsVisibleToFrozenAdmission)
