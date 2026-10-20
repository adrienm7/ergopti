; tests/unit/platform/remap/key_combinations/test_ctrl_alt_numpad_gate.ahk

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
	Body := _LT_NativeAltGrRegistrationBody()
	At := RegExMatch(Body, 'm)^[ `t]*HotkeyFn\.Call\("\^!" \. SC,', &Registration)
	AssertTrue(At > 0, "the Ctrl+Alt Numpad hotkeys must still be registered")
	Assert(_LT_NativeDelegateIsCode(Body, Registration, "HotkeyFn.Call("), "the Ctrl+Alt registration must be executable native-default code")
	GatePos := 0
	CriteriaSeen := 0
	Scan := 1
	while (Found := RegExMatch(Body, "m)^[ `t]*HotIfFn\.Call\(.*$", &Criterion, Scan)) and Found < At {
		CriteriaSeen += 1
		Assert(_LT_NativeDelegateIsCode(Body, Criterion, "HotIfFn.Call("), "the governing criterion must be executable native-default code")
		GatePos := Found
		Scan := Found + Max(1, Criterion.Len)
	}
	Assert(CriteriaSeen > 0, "the native criterion scan must find the actual governing registration criteria")
	Assert(GatePos > 0, "the Ctrl+Alt registration must retain a preceding native criterion")
	Gate := SubStr(Body, GatePos, InStr(Body, "`n", , GatePos) - GatePos)
	AssertTrue(InStr(Gate, "IsCtrlAltNotAltGr()") > 0, "the Ctrl+Alt Numpad hotkeys must be gated on a real Ctrl+Alt chord")
	AssertFalse(InStr(Gate, "RealAltGrFn.Call()") > 0, "the admitted physical AltGr delegate cannot gate a real Ctrl+Alt chord")
	AssertFalse(InStr(Gate, "IsRealAltGrPress()") > 0,
		"the AltGr gate needs the physical AltGr, which a Ctrl+Alt chord never holds")
}
Test("ctrl-alt numpad: registered under their own gate, not the AltGr layer's (ctrl-alt-numpad-gate-2026-09-26)",
	_CANG_RegisteredUnderTheirOwnGate)


; Capture the genuine producer and run only admitted Ctrl+Alt callbacks through
; the sender's recording hook. No host hotkey or keyboard output is created.
_CANG_RegisteredRowPolicy(Family, Emulated) {
	global Features, ALTGR_PLUS_OVERRIDES, ALTGR_NUMBER_ROW, ALTGR_BASE_ROWS, CTRL_ALT_NUMPAD
	global _OB_ALTGR_PASSTHROUGH, _SendHook, _Stub_RecordedSends
	_TestEnsureErgoptiLayout()
	Saved := [Features, ALTGR_PLUS_OVERRIDES, ALTGR_NUMBER_ROW, ALTGR_BASE_ROWS, CTRL_ALT_NUMPAD,
		_OB_ALTGR_PASSTHROUGH, _SendHook, _Stub_RecordedSends]
	PreviousFamily := _TestSetAltGrFamily(Family == "kana", Family == "altgr")
	Criterion := 0, Registrations := [], Chords := Map()
	SetCriterion(Fn := unset) {
		Criterion := IsSet(Fn) ? Fn : 0
	}
	Capture(Name, Callback, Options) {
		Registration := { Name: Name, Callback: Callback, Criterion: Criterion, Options: Options }
		Registrations.Push(Registration)
		if SubStr(Name, 1, 2) == "^!"
			Chords[Name] := Registration
	}
	try {
		Features := Map("layout", Map("ergopti_base", false, "ergopti_alt_gr", true,
			"ergopti_variant", "none", "emulated_layout", "", "emulate_number_row", Emulated,
			"emulate_top_row", false, "emulate_home_row", false, "emulate_bottom_row", false))
		_OB_ALTGR_PASSTHROUGH := false
		AssertFalse(GetKeyState(KS_AltGrKeyName(), "P"), "this passive Ctrl+Alt fixture requires the physical AltGr key up")
		_SendHook := _HOOK_RecordSend
		_Stub_RecordedSends := []
		RegisterAltGrLayer(Capture, SetCriterion, (*) => 0, (*) => false)
		AssertEqual(0, Criterion, "the actual producer must release its registration context")
		AssertEqual(ALTGR_PLUS_OVERRIDES.Count + ALTGR_NUMBER_ROW.Count + ALTGR_BASE_ROWS.Count + CTRL_ALT_NUMPAD.Count,
			Registrations.Length, "all four original cohorts must be registered")
		AssertEqual(10, Chords.Count, "every actual Ctrl+Alt digit must be captured")
		for Index in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10] {
			Name := Format("^!SC{:03X}", Index + 1)
			Registration := Chords[Name]
			AssertEqual("I2", Registration.Options)
			Admitted := Registration.Criterion.Call(Name)
			AssertEqual(Emulated, Admitted, "a native number row must retain " . Name . " on " . Family)
			if Admitted
				Registration.Callback.Call(Name)
			Features["layout"]["emulate_number_row"] := !Emulated
			AssertEqual(!Emulated, Registration.Criterion.Call(Name), "the existing criterion must follow a row toggle")
			Features["layout"]["emulate_number_row"] := true
			Features["layout"]["ergopti_alt_gr"] := false
			AssertFalse(Registration.Criterion.Call(Name), "a row switch cannot enable a disabled AltGr feature")
			Features["layout"]["ergopti_alt_gr"] := true
			_OB_ALTGR_PASSTHROUGH := true
			AssertFalse(Registration.Criterion.Call(Name), "onboarding must keep the chord native")
			_OB_ALTGR_PASSTHROUGH := false
			Features["layout"]["emulate_number_row"] := Emulated
		}
		AssertEqual(Emulated ? 10 : 0, _Stub_RecordedSends.Length, "only admitted callbacks may reach the sender")
		for Index, Emission in _Stub_RecordedSends {
			AssertEqual("SendFinalResult", Emission.fn, "the actual Ctrl+Alt dispatcher must retain its final sender")
			AssertEqual("^!{Numpad" . Mod(Index, 10) . "}", Emission.args[1], "the real callback must retain the exact digit")
		}
	} finally {
		Features := Saved[1], ALTGR_PLUS_OVERRIDES := Saved[2], ALTGR_NUMBER_ROW := Saved[3]
		ALTGR_BASE_ROWS := Saved[4], CTRL_ALT_NUMPAD := Saved[5], _OB_ALTGR_PASSTHROUGH := Saved[6]
		_SendHook := Saved[7], _Stub_RecordedSends := Saved[8]
		_TestRestoreAltGrFamily(PreviousFamily)
	}
}

for _CANG_Family in ["plain", "altgr", "kana"]
	for _CANG_Emulated in [false, true]
		Test("ctrl-alt numpad: " . _CANG_Family . " number row " . (_CANG_Emulated ? "emulated" : "native")
			. " preserves its registered owner (ctrl-alt-numpad-row-scope)", _CANG_RegisteredRowPolicy.Bind(_CANG_Family, _CANG_Emulated))
