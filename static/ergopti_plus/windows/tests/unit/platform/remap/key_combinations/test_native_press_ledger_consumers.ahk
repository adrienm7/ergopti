; tests/unit/platform/remap/key_combinations/test_native_press_ledger_consumers.ahk

; ==============================================================================
; MODULE: What the driver makes of the native press ledger
; DESCRIPTION:
; A terminal replay reaches AutoHotkey injected, so its physical state answers
; "not down" for a key the user holds: AltGr then typed the plain key, Shift the
; unshifted layer, and a rolled key read as released. And "held alone, then
; joined" had no order at all: the catalogue decided. These tests give
; KS_IsHeld and the first-key choice a modeled ledger through the real port, on
; both AltGr families. The real DLL and hook are in test_native_abi.ahk and
; tools/test/test-windows-native-hook-front.cjs.
; ==============================================================================

#Requires AutoHotkey v2.0

; Runs Body with a modeled ledger in the real port: Hidden lists the scan codes
; it holds out of AutoHotkey's sight. The port stays empty afterwards.
_NPL_WithLedger(Hidden, Body) {
	global KS_NATIVE_KEY_HIDDEN
	Query := (Sc) => { flags: _NPL_Has(Hidden, Sc) ? KS_NATIVE_KEY_HIDDEN : 0x01, sequence: 0 }
	Previous := KS_NativeKeyPressPort()
	KS_NativeKeyPressPort(Query)
	try Body.Call()
	finally KS_NativeKeyPressPort(Previous)
}

_NPL_Has(List, Sc) {
	for _, Item in List {
		if Item == Sc
			return true
	}
	return false
}

_NPL_HeldReadsTheHiddenPressOnly() {
	AssertEqual(0, KS_IsHeld("SC06E"), "no owner: only the physical state answers")
	_NPL_WithLedger([GetKeySC("SC06E")], () => (
		AssertEqual(1, KS_IsHeld("SC06E"), "a press the owner hid is held"),
		AssertEqual(0, KS_IsDown("SC06E"), "the port contract stays physical only")
	))
	; Merely down in the ledger is what AutoHotkey reads itself: it adds nothing.
	_NPL_WithLedger([], () => AssertEqual(0, KS_IsHeld("SC06E"),
		"a key the ledger does not hide follows AutoHotkey's physical state"))
}
Test("press ledger: KS_IsHeld adds only the press AutoHotkey cannot see (todo91-ledger-held)",
	_NPL_HeldReadsTheHiddenPressOnly)

_NPL_ShiftIsEitherShift() {
	AssertEqual(0, KS_ShiftIsHeld(), "no owner and no key: no Shift")
	for _, Sc in [0x02A, 0x036]
		_NPL_WithLedger([Sc], _NPL_ExpectShiftHeld)
}
_NPL_ExpectShiftHeld() {
	AssertEqual(1, KS_ShiftIsHeld(), "a replayed Shift is held for the layer read")
}
Test("press ledger: a replayed Shift of either side is held (todo91-ledger-shift)",
	_NPL_ShiftIsEitherShift)

; The driver's own gate, read through its production default on both families:
; the standard AltGr (LCtrl+RAlt) asks about RAlt, the Kana one about SC138, and
; both names are the scan code the owner replays.
_NPL_AltGrGateAcceptsTheReplayedPress() {
	global TapHold, _ALTGR_PHYSICAL_STATE_QUERY
	AssertTrue(_ALTGR_PHYSICAL_STATE_QUERY == KS_IsHeld,
		"the gate must read the held state, not the physical one alone")
	Saved := TapHold
	TapHold := Map("keys", Map(), "layers", Map())
	try {
		for _, Kana in [false, true] {
			Family := _TestSetAltGrFamily(Kana)
			try {
				AssertFalse(IsRealAltGrPress(), "the key up is no AltGr")
				_NPL_WithLedger([0x138], _NPL_ExpectAltGr.Bind(true))
				_NPL_WithLedger([0x02A], _NPL_ExpectAltGr.Bind(false))
			} finally _TestRestoreAltGrFamily(Family)
		}
	} finally TapHold := Saved
}
_NPL_ExpectAltGr(Expected) {
	AssertEqual(Expected, IsRealAltGrPress() ? true : false,
		"a replayed AltGr press stays AltGr, another replayed key arms nothing")
}
Test("press ledger: AltGr stays AltGr through a replay on both families (todo91-ledger-altgr)",
	_NPL_AltGrGateAcceptsTheReplayedPress)

_NPL_RollReadsTheHiddenPress() {
	AssertFalse(_TapHoldRollScIsDown(0x06E), "no owner: a key up reads up")
	_NPL_WithLedger([0x06E], () => AssertTrue(_TapHoldRollScIsDown(0x06E),
		"a replayed rolled key is not a key let go"))
}
Test("press ledger: the roll decision does not read a replayed key as released (todo91-ledger-roll)",
	_NPL_RollReadsTheHiddenPress)

; Runs the choice over two first keys of one Second, in a known catalogue order.
_NPL_FirstOf(Catalogue, Sequences) {
	global _KeyCombinationFirstKeys
	Saved := _KeyCombinationFirstKeys
	_KeyCombinationFirstKeys := Map("space", Catalogue)
	try return KeyCombinationHeldFirstKey("space", (*) => true, (KeyId) => Sequences[KeyId])
	finally _KeyCombinationFirstKeys := Saved
}

_NPL_FirstKeyFollowsThePresses() {
	AssertEqual("tab", _NPL_FirstOf(["caps_lock", "tab"], Map("caps_lock", 9, "tab", 4)),
		"held alone then joined: the key pressed first, not the first of the catalogue")
	AssertEqual("caps_lock", _NPL_FirstOf(["caps_lock", "tab"], Map("caps_lock", 4, "tab", 9)),
		"the same when the catalogue agrees")
	AssertEqual("caps_lock", _NPL_FirstOf(["caps_lock", "tab"], Map("caps_lock", 9, "tab", 0)),
		"a press the ledger did not number leaves the order unknown: the catalogue decides")
	AssertEqual("caps_lock", _NPL_FirstOf(["caps_lock", "tab"], Map("caps_lock", 0, "tab", 4)),
		"the same whichever key lacks its number")
	AssertEqual("tab", _NPL_FirstOf(["tab"], Map("tab", 0)),
		"one key held needs no number")
}
Test("press ledger: the first key is the one pressed first (todo91-first-key-order)",
	_NPL_FirstKeyFollowsThePresses)

; The AltGr guard runs before the order: the fake LCtrl of a standard AltGr
; press must never become the pair's first key, whatever its number says.
_NPL_FakeLCtrlIsNeverTheFirstKey() {
	global _KeyCombinationFirstKeys
	Saved := _KeyCombinationFirstKeys
	Family := _TestSetAltGrFamily(false)
	_KeyCombinationFirstKeys := Map("alt_gr", ["left_ctrl"])
	try {
		if KS_AltGrAddsFakeLCtrl()
			AssertEqual("", KeyCombinationHeldFirstKey("alt_gr", (*) => true, (*) => 1),
				"on a standard AltGr layout LCtrl is AltGr's own")
	} finally {
		_KeyCombinationFirstKeys := Saved
		_TestRestoreAltGrFamily(Family)
	}
}
Test("press ledger: the fake LCtrl stays out of the first-key choice (todo91-first-key-altgr)",
	_NPL_FakeLCtrlIsNeverTheFirstKey)
