; tests/unit/test_ctrl_alt_numpad_gate.ahk

; ==============================================================================
; MODULE: Ctrl+Alt+digit reaches the Ctrl+Alt+Numpad shortcuts
; DESCRIPTION:
; The CTRL_ALT_NUMPAD table exists for a real Ctrl+Alt chord ("Ctrl + Alt
; different from AltGr": Google Docs headings on Ctrl+Alt+Numpad N), but its
; "^!SCxxx" hotkeys were registered under the AltGr layer's gate,
; IsRealAltGrPress, which off Kana needs the physical AltGr. A LCtrl+LAlt chord
; never holds it, so on AZERTY LCtrl+LAlt+é went to Windows as AltGr+é and
; typed the ~ dead key; the shortcuts only worked on a Kana layout
; (ctrl-alt-numpad-gate-2026-09-26). They now need the opposite: the AltGr key
; up. The physical AltGr cannot be pressed from a test, so the gate is read
; with it up, which is when a Ctrl+Alt chord runs.
; ==============================================================================

#Requires AutoHotkey v2.0

_CANG_GateHoldsForACtrlAltChord() {
	global _OB_ALTGR_PASSTHROUGH
	for _, Kana in [false, true] {
		Family := _TestSetAltGrFamily(Kana)
		try {
			AssertTrue(IsCtrlAltNotAltGr(),
				(Kana ? "Kana" : "standard or QWERTY") . " layout: a Ctrl+Alt chord with the AltGr key up is a real Ctrl+Alt")
			Saved := _OB_ALTGR_PASSTHROUGH
			_OB_ALTGR_PASSTHROUGH := true
			try AssertFalse(IsCtrlAltNotAltGr(), "the first-run wizard keeps every AltGr-looking chord native")
			finally _OB_ALTGR_PASSTHROUGH := Saved
		} finally _TestRestoreAltGrFamily(Family)
	}
}
Test("ctrl-alt numpad: the gate admits a real Ctrl+Alt chord on every layout (ctrl-alt-numpad-gate-2026-09-26)",
	_CANG_GateHoldsForACtrlAltChord)

_CANG_RegisteredUnderTheirOwnGate() {
	Body := _DriverFuncBody("RegisterAltGrLayer")
	At := InStr(Body, 'Hotkey("^!" . SC')
	AssertTrue(At > 0, "the Ctrl+Alt Numpad hotkeys must still be registered")
	GatePos := 0
	Scan := 1
	while (Found := InStr(Body, "HotIf(", , Scan)) and Found < At {
		GatePos := Found
		Scan := Found + 1
	}
	Gate := SubStr(Body, GatePos, InStr(Body, "`n", , GatePos) - GatePos)
	AssertTrue(InStr(Gate, "IsCtrlAltNotAltGr()") > 0, "the Ctrl+Alt Numpad hotkeys must be gated on a real Ctrl+Alt chord")
	AssertFalse(InStr(Gate, "IsRealAltGrPress()") > 0,
		"the AltGr gate needs the physical AltGr, which a Ctrl+Alt chord never holds")
}
Test("ctrl-alt numpad: registered under their own gate, not the AltGr layer's (ctrl-alt-numpad-gate-2026-09-26)",
	_CANG_RegisteredUnderTheirOwnGate)
