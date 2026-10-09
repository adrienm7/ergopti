; tests/unit/test_altgr_lctrl_not_typed.ahk

; ==============================================================================
; MODULE: AltGr's fake LCtrl is no Ctrl in the typed stream
; DESCRIPTION:
; The LCtrl tap-hold pushes "LControl" to the last-sent ring so a Ctrl chord
; breaks roll and hotstring sequences. On a standard AltGr layout every AltGr
; press begins with a fake LCtrl that reaches that hotkey first, so every AltGr
; press pushed "LControl": '<' then AltGr+the = key never gave the chevron_equal
; roll's '=' there, as it does on a Kana layout, whose AltGr has no LCtrl
; (std-altgr-lcontrol-ring-2026-09-26). The press is now recorded once it has
; resolved, unless the AltGr that followed marked it as AltGr's.
; ==============================================================================

#Requires AutoHotkey v2.0

; Run Body with SC01D physically down on the given layout family.
_ALNT_With(Kana, AltGrLevel, Body) {
	global _TapHoldKeyIsDown
	Saved := { KeyIsDown: _TapHoldKeyIsDown, Family: _TestSetAltGrFamily(Kana, AltGrLevel) }
	_TapHoldKeyIsDown := (Name, Mode) => (Name == "SC01D" and Mode == "P")
	try
		return Body.Call()
	finally {
		_TapHoldKeyIsDown := Saved.KeyIsDown
		_TestRestoreAltGrFamily(Saved.Family)
	}
}

_ALNT_AltGrMarksTheLCtrlPress() {
	_TH_TakeAltGrPress("left_ctrl")
	_ALNT_With(false, true, () => TapHoldAltGrTakesItsLCtrl(true))
	AssertTrue(_TH_TakeAltGrPress("left_ctrl"), "AZERTY: the LCtrl press an AltGr began with is AltGr's")
	AssertFalse(_TH_TakeAltGrPress("left_ctrl"), "the mark is read once")
	_ALNT_With(true, false, () => TapHoldAltGrTakesItsLCtrl(true))
	AssertFalse(_TH_TakeAltGrPress("left_ctrl"), "Kana: the AltGr key begins with no LCtrl")
	_ALNT_With(false, false, () => TapHoldAltGrTakesItsLCtrl(true))
	AssertFalse(_TH_TakeAltGrPress("left_ctrl"), "QWERTY: LCtrl then right Alt is the user's own chord")
}
Test("altgr lctrl ring: the LCtrl press an AltGr began with is marked as AltGr's (std-altgr-lcontrol-ring-2026-09-26)",
	_ALNT_AltGrMarksTheLCtrlPress)

_ALNT_OnlyAUserLCtrlIsRecorded() {
	global _Stub_LastChars
	for _, Name in ["_LCtrlHandleHold", "_LCtrlHandleTapOnly"] {
		Body := _DriverFuncBody(Name)
		Record := InStr(Body, "TapHoldRecordLCtrlPress()")
		Wait := Max(InStr(Body, "TapHoldOwnImmediateModifier("), InStr(Body, 'KeyWait("SC01D"'))
		AssertFalse(InStr(Body, 'UpdateLastSentCharacter("LControl")') > 0, Name . " must not push LControl before it knows")
		AssertTrue(Wait > 0 and Record > Wait, Name . " must record the press once it has resolved, after the AltGr that followed it")
	}
	Saved := _Stub_LastChars.Clone()
	try {
		_Stub_LastChars := []
		_ALNT_With(false, true, () => TapHoldAltGrTakesItsLCtrl(true))
		TapHoldRecordLCtrlPress()
		AssertEqual(0, _Stub_LastChars.Length, "an AltGr press must not push LControl to the last-sent ring")
		TapHoldRecordLCtrlPress()
		AssertEqual("LControl", _Stub_LastChars.Length ? _Stub_LastChars[-1] : "",
			"a real LCtrl press still ends the typed sequence")
	} finally {
		_Stub_LastChars := Saved
	}
}
Test("altgr lctrl ring: only a user's LCtrl press is recorded in the typed stream (std-altgr-lcontrol-ring-2026-09-26)",
	_ALNT_OnlyAUserLCtrlIsRecorded)
