; tests/meta/modules/shortcuts/test_capsword_auto_off_single_source.ahk

; ==============================================================================
; MODULE: CapsWord Auto-Off Single Source (Windows)
; DESCRIPTION:
; The CapsWord delimiters are the hotstring delimiter catalogue, the delay
; presets and the pointer kinds are the manifest's. Windows ended CapsWord on
; a fixed list of its own (TAP_HOLD_CAPSWORD_TERMINATORS, Space and Enter
; hotkeys, two mouse buttons) that no setting could change. This guard fails
; when a Windows CapsWord source spells a delimiter list, the presets, or the
; pointer kinds outside the one adapter mapping of native events to kinds.
; Only Space and Enter may be named: capsword.ahk binds those two keys itself.
; ==============================================================================

#Requires AutoHotkey v2.0




; The CapsWord sources: the shortcut modules and the tap-hold dispatcher rule.
_CWSS_Source() {
	Rule := _DriverFuncBody("_TapHoldTapEndsCapsWord")
	Assert(Rule != "", "_TapHoldTapEndsCapsWord must exist")
	Src := _DriverDirConcat("modules/shortcuts") . "`n" . Rule
	for Name in ["CapsWordEndCallback", "CapsWordHandleAutoOff", "CapsWordActivationToggle", "CapsWordDeactivate",
			"CapsWordSyncLed"]
		Src .= "`n" . _DriverFuncBody(Name)
	Src := _StripFullLineComments(Src)
	Assert(InStr(Src, "CapsWordAutoOffArm(") > 0, "the CapsWord sources must be readable")
	return Src
}

_CWSS_NoDelimiterList() {
	Src := _CWSS_Source()
	Named := []
	Checked := 0
	for Row in CapsWordAutoOffTerminatorRows() {
		if Row.Has("separator")
			continue
		Checked++
		if InStr(Src, '"' . Row["key"] . '"', true)
			Named.Push(Row["key"])
	}
	Assert(Checked >= 20, "the generated catalogue must be readable, got " . Checked . " delimiter(s)")
	Spelled := ""
	for Key in Named {
		if Key != "space" && Key != "enter"
			Spelled .= (Spelled == "" ? "" : ", ") . Key
	}
	AssertEqual("", Spelled,
		"a Windows CapsWord source names delimiters beyond the Space and Enter it binds: read them through the policy")
	Assert(!InStr(Src, "TAP_HOLD_CAPSWORD_TERMINATORS"), "the retired fixed tap-hold delimiter list must stay gone")
}
Test("capsword auto-off: no Windows CapsWord source keeps a delimiter list", _CWSS_NoDelimiterList)

_CWSS_NoPresetList() {
	Entry := ManifestFindEntryByPath("shortcuts.caps_word.idle_timeout_seconds")
	Assert(Entry is Map, "the delay feature must be declared")
	Src := _CWSS_Source()
	Assert(!RegExMatch(Src, "[\[(]\s*0\s*,\s*1\s*,\s*3\s*,\s*5\b"),
		"a Windows CapsWord source spells the delay presets: the menu reads them from the manifest")
}
Test("capsword auto-off: no Windows CapsWord source spells the delay presets", _CWSS_NoPresetList)

_CWSS_PointerKindsOnlyInTheMapping() {
	Src := _CWSS_Source()
	; The adapter's own half of the list: native event -> kind, and the click
	; kinds that release a gesture click-hold.
	for Name in ["CapsWordAutoOffPointerEvents", "CapsWordAutoOffPolledKind", "CapsWordHandleAutoOff"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . " must exist")
		Src := StrReplace(Src, _StripFullLineComments(Body), "")
	}
	Kinds := CapsWordAutoOffPointerKinds()
	Assert(Kinds.Length >= 5, "the manifest must declare the Windows pointer kinds")
	Spelled := ""
	for Kind in Kinds {
		if InStr(Src, '"' . Kind . '"', true)
			Spelled .= (Spelled == "" ? "" : ", ") . Kind
	}
	AssertEqual("", Spelled,
		"pointer kinds named outside the native event mapping: iterate CapsWordAutoOffPointerKinds() instead")
}
Test("capsword auto-off: pointer kinds are named only by the native event mapping", _CWSS_PointerKindsOnlyInTheMapping)
