; tests/unit/test_altgr_layer_shift_from_hold.ahk

; ==============================================================================
; MODULE: The AltGr layer's Shifted output under a hold's Shift
; DESCRIPTION:
; The AltGr layer chose its Shifted entry from the physical Shift only. The
; AltGr key held as Shift+AltGr presses that Shift synthetically, so AltGr+E
; typed the Plain entry (the % wrap under ergopti_plus) where a physical
; Shift+AltGr typed the Shifted one (altgr-hold-shift-2026-09-26). The same
; read sat in the two rolls registered apart from AltGrShiftDispatch and in the
; AltGr+LAlt shortcut. A Shift a tap-hold holds is the user's Shift. The cases leave the key state and the synthetic ledger as each
; family's owner of a shift+alt_gr hold does, then run the layer's output.
; ==============================================================================

#Requires AutoHotkey v2.0

global _ALSH_Sent := []
global _ALSH_Physical := Map()

; The keyboard as the case sets it: only the keys in _ALSH_Physical are down,
; physically; the logical state follows the synthetic ledger.
_ALSH_KeyIsDown(Name, Mode) {
	global _ALSH_Physical, _TH_SyntheticHeldKeys
	if (Mode == "P")
		return _ALSH_Physical.Has(Name)
	return _TH_SyntheticHeldKeys.Has(Name)
}

_ALSH_Plain() {
	global _ALSH_Sent
	_ALSH_Sent.Push("plain")
	return true
}

_ALSH_Shifted() {
	global _ALSH_Sent
	_ALSH_Sent.Push("shifted")
	return true
}

; Run one AltGr-layer output on layout Family ("standard", "qwerty" or
; "kana") with the ledger Held (key name -> count) and the physical keys
; Physical, and return what went out, joined.
_ALSH_Output(Family, Held, Physical) {
	global _AHK_SendInput, _TapHoldKeyIsDown, _ALSH_Sent, _ALSH_Physical
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys, _TH_SyntheticUserHeldKeys
	Saved := {
		SendInput: _AHK_SendInput, KeyIsDown: _TapHoldKeyIsDown,
		Family: _TestSetAltGrFamily(Family == "kana", Family == "standard"),
		Held: _TH_SyntheticHeldKeys, Pending: _TH_SyntheticReleasePendingKeys,
		UserHeld: _TH_SyntheticUserHeldKeys
	}
	_ALSH_Sent := []
	_ALSH_Physical := Map()
	for _, Name in Physical
		_ALSH_Physical[Name] := true
	_TH_SyntheticHeldKeys := Map()
	for Name, Count in Held
		_TH_SyntheticHeldKeys[Name == "AltGr" ? KS_AltGrKeyName() : Name] := Count
	_TH_SyntheticReleasePendingKeys := Map()
	_TH_SyntheticUserHeldKeys := Map()
	_TapHoldKeyIsDown := _ALSH_KeyIsDown
	_AHK_SendInput := (Keys) => _ALSH_Sent.Push(Keys)
	try {
		Entry := { Plain: _ALSH_Plain, Shifted: _ALSH_Shifted }
		AltGrLayerEmit(AltGrLayerEntryCallable(Entry))
	} finally {
		_AHK_SendInput := Saved.SendInput
		_TapHoldKeyIsDown := Saved.KeyIsDown
		_TestRestoreAltGrFamily(Saved.Family)
		_TH_SyntheticHeldKeys := Saved.Held
		_TH_SyntheticReleasePendingKeys := Saved.Pending
		_TH_SyntheticUserHeldKeys := Saved.UserHeld
	}
	Out := ""
	for _, Keys in _ALSH_Sent
		Out .= (Out == "" ? "" : "|") . Keys
	return Out
}

; What an output leaves on the wire on Family around Sends: a suppressing
; owner (QWERTY, Kana) holds the AltGr key synthetically, and it is lifted
; around the output; the standard family's pass-through AltGr is the user's.
_ALSH_Around(Family, Sends) {
	if (Family == "kana")
		return "{Blind}{vkDF Up}|" . Sends . "|{Blind}{vkDF Down}"
	if (Family == "qwerty")
		return "{Blind}{" . A_MenuMaskKey . "}|{RAlt Up}|" . Sends . "|{RAlt Down}"
	return Sends
}

; The ledger each family's owner leaves for the alt_gr hold Hold: the standard
; family passes the AltGr key through and presses the rest; QWERTY and Kana
; suppress it and press the whole combination.
_ALSH_OwnerLedger(Family, Hold) {
	Held := Map()
	if (Hold == "shift+alt_gr")
		Held["LShift"] := 1
	if (Family != "standard")
		Held["AltGr"] := 1
	return Held
}

_ALSH_ShiftFromTheHoldPicksShifted() {
	for _, Family in ["standard", "qwerty", "kana"] {
		AssertEqual(_ALSH_Around(Family, "shifted"), _ALSH_Output(Family, _ALSH_OwnerLedger(Family, "shift+alt_gr"), ["SC138"]),
			Family . ": AltGr held as Shift+AltGr must type the Shifted entry, as a physical Shift+AltGr does")
		AssertEqual(_ALSH_Around(Family, "plain"), _ALSH_Output(Family, _ALSH_OwnerLedger(Family, "alt_gr"), ["SC138"]),
			Family . ": AltGr held as AltGr alone types the Plain entry")
		AssertEqual(_ALSH_Around(Family, "shifted"), _ALSH_Output(Family, _ALSH_OwnerLedger(Family, "alt_gr"), ["SC138", "Shift"]),
			Family . ": a physical Shift still picks the Shifted entry")
	}
	AssertEqual("shifted", _ALSH_Output("standard", Map("RShift", 1), ["SC138"]),
		"a Shift another tap-hold holds (right_shift, space) is the user's Shift too")
}
Test("altgr layer: a Shift held by the AltGr hold picks the Shifted entry on every family (altgr-hold-shift-2026-09-26)",
	_ALSH_ShiftFromTheHoldPicksShifted)

; Every AltGr-layer output that picks by Shift reads it through the same rule:
; the table dispatcher and the two rolls it does not dispatch.
_ALSH_EveryAltGrShiftReadUsesTheRule() {
	Dispatch := _DriverFuncBody("AltGrShiftDispatch")
	Assert(Dispatch != "", "AltGrShiftDispatch must be found")
	AssertTrue(InStr(Dispatch, "Cb := AltGrLayerEntryCallable(Entry)") > 0,
		"AltGrShiftDispatch must pick its entry through AltGrLayerEntryCallable")
	for _, Name in ["AltGrLayerEntryCallable", "_RollChevronEqualEmit", "_RollHashtagQuoteEmit"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . " must be found")
		AssertTrue(InStr(Body, "AltGrLayerShiftHeld()") > 0, Name . " must read Shift through AltGrLayerShiftHeld")
		AssertFalse(InStr(Body, 'GetKeyState("Shift", "P")') > 0,
			Name . " must not read the physical Shift alone: a hold's Shift is synthetic")
	}
}
Test("altgr layer: every AltGr Shift read counts a hold's Shift (altgr-hold-shift-2026-09-26)",
	_ALSH_EveryAltGrShiftReadUsesTheRule)
