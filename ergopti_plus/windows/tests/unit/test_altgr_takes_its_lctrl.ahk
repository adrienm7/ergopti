; tests/unit/test_altgr_takes_its_lctrl.ahk

; ==============================================================================
; MODULE: An AltGr press takes back the fake LCtrl a left_ctrl tap-hold took
; DESCRIPTION:
; On a standard AltGr layout every AltGr press starts with a fake LCtrl that
; the hook reads as SC01D. With LCtrl's tap-hold holding anything but Ctrl
; (Alt, Shift, Ctrl+Shift from the hold picker):
; - with AltGr's own tap-hold off, the suppressing "*$SC01D" fired on that fake
;   LCtrl, suppressed it and pressed its hold, so the system got [hold]+RAlt,
;   not AltGr (std-altgr-fake-lctrl-2026-09-26);
; - with AltGr's tap-hold on, "SC01D & SC138" made SC01D a suppressed prefix:
;   AutoHotkey held the fake LCtrl back and dropped it, so the system saw a lone
;   RAlt (a plain Alt), and the same deferral postponed a real LCtrl's hold to
;   its release: LCtrl held as Alt then Tab typed Tab, not Alt+Tab
;   (lctrl-hold-deferred-2026-09-26).
; The SC01D combinations now carry ~ on the prefix, so the left_ctrl hotkey
; fires on the press, and when that press turns out to be AltGr's the hold is
; handed back and LCtrl held for AltGr. The cases drive the real owner with a
; recorded sender; no key is sent.
; ==============================================================================

#Requires AutoHotkey v2.0

global _ATIL_Sent := []

; The real left_ctrl owner holding ModKey on the given layout family; the
; release wait lets AltGr arrive (Arrive) mid-hold before the key comes up.
; Returns the wire, the owner's verdict and the ledger it left.
_ATIL_Press(Kana, AltGrLevel, ModKey, Arrive, AsAltGr := true, KeyId := "left_ctrl") {
	global _AHK_SendInput, _TapHoldKeyIsDown, _ATIL_Sent
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys, _TH_SyntheticUserHeldKeys
	Saved := { Send: _AHK_SendInput, KeyIsDown: _TapHoldKeyIsDown, Held: _TH_SyntheticHeldKeys,
		Pending: _TH_SyntheticReleasePendingKeys, UserHeld: _TH_SyntheticUserHeldKeys,
		Family: _TestSetAltGrFamily(Kana, AltGrLevel) }
	_ATIL_Sent := []
	_TH_SyntheticHeldKeys := Map()
	_TH_SyntheticReleasePendingKeys := Map()
	_TH_SyntheticUserHeldKeys := Map()
	_AHK_SendInput := (Keys) => _ATIL_Sent.Push(Keys)
	; SC01D physically down (the fake LCtrl this press began with), nothing
	; else down.
	_TapHoldKeyIsDown := (Name, Mode) => (Name == "SC01D" and Mode == "P")
	try {
		Wait := (*) => (Arrive ? TapHoldAltGrTakesItsLCtrl(AsAltGr) : 0, true)
		Result := TapHoldOwnImmediateModifier(KeyId, "SC01D", ModKey, 0.2,
			Wait, (*) => false, (*) => 1000, , , (*) => "")
		Wire := ""
		for _, Keys in _ATIL_Sent
			Wire .= (Wire == "" ? "" : "|") . Keys
		return { Wire: Wire, Tap: Result["tap"], Released: Result["released"],
			Left: _TH_SyntheticHeldKeys.Count + _TH_SyntheticReleasePendingKeys.Count }
	} finally {
		_AHK_SendInput := Saved.Send
		_TapHoldKeyIsDown := Saved.KeyIsDown
		_TH_SyntheticHeldKeys := Saved.Held
		_TH_SyntheticReleasePendingKeys := Saved.Pending
		_TH_SyntheticUserHeldKeys := Saved.UserHeld
		_TestRestoreAltGrFamily(Saved.Family)
	}
}

_ATIL_AltGrGetsItsLCtrlBack() {
	Mask := "{Blind}{" . A_MenuMaskKey . "}"
	Press := _ATIL_Press(false, true, "LAlt", true)
	AssertEqual("{LAlt Down}|" . Mask . "|{LAlt Up}|{LCtrl Down}|{LCtrl Up}", Press.Wire,
		"AZERTY: the LAlt hold is handed back (masked) and LCtrl held for AltGr until the press ends")
	AssertFalse(Press.Tap, "an AltGr press is never the left_ctrl tap")
	AssertTrue(Press.Released, "the handed-back hold counts as released")
	AssertEqual(0, Press.Left, "nothing is left held or release-pending")
	Press := _ATIL_Press(false, true, ["LCtrl", "LShift"], true)
	AssertEqual("{LCtrl Down}|{LShift Down}|{LCtrl Up}|{LShift Up}|{LCtrl Down}|{LCtrl Up}", Press.Wire,
		"a Ctrl+Shift hold is handed back too, and LCtrl alone is held for AltGr")
	Press := _ATIL_Press(false, true, "LAlt", true, false)
	AssertEqual("{LAlt Down}|" . Mask . "|{LAlt Up}", Press.Wire,
		"AltGr held as another modifier: the left_ctrl hold is handed back and no LCtrl given")
}
Test("altgr lctrl: an AltGr press takes back the fake LCtrl a left_ctrl hold took (std-altgr-fake-lctrl-2026-09-26)",
	_ATIL_AltGrGetsItsLCtrlBack)

_ATIL_OnlyWhereAltGrHasAFakeLCtrl() {
	Mask := "{Blind}{" . A_MenuMaskKey . "}"
	Normal := "{LAlt Down}|" . Mask . "|{LAlt Up}"
	Press := _ATIL_Press(true, false, "LAlt", true)
	AssertEqual(Normal, Press.Wire, "Kana: the AltGr key adds no LCtrl, the left_ctrl hold is the user's")
	AssertTrue(Press.Tap, "Kana: the left_ctrl press keeps its tap")
	Press := _ATIL_Press(false, false, "LAlt", true)
	AssertEqual(Normal, Press.Wire, "QWERTY: right Alt is a plain Alt, LCtrl then RAlt is the user's chord")
	Press := _ATIL_Press(false, true, "LAlt", false)
	AssertEqual(Normal, Press.Wire, "no AltGr during the press: the hold is untouched")
	AssertTrue(Press.Tap, "and its tap survives")
	Press := _ATIL_Press(false, true, "LCtrl", true, true, "caps_lock")
	AssertEqual("{LCtrl Down}|{LCtrl Up}", Press.Wire, "another key's hold is never taken for AltGr's LCtrl")
}
Test("altgr lctrl: only a layout whose AltGr adds a fake LCtrl hands the hold back (std-altgr-fake-lctrl-2026-09-26)",
	_ATIL_OnlyWhereAltGrHasAFakeLCtrl)

; The SC01D combinations carry ~ on the prefix, so the left_ctrl hotkey fires on
; the LCtrl press instead of its release, and both detectors are wired.
_ATIL_TheWiringIsInPlace() {
	Src := _StripFullLineComments(_DriverDirConcat("platform/remap"))
	Bare := RegExMatch(Src, "m)^SC01D & ")
	AssertEqual(0, Bare, "every SC01D combination must carry ~ on its prefix, or AutoHotkey postpones the left_ctrl hold to the LCtrl release")
	StrReplace(Src, "~SC01D & ", , , &Tilded)
	AssertTrue(Tilded >= 3, "the AltGr owners and the navigation Escape must still be SC01D combinations (found " . Tilded . ")")
	Owner := _DriverFuncBody("_AltGrHandleHold")
	AssertTrue(InStr(Owner, "TapHoldAltGrTakesItsLCtrl(Passthrough)") > 0,
		"the AltGr owner must take its fake LCtrl back from a left_ctrl hold")
	Dispatcher := _StripFullLineComments(_DriverDirConcat("infra"))
	KeyDown := InStr(Dispatcher, "static _OnKeyDown(ih, vk, sc) {")
	AssertTrue(KeyDown > 0, "HookDispatcher._OnKeyDown must exist")
	Body := SubStr(Dispatcher, KeyDown, InStr(Dispatcher, "static _OnKeyUp(", , KeyDown) - KeyDown)
	AssertTrue(InStr(Body, "TapHoldTrackAltGrLCtrl(vk, sc)") > 0,
		"the key-down dispatcher must let a passed-through AltGr RAlt take its fake LCtrl back")
}
Test("altgr lctrl: the SC01D prefixes pass through and both detectors are wired (lctrl-hold-deferred-2026-09-26)",
	_ATIL_TheWiringIsInPlace)
