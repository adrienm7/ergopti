; tests/unit/test_user_lctrl_held.ahk

; ==============================================================================
; MODULE: AltGr's fake LCtrl is not the user's LCtrl
; DESCRIPTION:
; On a standard AltGr layout Windows adds a fake LCtrl to every AltGr press,
; which AutoHotkey records as physically down (hook.cpp: "fake LCtrl is marked
; as physical"). BackSpaceLogic read that as "LCtrl physically held": with
; AltGr held and LAlt tapped as Backspace (AltGr+LAlt shortcut off, or the
; plain Backspace LAlt), it sent Ctrl+Backspace and deleted a whole word, and
; Ctrl+Delete under AltGr+Shift, where a Kana layout, whose AltGr adds no Ctrl,
; sent Backspace and Delete (std-altgr-fake-lctrl-backspace-2026-09-26).
; ==============================================================================

#Requires AutoHotkey v2.0

; A key-state stand-in where exactly the keys named in Down are held.
_ULH_Keys(Down*) {
	Held := Map()
	for _, Name in Down
		Held[Name] := true
	return (Name) => Held.Has(Name)
}

_ULH_AltGrLCtrlIsNotTheUsers() {
	Body := _DriverFuncBody("BackSpaceLogic")
	AssertFalse(InStr(Body, 'KS_IsDown("SC01D")') > 0,
		"BackSpaceLogic must not read AltGr's fake LCtrl as the user's LCtrl")
	StrReplace(Body, "TapHoldUserLCtrlHeld()", , , &Reads)
	AssertEqual(3, Reads, "every LCtrl branch of BackSpaceLogic must ask for the user's own LCtrl")
	Family := _TestSetAltGrFamily(false)
	try {
		AssertFalse(TapHoldUserLCtrlHeld(_ULH_Keys("SC01D", "RAlt")),
			"standard layout: LCtrl with RAlt physically down is AltGr's fake LCtrl")
		AssertTrue(TapHoldUserLCtrlHeld(_ULH_Keys("SC01D")), "a real LCtrl alone is the user's")
		AssertFalse(TapHoldUserLCtrlHeld(_ULH_Keys("RAlt")), "no LCtrl at all")
	} finally _TestRestoreAltGrFamily(Family)
	Family := _TestSetAltGrFamily(true)
	try {
		AssertTrue(TapHoldUserLCtrlHeld(_ULH_Keys("SC01D", "SC138")),
			"Kana layout: the AltGr key adds no Ctrl, so a physical LCtrl is the user's")
	} finally _TestRestoreAltGrFamily(Family)
}
Test("user lctrl: AltGr's fake LCtrl is not the user's LCtrl (std-altgr-fake-lctrl-backspace-2026-09-26)",
	_ULH_AltGrLCtrlIsNotTheUsers)

; On QWERTY right Alt is a plain Alt with no fake LCtrl (the boot probe finds no
; AltGr level), so a physical LCtrl held with it is the user's: LCtrl+RAlt then
; LAlt tapped as Backspace must take the Ctrl+Backspace branch, not the
; additive Ctrl+Alt+Backspace (qwerty-user-lctrl-2026-09-26).
_ULH_QwertyLCtrlWithRAltIsTheUsers() {
	Family := _TestSetAltGrFamily(false, false)
	try {
		AssertTrue(TapHoldUserLCtrlHeld(_ULH_Keys("SC01D", "RAlt")),
			"QWERTY: a physical LCtrl held with the right Alt is the user's Ctrl")
		AssertTrue(TapHoldUserLCtrlHeld(_ULH_Keys("SC01D")), "QWERTY: a real LCtrl alone is the user's")
		AssertFalse(TapHoldUserLCtrlHeld(_ULH_Keys("RAlt")), "QWERTY: no LCtrl at all")
	} finally _TestRestoreAltGrFamily(Family)
}
Test("user lctrl: on QWERTY an LCtrl held with right Alt is the user's (qwerty-user-lctrl-2026-09-26)",
	_ULH_QwertyLCtrlWithRAltIsTheUsers)
