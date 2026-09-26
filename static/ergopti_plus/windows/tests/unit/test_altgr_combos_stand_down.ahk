; tests/unit/test_altgr_combos_stand_down.ahk

; ==============================================================================
; MODULE: The AltGr combinations stand down while AltGr holds something else
; DESCRIPTION:
; Every "SC138 & X" combination (the AltGr layer, the rolls, AltGr+LAlt,
; AltGr+CapsLock, the script chords) is gated on IsRealAltGrPress, which was
; always true on a Kana layout. With the AltGr key held as Ctrl, AltGr+C then
; typed the AltGr layer's character instead of Ctrl+C, and AltGr+Enter ran a
; script chord instead of Ctrl+Enter (kana-altgr-hold-other-2026-09-26). The
; key held as another modifier or a layer is that modifier or layer on every
; layout, so the gate is false then. The Kana family is driven here: the
; standard family's gate also needs the physical RAlt, which no test can press.
; ==============================================================================

#Requires AutoHotkey v2.0

; IsRealAltGrPress on a Kana layout with the alt_gr row Entry (0 for none).
_ACSD_Gate(Entry) {
	global TapHold
	Saved := { TapHold: TapHold, Family: _TestSetAltGrFamily(true) }
	try {
		TapHold := Map("keys", IsObject(Entry) ? Map("alt_gr", Entry) : Map(), "layers", Map())
		return IsRealAltGrPress()
	} finally {
		TapHold := Saved.TapHold
		_TestRestoreAltGrFamily(Saved.Family)
	}
}

_ACSD_Row(Hold := "", Layer := "") {
	Entry := Map("tap_action", "tab", "time_activation_seconds", 0.2)
	if (Hold != "")
		Entry["hold_modifier"] := Hold
	if (Layer != "")
		Entry["hold_layer"] := Layer
	return Entry
}

_ACSD_CombosFollowWhatAltGrHolds() {
	AssertTrue(_ACSD_Gate(0), "with no AltGr tap-hold the key is AltGr")
	AssertTrue(_ACSD_Gate(_ACSD_Row()), "a tap-only AltGr is AltGr while held")
	AssertTrue(_ACSD_Gate(_ACSD_Row("alt_gr")), "AltGr held as AltGr is AltGr")
	AssertTrue(_ACSD_Gate(_ACSD_Row("alt_gr+shift")), "a combination holding AltGr keeps the AltGr combinations")
	AssertFalse(_ACSD_Gate(_ACSD_Row("ctrl")), "AltGr held as Ctrl is Ctrl: AltGr+C must be Ctrl+C")
	AssertFalse(_ACSD_Gate(_ACSD_Row("", "nav")), "AltGr held as the navigation layer maps the layer's keys")
}
Test("altgr combos: they stand down while AltGr holds another modifier or a layer (kana-altgr-hold-other-2026-09-26)",
	_ACSD_CombosFollowWhatAltGrHolds)

; The Kana script chords that need no prefix (Enter, BackSpace, Delete, Escape
; under the physical SC138) follow the same rule, and the standard family's
; gate applies it before the physical check.
_ACSD_EveryAltGrGateAppliesIt() {
	Body := _DriverFuncBody("IsRealAltGrPress")
	Gate := InStr(Body, "AltGrKeyIsAltGr()")
	AssertTrue(Gate > 0 and Gate < InStr(Body, 'GetKeyState("RAlt", "P")'),
		"IsRealAltGrPress must stand down for a non-AltGr hold before its standard-layout physical check")
	Script := _DriverFuncBody("_RegisterScriptAltGrHotkeys")
	AssertTrue(InStr(Script, 'GetKeyState("SC138", "P") and AltGrKeyIsAltGr()') > 0,
		"the Kana suffix-only script chords must stand down with the combinations")
}
Test("altgr combos: every AltGr gate applies the rule (kana-altgr-hold-other-2026-09-26)",
	_ACSD_EveryAltGrGateAppliesIt)
