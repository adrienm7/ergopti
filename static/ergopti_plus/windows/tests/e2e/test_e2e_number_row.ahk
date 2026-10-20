; static/ergopti_plus/windows/tests/e2e/test_e2e_number_row.ahk

; ==============================================================================
; MODULE: E2E Number Row (headless)
; DESCRIPTION:
; « Chiffres en accès direct » end to end on the keyboard layouts of the
; machine: the stored choice, the real layout's levels (MapVirtualKeyEx and
; ToUnicodeEx on a real HKL), the criteria the number-row hotkeys of
; modules/keymap/layout.ahk declare, and the real handlers they run, whose
; sends the harness records (_SendHook) instead of typing them. A press no
; hotkey takes is typed by the layout itself: the harness reads that level from
; the same real layout. Layout switches move the foreground layout the
; handlers read (NumberRowForegroundLayout's seam) between real layouts, both
; ways. A tester reported the digit row dead under « digits first » on 1.0.3
; (number-row-e2e).
;
; On the CI runner French AZERTY and US QWERTY are loaded without being
; activated; elsewhere only the installed layouts are read. No key is sent and
; no hotkey registered.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================
; ==========================
; ======= 1/ Harness =======
; ==========================
; ==========================

; The handlers ask whether a typed character reached the screen; no suppressing
; input hook runs in this harness, so every recorded send did.
_EmitReachedScreen() => true

; HKL of the layout with KLID Klid: loaded on the CI runner, looked up among
; the installed ones elsewhere (0 when absent).
_E2ENR_Layout(Klid) {
	if (EnvGet("GITHUB_ACTIONS") = "true") {
		; KLF_NOTELLSHELL (0x80): load for the probe, activate nothing.
		Hkl := DllCall("LoadKeyboardLayoutW", "Str", Klid, "UInt", 0x80, "Ptr")
		Assert(Hkl != 0, "the CI runner must be able to load keyboard layout " . Klid)
		return Hkl
	}
	Wanted := Integer("0x" . Klid)
	for _, Hkl in KS_InstalledKeyboardLayouts() {
		if ((Hkl & 0xFFFFFFFF) == ((Wanted << 16) | Wanted))
			return Hkl
	}
	return 0
}

; Publishes Layout as the [layout] section, the layout category on; no registry
; layout is emulated here, so nothing supersedes a built-in feature.
_E2ENR_UseLayout(Layout) {
	global Features, CategoryEnabled, LayerEnabled
	Features["layout"] := Layout
	CategoryEnabled := Map("Layout", true)
	LayerEnabled := false
	; No master gate: its desired view is then the Features read here.
	MasterGateState()["initialized"] := false
}

; The [layout] section of a fresh configuration with Changes applied.
_E2ENR_Settings(Changes) {
	Layout := Map()
	for Key in ["emulated_layout", "ergopti_base", "ergopti_alt_gr", "ergopti_variant", "direct_access_digits",
			"number_row_reorder_edges", "emulate_number_row", "emulate_top_row", "emulate_home_row", "emulate_bottom_row"]
		Layout[Key] := ManifestDefaultFor("layout." . Key)
	for Key, Value in Changes
		Layout[Key] := Value
	return Layout
}

; What the layout Hkl itself types on key Sc (the press no hotkey takes).
_E2ENR_Native(Hkl, Sc, Shift) {
	Level := KS_LayoutKeyLevels(Hkl, [Sc])[Sc]
	return "native:" . Level[Shift ? "shift" : "plain"]
}

; One press of number-row key Sc on the foreground layout, resolved the way AHK
; resolves the variants layout.ahk declares (their criteria are exclusive):
; the handler a hotkey runs, with its sends recorded, or the layout's own level.
; @returns {String} "native:<char>", or the recorded sends joined by "|".
_E2ENR_Press(Sc, Shift) {
	global _Stub_RecordedSends
	ResetHotstringRecorders()
	Hkl := NumberRowForegroundLayout()
	Digit := Sc >= 0x02 && Sc <= 0x0B
	Ran := false
	if Digit && !Shift && NumberRowEffectiveMode() == "digits" && !TapHoldKanaAltGrHeld() {
		_DigitRowDown(Mod(Sc - 1, 10) . "")
		_DigitRowUp(Mod(Sc - 1, 10) . "")
		Ran := true
	} else if Digit && NumberRowEffectiveMode() == "symbols" && !NumberRowRegistryOwnsRow() && !TapHoldKanaAltGrHeld() {
		_NumberRowSymbolsFirstSend(Sc, Shift)
		Ran := true
	} else if Digit && Shift && _DigitRowSwapIsLive(Sc, NumberRowForegroundLayout) {
		_DigitRowSwapSend(Sc, NumberRowForegroundLayout)
		Ran := true
	} else if !Digit && NumberRowEdgesEffective() && !TapHoldKanaAltGrHeld() {
		_NumberRowEdgeSend(Sc, Shift)
		Ran := true
	}
	; The handlers take Critical("On"), which is thread-scoped in a hotkey thread
	; and would outlive this direct call: the test thread gives it back.
	Critical("Off")
	if !Ran
		return _E2ENR_Native(Hkl, Sc, Shift)
	Out := ""
	for Entry in _Stub_RecordedSends
		Out .= (A_Index > 1 ? "|" : "") . Entry.args[1]
	return Out
}

; The resolver above evaluates the criteria the hotkeys of the keymap module
; declare; this pins them to that module's own #HotIf lines, so a criterion
; changed there without the harness fails here (number-row-e2e).
_E2ENR_CriteriaMatchTheHotkeys() {
	global _DriverDir
	Source := FileRead(_DriverProductionFileForSymbol("RemapKey", _DriverDir), "UTF-8")
	for Criterion in ['NumberRowEffectiveMode() == "digits" && !TapHoldKanaAltGrHeld()',
			'NumberRowEffectiveMode() == "symbols" && !NumberRowRegistryOwnsRow() && !TapHoldKanaAltGrHeld()',
			'NumberRowEdgesEffective() && !TapHoldKanaAltGrHeld()']
		AssertTrue(InStr(Source, "`n#HotIf " . Criterion . "`n") > 0, "the keymap module declares #HotIf " . Criterion)
	AssertTrue(InStr(Source, "HotIf(_DigitRowSwapIsLive.Bind(") > 0, "the Shift swap is decided by _DigitRowSwapIsLive")
}
Test("e2e[number-row] the replayed criteria are the hotkeys' own (number-row-e2e)", _E2ENR_CriteriaMatchTheHotkeys)

; Runs Fn(Azerty, Qwerty) with the driver state it changes restored after, or
; skips when this machine has neither layout.
_E2ENR_With(Fn) {
	global Features, CategoryEnabled, LayerEnabled, _NumberRowForegroundLayout, _DigitRowProfiles
	global _NumberRowAvailabilityCache, _NumberRowEffectiveLogged, _NumberRowEdgesLogged
	Azerty := _E2ENR_Layout("0000040C")
	Qwerty := _E2ENR_Layout("00000409")
	if !Azerty || !Qwerty {
		_TestPrint("# skip: French AZERTY and US QWERTY are not both installed on this machine")
		return
	}
	State := MasterGateState()
	Saved := [Features.Has("layout") ? Features["layout"] : 0, CategoryEnabled, LayerEnabled, State.Clone(),
		_NumberRowForegroundLayout, _DigitRowProfiles, _NumberRowAvailabilityCache, _NumberRowEffectiveLogged,
		_NumberRowEdgesLogged]
	try {
		_DigitRowProfiles := Map()
		_NumberRowAvailabilityCache := Map()
		Fn.Call(Azerty, Qwerty)
	} finally {
		if Saved[1] is Map
			Features["layout"] := Saved[1]
		CategoryEnabled := Saved[2]
		LayerEnabled := Saved[3]
		State.Clear()
		for Key, Value in Saved[4]
			State[Key] := Value
		_NumberRowForegroundLayout := Saved[5]
		_DigitRowProfiles := Saved[6]
		_NumberRowAvailabilityCache := Saved[7]
		_NumberRowEffectiveLogged := Saved[8]
		_NumberRowEdgesLogged := Saved[9]
	}
}





; ============================
; ============================
; ======= 2/ Scenarios =======
; ============================
; ============================

; « Digits first » on AZERTY types the digit unshifted (a key down and up, as
; the OTP boxes need) and AZERTY's symbol with Shift; on US QWERTY it is inert
; and the layout types its own row; back on AZERTY it applies again, with no
; reload and the stored choice untouched.
_E2ENR_DigitsFirstAcrossLayoutSwitches(Azerty, Qwerty) {
	global _NumberRowForegroundLayout
	_E2ENR_UseLayout(_E2ENR_Settings(Map("direct_access_digits", "digits")))
	for Hkl in [Azerty, Qwerty, Azerty, Qwerty, Azerty] {
		_NumberRowForegroundLayout := Hkl
		Where := Format("layout 0x{:X}", Hkl & 0xFFFFFFFF)
		Loop 10 {
			Sc := A_Index + 1, Digit := Mod(A_Index, 10) . ""
			if Hkl == Azerty {
				AssertEqual("{" . Digit . " Down}|{" . Digit . " Up}", _E2ENR_Press(Sc, false), Where . ": the digit unshifted")
				Symbol := KS_LayoutKeyLevels(Azerty, [Sc])[Sc]["plain"]
				AssertEqual("{Text}" . Symbol, _E2ENR_Press(Sc, true), Where . ": AZERTY's own symbol with Shift")
			} else {
				AssertEqual("native:" . Digit, _E2ENR_Press(Sc, false), Where . ": QWERTY types its digit itself")
				AssertEqual(_E2ENR_Native(Qwerty, Sc, true), _E2ENR_Press(Sc, true), Where . ": and its own Shift symbol")
			}
		}
		for Sc in [0x29, 0x0C, 0x0D]
			AssertEqual(_E2ENR_Native(Hkl, Sc, false), _E2ENR_Press(Sc, false), Where . ": the edge keys keep the layout's level")
	}
	AssertEqual("digits", MasterGateDesiredFeatures(Features)["layout"]["direct_access_digits"], "the stored choice is kept")
}
Test("e2e[number-row] digits first follows real AZERTY and QWERTY switches both ways (number-row-e2e)",
	_E2ENR_With.Bind(_E2ENR_DigitsFirstAcrossLayoutSwitches))

; A fresh configuration leaves the row to the layout: nothing is reordered.
_E2ENR_NativeByDefault(Azerty, Qwerty) {
	global _NumberRowForegroundLayout
	_E2ENR_UseLayout(_E2ENR_Settings(Map()))
	for Hkl in [Azerty, Qwerty] {
		_NumberRowForegroundLayout := Hkl
		for Sc in [0x29, 0x02, 0x06, 0x0B, 0x0C, 0x0D]
			for Shift in [false, true]
				AssertEqual(_E2ENR_Native(Hkl, Sc, Shift), _E2ENR_Press(Sc, Shift),
					Format("layout 0x{:X} SC{:03X} shift={}: the layout's own level", Hkl & 0xFFFFFFFF, Sc, Shift))
	}
}
Test("e2e[number-row] a fresh configuration reorders nothing (number-row-e2e)", _E2ENR_With.Bind(_E2ENR_NativeByDefault))

; « Symbols first » on US QWERTY types the Shift symbol unshifted and the digit
; with Shift, the edge keys too when asked; AZERTY already types its symbols
; first, so there it is inert.
_E2ENR_SymbolsFirstAndEdges(Azerty, Qwerty) {
	global _NumberRowForegroundLayout
	_E2ENR_UseLayout(_E2ENR_Settings(Map("direct_access_digits", "symbols", "number_row_reorder_edges", true)))
	for Hkl in [Qwerty, Azerty, Qwerty] {
		_NumberRowForegroundLayout := Hkl
		Where := Format("layout 0x{:X}", Hkl & 0xFFFFFFFF)
		Loop 10 {
			Sc := A_Index + 1
			if Hkl == Qwerty {
				AssertEqual("{Text}" . KS_LayoutKeyLevels(Qwerty, [Sc])[Sc]["shift"], _E2ENR_Press(Sc, false), Where . ": the symbol unshifted")
				AssertEqual("{Text}" . Mod(A_Index, 10), _E2ENR_Press(Sc, true), Where . ": the digit with Shift")
			} else
				AssertEqual(_E2ENR_Native(Azerty, Sc, false), _E2ENR_Press(Sc, false), Where . ": AZERTY keeps its row")
		}
		for Sc in [0x29, 0x0C, 0x0D] {
			Levels := KS_LayoutKeyLevels(Hkl, [Sc])[Sc]
			if Hkl == Qwerty {
				AssertEqual("{Text}" . Levels["shift"], _E2ENR_Press(Sc, false), Where . ": an edge key's Shift level unshifted")
				AssertEqual("{Text}" . Levels["plain"], _E2ENR_Press(Sc, true), Where . ": and its base level with Shift")
			} else
				AssertEqual(_E2ENR_Native(Azerty, Sc, false), _E2ENR_Press(Sc, false), Where . ": no ordering, the edges stay")
		}
	}
}
Test("e2e[number-row] symbols first and the edge keys follow real layout switches (number-row-e2e)",
	_E2ENR_With.Bind(_E2ENR_SymbolsFirstAndEdges))

; The built-in Ergopti emulation types its own row (its digits on both levels),
; so « digits first » is inert under it, and Shift+1 is never AZERTY's « & »
; (digit-row-builtin-ergopti-shift); with the number row switched off the
; emulation leaves it to AZERTY, which « digits first » reorders again.
_E2ENR_BuiltinErgoptiAndRowSwitch(Azerty, Qwerty) {
	global _NumberRowForegroundLayout
	_TestEnsureErgoptiLayout()
	_NumberRowForegroundLayout := Azerty
	Settings := _E2ENR_Settings(Map("direct_access_digits", "digits", "ergopti_base", true, "ergopti_variant", "ergopti"))
	_E2ENR_UseLayout(Settings)
	Loop 10 {
		Sc := A_Index + 1, Digit := Mod(A_Index, 10) . ""
		AssertEqual("native", NumberRowEffectiveMode(), "the built-in row cannot be reordered")
		AssertFalse(_DigitRowSwapIsLive(Sc, NumberRowForegroundLayout), "Shift+" . Digit . " is the built-in Shift level")
		AssertEqual(Digit, NumberRowEmulatedBase(Format("SC{:03X}", Sc)), "the built-in row types " . Digit . " unshifted")
		AssertEqual(Digit, _DigitRowEffectiveKey(Sc, Azerty, false)["shift"]["Text"], "and " . Digit . " with Shift")
	}
	Settings["emulate_number_row"] := false
	_E2ENR_UseLayout(Settings)
	AssertEqual("digits", NumberRowEffectiveMode(), "its number row switched off, AZERTY's row is reordered")
	AssertEqual("{1 Down}|{1 Up}", _E2ENR_Press(0x02, false))
	AssertEqual("{Text}" . KS_LayoutKeyLevels(Azerty, [0x02])[0x02]["plain"], _E2ENR_Press(0x02, true))
}
Test("e2e[number-row] the built-in Ergopti row and its row switch on real AZERTY (number-row-e2e)",
	_E2ENR_With.Bind(_E2ENR_BuiltinErgoptiAndRowSwitch))

; Under a held Kana AltGr, a key AutoHotkey does not count as a modifier, no
; number-row hotkey may replace the layout's AltGr level.
_E2ENR_KanaAltGrStandsDown(Azerty, Qwerty) {
	global _NumberRowForegroundLayout, _ALTGR_KANA_FIXUP, _TapHoldModifierIsHeld
	Saved := [IsSet(_ALTGR_KANA_FIXUP) ? _ALTGR_KANA_FIXUP : 0, IsSet(_TapHoldModifierIsHeld) ? _TapHoldModifierIsHeld : 0]
	try {
		_ALTGR_KANA_FIXUP := true
		_TapHoldModifierIsHeld := (*) => true
		_NumberRowForegroundLayout := Azerty
		_E2ENR_UseLayout(_E2ENR_Settings(Map("direct_access_digits", "digits")))
		AssertEqual(_E2ENR_Native(Azerty, 0x02, false), _E2ENR_Press(0x02, false), "digits first stands down")
		AssertEqual(_E2ENR_Native(Azerty, 0x02, true), _E2ENR_Press(0x02, true), "and its Shift level")
		_NumberRowForegroundLayout := Qwerty
		_E2ENR_UseLayout(_E2ENR_Settings(Map("direct_access_digits", "symbols", "number_row_reorder_edges", true)))
		AssertEqual(_E2ENR_Native(Qwerty, 0x02, false), _E2ENR_Press(0x02, false), "symbols first stands down")
		AssertEqual(_E2ENR_Native(Qwerty, 0x29, false), _E2ENR_Press(0x29, false), "the edge keys stand down")
	} finally {
		_ALTGR_KANA_FIXUP := Saved[1]
		_TapHoldModifierIsHeld := Saved[2]
	}
}
Test("e2e[number-row] a held Kana AltGr keeps the layout's AltGr level (number-row-e2e)",
	_E2ENR_With.Bind(_E2ENR_KanaAltGrStandsDown))

; Every layout installed on this machine (the maintainer's Kana layouts here):
; « digits first » types the digit exactly where it can reorder the row, and the
; layout's own digit elsewhere is never replaced by a symbol.
_E2ENR_EveryInstalledLayout(Azerty, Qwerty) {
	global _NumberRowForegroundLayout
	_E2ENR_UseLayout(_E2ENR_Settings(Map("direct_access_digits", "digits")))
	Checked := 0
	for _, Hkl in KS_InstalledKeyboardLayouts() {
		_NumberRowForegroundLayout := Hkl
		Where := Format("installed layout 0x{:X}", Hkl & 0xFFFFFFFF)
		Applies := NumberRowAvailability(Hkl, false)["digits"] == ""
		AssertEqual(Applies ? "{1 Down}|{1 Up}" : _E2ENR_Native(Hkl, 0x02, false), _E2ENR_Press(0x02, false),
			Where . ": the 1 key unshifted")
		if !Applies
			AssertEqual(_E2ENR_Native(Hkl, 0x02, true), _E2ENR_Press(0x02, true), Where . ": Shift+1 is the layout's own")
		Checked += 1
	}
	AssertTrue(Checked >= 1, "at least the session's own layout must be replayed")
}
Test("e2e[number-row] digits first on every installed layout (number-row-e2e)",
	_E2ENR_With.Bind(_E2ENR_EveryInstalledLayout))
