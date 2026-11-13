; tests/unit/keyboard/engine/key_combinations/test_native_press_ledger_consumers.ahk

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

; The owner starts for everyone: no AI gate stands before it, and a hook that cannot
; install or read leaves the keyboard working, on the catalogue order (item4).
_NPL_OwnerRunsForEveryoneAndFailsSoft() {
	; The only guard: a quarantined startup smoke never starts the native hook,
	; which ignores Suspend (3d65b7da79). No user setting stands before it.
	Assert(RegExMatch(_DriverSourceNoComments(), "m)^if !_DriverSmokeInputQuarantined\R\s*KeyboardArbiterEnsureForLedger\(\)$"),
		"the boot starts it at top level, under the smoke quarantine alone")
	AssertTrue(KeyboardArbiterEnsureForLedger(() => true))
	AssertFalse(KeyboardArbiterEnsureForLedger(() => false), "a refused start is reported, not raised")
	AssertFalse(KeyboardArbiterEnsureForLedger(_NPL_Raises), "a raising start is reported, not raised")
	Previous := KS_NativeKeyPressPort()
	KS_NativeKeyPressPort(_NPL_Raises)
	try {
		AssertEqual(0, KS_IsHeld("SC06E"), "a failing ledger: only the physical state answers")
		AssertEqual(0, KS_PressSequence("SC06E"), "and the order reads unknown")
		AssertEqual(-1 == KS_RealPressState("SC06E") ? 1 : 0, 1, "and the real flag reads unknown")
	} finally KS_NativeKeyPressPort(Previous)
	AssertEqual("caps_lock", _NPL_FirstOf(["caps_lock", "tab"], Map("caps_lock", 0, "tab", 0)),
		"no numbers: the catalogue decides")
}
_NPL_Raises(*) {
	throw Error("no hook")
}
Test("press ledger: the owner runs for everyone and a failure falls back to the catalogue (item4-always-on)",
	_NPL_OwnerRunsForEveryoneAndFailsSoft)

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

; A first key replayed after a terminal expansion reads as up physically: the pair
; must still see it held. Its own second key keeps the press reading, or a replayed
; press would read as its own auto-repeat and start no pair.
_NPL_ReplayedFirstKeyStartsThePair() {
	global _KeyCombinationFirstKeys, _KeyCombinationScanNames, _KeyCombinationTaken, _KeyCombinationHandled, _KeyCombinationPressAssignments
	global KeyCombinationTaps, KeyCombinationHolds, CategoryEnabled
	Saved := [_KeyCombinationFirstKeys, _KeyCombinationScanNames, _KeyCombinationTaken, _KeyCombinationHandled,
		_KeyCombinationPressAssignments, KeyCombinationTaps, KeyCombinationHolds, CategoryEnabled]
	_KeyCombinationFirstKeys := Map("space", ["tab"])
	_KeyCombinationScanNames := Map("tab", "SC06E", "space", "SC06F")
	_KeyCombinationTaken := Map(), _KeyCombinationHandled := Map(), _KeyCombinationPressAssignments := Map()
	KeyCombinationTaps := Map("tab_then_space", "copy"), KeyCombinationHolds := Map()
	CategoryEnabled := Map("KeyCombinations", true)
	try {
		AssertFalse(KeyCombinationOwns("space"), "no first key held: no pair")
		_NPL_WithLedger([0x06E], () => AssertTrue(KeyCombinationOwns("space"), "a replayed first key takes the pair"))
		_KeyCombinationTaken := Map()
		_NPL_WithLedger([0x06F, 0x06E], () => AssertTrue(KeyCombinationOwns("space"),
			"a replayed second key is a new press, not a repeat"))
	} finally {
		_KeyCombinationFirstKeys := Saved[1], _KeyCombinationScanNames := Saved[2], _KeyCombinationTaken := Saved[3]
		_KeyCombinationHandled := Saved[4], _KeyCombinationPressAssignments := Saved[5]
		KeyCombinationTaps := Saved[6], KeyCombinationHolds := Saved[7], CategoryEnabled := Saved[8]
	}
}
Test("press ledger: a replayed first key starts its pair (item5-first-key)", _NPL_ReplayedFirstKeyStartsThePair)

; The script chord's cleanup must not lift an AltGr or a suffix held through a replay.
_NPL_ScriptChordReadsTheHeldKeys() {
	Body := _DriverFuncBody("ResetScriptComboKeys")
	AssertTrue(InStr(Body, "KS_IsHeld(SuffixSC)") > 0, "a replayed suffix is not up")
	AssertFalse(InStr(Body, 'GetKeyState(SuffixSC, "P")') > 0, "the physical read alone misses a replayed press")
	AssertTrue(InStr(_DriverFuncBody("_ScriptComboClearAltGr"), "KS_IsHeld(Name)") > 0, "nor a replayed AltGr")
}
Test("press ledger: the script chord cleanup reads held keys (item5-script-chord)", _NPL_ScriptChordReadsTheHeldKeys)

; An ordinary press is exactly a KeyWait: its duration, and so every tap-hold, does
; not change. Only a press the ledger hides is watched there.
_NPL_WaitOrdinaryPressIsAKeyWait() {
	Asked := []
	Ports := Map("key_wait", (Options) => (Asked.Push(Options), true),
		"tick", () => (Assert(false, "an ordinary press reads no clock"), 0),
		"sleep", (*) => Assert(false, "an ordinary press polls nothing"))
	AssertTrue(KS_WaitReleased("SC06E", 0.2, Ports), "no owner")
	_NPL_WithLedger([], () => KS_WaitReleased("SC06E", 0.2, Ports))
	AssertEqual(2, Asked.Length)
	AssertEqual("T" . 0.2, Asked[1], "the same timeout goes to the same KeyWait")
	AssertEqual("T" . 0.2, Asked[2], "with an owner too")
}
Test("press ledger: an ordinary press waits with KeyWait, its duration unchanged (item5-keywait-ordinary)",
	_NPL_WaitOrdinaryPressIsAKeyWait)

; A release the ledger missed (Ctrl+Alt+Del, UAC): the wait is bounded, and the reset
; ends it at once. Either way the owner runs on, no press stays held for good.
_NPL_WaitMissedRelease() {
	global KS_NATIVE_KEY_HIDDEN
	Hidden := true, Now := 1000, Sleeps := 0
	Previous := KS_NativeKeyPressPort()
	KS_NativeKeyPressPort((Sc) => { flags: Hidden ? KS_NATIVE_KEY_HIDDEN : 0, sequence: 0 })
	try {
		Ports := Map("key_wait", (*) => Assert(false, "a hidden press is not AutoHotkey's to wait for"),
			"tick", () => Now, "sleep", (Ms) => (Now += Ms, Sleeps += 1))
		AssertFalse(KS_WaitReleased("SC06E", 0.2, Ports), "never released: the timeout ends the wait")
		AssertEqual(1200, Now, "and at its bound")
		Hidden := true, Now := 1000
		ResetPorts := Map("key_wait", (*) => Assert(false, "no KeyWait"), "tick", () => Now,
			"sleep", (Ms) => (Now += Ms, Hidden := Now < 1030))
		AssertTrue(KS_WaitReleased("SC06E", 5, ResetPorts), "the ledger's reset releases it")
		Assert(Now < 1100, "well before the five seconds")
	} finally KS_NativeKeyPressPort(Previous)
}
Test("press ledger: a missed release never stalls a wait (item5-keywait-missed)", _NPL_WaitMissedRelease)

; Every release wait of the driver goes through the one bounded owner.
_NPL_NoBareKeyWaitLeft() {
	Source := _DriverSourceNoComments()
	Count := 0, Pos := 1
	while (Pos := InStr(Source, "KeyWait(", true, Pos)) {
		Count += 1
		Pos += 1
	}
	AssertEqual(1, Count, "the whole driver must wait through KS_WaitReleased, the one native KeyWait")
	Assert(InStr(_DriverFuncBody("KS_WaitReleased"), "KeyWait("), "the one native KeyWait belongs to the bounded owner")
}
Test("press ledger: every release wait is bounded through KS_WaitReleased (item5-keywait-sites)", _NPL_NoBareKeyWaitLeft)

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

; #HotIf criteria read the ledger on the keystroke path. Resolving an export proves
; every issued address again, which made one read cost 48 GetKeyState calls.
_NPL_KeystrokeReadResolvesNoExport(*) {
	Source := _DriverFileSource("llm_nav_event_owner.ahk")
	Assert(InStr(Source, "KS_NativeKeyPressPort(LLM_NavEventOwner_KeyPress)") == 0,
		"the port must not resolve the export at every read")
	Assert(RegExMatch(Source, "KS_NativeKeyPressPort\(\(Sc\) => LLM_NavEventOwner_KeyPress\(Sc, \w+\)\)") > 0,
		"the port must carry the export resolved once at the owner's start")
}
Test("press ledger: a keystroke read resolves no export (ledger-read-cost-2026-11-01)",
	_NPL_KeystrokeReadResolvesNoExport)
