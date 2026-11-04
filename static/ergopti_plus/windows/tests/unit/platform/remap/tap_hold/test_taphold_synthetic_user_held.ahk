; tests/unit/platform/remap/tap_hold/test_taphold_synthetic_user_held.ahk

; ==============================================================================
; MODULE: A synthetic hold never releases a modifier the user holds
; DESCRIPTION:
; Windows keeps one down bit per key. Holding LCtrl, then tapping CapsLock held
; as Ctrl, made the CapsLock owner press LCtrl again and release it at its last
; Up: LCtrl was logically up while the user still held it, and C then typed "c".
; CapsLock papered over its own tap with a CtrlActivated wrapper, which released
; LCtrl the same way. The owner now remembers, when it first presses a key,
; whether the user already held it down and delivered to the system; it leaves
; such a key down at its last release when the key is still physically held,
; since the user's own Up will release it. A press the driver suppressed (the
; RCtrl tap-hold holding its own RCtrl, the LAlt one-shot Shift) was never
; delivered, so its physical Up is swallowed and the synthetic Up must still be
; sent, or the modifier would stay down (synthetic-user-held-2026-09-25).
; ==============================================================================

#Requires AutoHotkey v2.0

global _TSUH_Sent := []
global _TSUH_Logical := Map()
global _TSUH_Physical := Map()
global _TSUH_OwnerState := 0

_TSUH_Begin(Logical, Physical) {
	global _AHK_SendInput, _TapHoldKeyIsDown, _TSUH_Sent, _TSUH_Logical, _TSUH_Physical, _TSUH_OwnerState
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys, _TH_SyntheticUserHeldKeys
	global _TH_OwnedModifiers, _TH_ModifierOwners, _TH_OwnedPresses, _TH_RetractedOwners, _TH_AltGrLCtrlOwners
	global _TH_AltGrPresses, _TH_TabAltOwner, _TH_LayerOwner, LayerEnabled, NumberOfRepetitions
	AssertFalse(IsObject(_TSUH_OwnerState), "A foreign synthetic-key fixture cannot be replaced")
	AssertEqual(0, _TH_SyntheticHeldKeys.Count + _TH_SyntheticReleasePendingKeys.Count,
		"A foreign native acquisition or release debt cannot be parked")
	AssertEqual(0, _TH_ModifierOwners.Count + _TH_OwnedPresses.Count + _TH_AltGrLCtrlOwners.Count,
		"A foreign live gesture cannot be parked across teardown")
	AssertFalse(IsObject(_TH_LayerOwner) || IsObject(_TH_TabAltOwner))
	_TSUH_OwnerState := {Send: _AHK_SendInput, KeyState: _TapHoldKeyIsDown,
		Held: _TH_SyntheticHeldKeys, Pending: _TH_SyntheticReleasePendingKeys, User: _TH_SyntheticUserHeldKeys,
		Names: _TH_OwnedModifiers, Owners: _TH_ModifierOwners, Presses: _TH_OwnedPresses,
		Retracted: _TH_RetractedOwners, AltCtrl: _TH_AltGrLCtrlOwners, AltPress: _TH_AltGrPresses,
		Tab: _TH_TabAltOwner, LayerOwner: _TH_LayerOwner, Layer: LayerEnabled, Repetitions: NumberOfRepetitions}
	_TSUH_Sent := [], _TSUH_Logical := Logical, _TSUH_Physical := Physical
	_TH_SyntheticHeldKeys := Map(), _TH_SyntheticReleasePendingKeys := Map(), _TH_SyntheticUserHeldKeys := Map()
	_TH_OwnedModifiers := Map(), _TH_ModifierOwners := Map(), _TH_OwnedPresses := Map(), _TH_RetractedOwners := Map()
	_TH_AltGrLCtrlOwners := Map(), _TH_AltGrPresses := Map(), _TH_TabAltOwner := 0, _TH_LayerOwner := 0
	LayerEnabled := false, NumberOfRepetitions := 1
	_AHK_SendInput := (Keys) => _TSUH_Sent.Push(Keys)
	_TapHoldKeyIsDown := _TSUH_KeyIsDown
}

_TSUH_End() {
	global _AHK_SendInput, _TapHoldKeyIsDown, _TSUH_OwnerState
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys, _TH_SyntheticUserHeldKeys
	global _TH_OwnedModifiers, _TH_ModifierOwners, _TH_OwnedPresses, _TH_RetractedOwners, _TH_AltGrLCtrlOwners
	global _TH_AltGrPresses, _TH_TabAltOwner, _TH_LayerOwner, LayerEnabled, NumberOfRepetitions
	Saved := _TSUH_OwnerState
	_AHK_SendInput := Saved.Send, _TapHoldKeyIsDown := Saved.KeyState
	_TH_SyntheticHeldKeys := Saved.Held, _TH_SyntheticReleasePendingKeys := Saved.Pending, _TH_SyntheticUserHeldKeys := Saved.User
	_TH_OwnedModifiers := Saved.Names, _TH_ModifierOwners := Saved.Owners, _TH_OwnedPresses := Saved.Presses
	_TH_RetractedOwners := Saved.Retracted, _TH_AltGrLCtrlOwners := Saved.AltCtrl, _TH_AltGrPresses := Saved.AltPress
	_TH_TabAltOwner := Saved.Tab, _TH_LayerOwner := Saved.LayerOwner
	LayerEnabled := Saved.Layer, NumberOfRepetitions := Saved.Repetitions
	; Epochs stay monotone. Preconditions above exclude any live foreign owner.
	_TSUH_OwnerState := 0
}

_TSUH_KeyIsDown(Name, Mode) {
	global _TSUH_Logical, _TSUH_Physical
	return (Mode == "P") ? _TSUH_Physical.Has(Name) : _TSUH_Logical.Has(Name)
}

_TSUH_Count(Payload) {
	global _TSUH_Sent
	N := 0
	for _, Sent in _TSUH_Sent {
		if (Sent == Payload)
			N++
	}
	return N
}

_TSUH_UserHeldCtrlSurvivesTheHold() {
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys
	_TSUH_Begin(Map("LCtrl", true), Map("LCtrl", true))
	try {
		AssertTrue(TapHoldSyntheticKeyDown("LCtrl"), "the hold must still be owned")
		AssertTrue(TapHoldSyntheticKeyUp("LCtrl"), "the release must succeed")
		AssertEqual(0, _TSUH_Count("{LCtrl Up}"),
			"LCtrl held by the user must stay down: releasing it made C type 'c' under the user's Ctrl")
		AssertEqual(0, _TH_SyntheticHeldKeys.Count, "the owner's count must end")
		AssertEqual(0, _TH_SyntheticReleasePendingKeys.Count, "nothing may stay release-pending")
	} finally _TSUH_End()
}
Test("taphold-synthetic: a modifier the user holds stays down after a synthetic hold (synthetic-user-held-2026-09-25)",
	_TSUH_UserHeldCtrlSurvivesTheHold)

_TSUH_SuppressedOwnKeyIsReleased() {
	; RCtrl held as its own RCtrl through the suppressing tap-hold: physically
	; down, never delivered, so logically up until the synthetic Down.
	_TSUH_Begin(Map(), Map("RCtrl", true))
	try {
		TapHoldSyntheticKeyDown("RCtrl")
		TapHoldSyntheticKeyUp("RCtrl")
		AssertEqual(1, _TSUH_Count("{RCtrl Up}"),
			"a suppressed press's physical Up is swallowed: skipping the synthetic Up would leave RCtrl stuck down")
	} finally _TSUH_End()
}
Test("taphold-synthetic: a suppressed own press is still released (synthetic-user-held-2026-09-25)",
	_TSUH_SuppressedOwnKeyIsReleased)

_TSUH_UserReleasedBeforeTheHoldEnds() {
	global _TSUH_Physical
	_TSUH_Begin(Map("LCtrl", true), Map("LCtrl", true))
	try {
		TapHoldSyntheticKeyDown("LCtrl")
		_TSUH_Physical := Map()
		TapHoldSyntheticKeyUp("LCtrl")
		AssertEqual(1, _TSUH_Count("{LCtrl Up}"),
			"once the user has let go, the last owner must release the key")
	} finally _TSUH_End()
}
Test("taphold-synthetic: a key the user let go is released by the last owner (synthetic-user-held-2026-09-25)",
	_TSUH_UserReleasedBeforeTheHoldEnds)

_TSUH_LifecycleCleanupLeavesTheUsersKey() {
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys
	_TSUH_Begin(Map("LCtrl", true), Map("LCtrl", true, "LShift", true))
	try {
		TapHoldSyntheticKeyDown(["LCtrl", "LShift"])
		AssertTrue(TapHoldReleaseSyntheticKeys(), "the cleanup must succeed")
		AssertEqual(0, _TSUH_Count("{LCtrl Up}"), "the cleanup must not release the key the user holds")
		AssertEqual(1, _TSUH_Count("{LShift Up}"),
			"LShift was not delivered before the hold, so the cleanup must release it")
		AssertEqual(0, _TH_SyntheticHeldKeys.Count + _TH_SyntheticReleasePendingKeys.Count,
			"the cleanup must leave no owner behind")
	} finally _TSUH_End()
}
Test("taphold-synthetic: lifecycle cleanup leaves a key the user holds (synthetic-user-held-2026-09-25)",
	_TSUH_LifecycleCleanupLeavesTheUsersKey)

_TSUH_CapsLockHasNoCtrlWrapper() {
	Body := _DriverFuncBody("_CapsLockInvokeTap")
	Assert(Body != "", "_CapsLockInvokeTap must exist")
	Assert(!InStr(Body, "TapHoldSyntheticKeyDown") and !InStr(Body, "CtrlActivated"),
		"the CapsLock tap must not wrap itself in a synthetic LCtrl: the owner now keeps a held LCtrl down")
}
Test("taphold-synthetic: the CapsLock tap no longer wraps itself in Ctrl (synthetic-user-held-2026-09-25)",
	_TSUH_CapsLockHasNoCtrlWrapper)


_TSUH_RetiredOwnerPreservesSuccessor() {
	global _TH_SyntheticHeldKeys
	_TSUH_Begin(Map(), Map())
	WasSuspended := A_IsSuspended
	Ticks := 0
	Now() {
		Ticks += 1
		return Ticks == 1 ? 1000 : 1100
	}
	WaitRelease(*) {
		Suspend(true)
		try AssertTrue(TapHoldReleaseSyntheticKeys(), "The genuine teardown must acknowledge A's release")
		finally Suspend(false)
		AssertTrue(TapHoldSyntheticKeyDown("LCtrl"), "A fresh post-resume acquisition B must reach the actual ledger")
		AssertEqual(1, _TH_SyntheticHeldKeys["LCtrl"])
		return true
	}
	try {
		Suspend(false)
		Result := TapHoldOwnImmediateModifier("caps_lock", "CapsLock", "LCtrl", 0.2,
			WaitRelease, (*) => false, Now, 0, 0, (*) => "")
		AssertTrue(_TH_SyntheticHeldKeys.Has("LCtrl"), "Unwinding retired A must preserve the current B ownership")
		AssertEqual(1, _TH_SyntheticHeldKeys["LCtrl"], "An old release must not consume B's reference")
		AssertEqual(1, _TSUH_Count("{LCtrl Up}"), "Only the actual teardown may have emitted an Up before B ends")
		AssertFalse(Result["tap"], "A revoked gesture must not become a tap after resume")
		AssertTrue(TapHoldSyntheticKeyUp("LCtrl"))
		AssertEqual(2, _TSUH_Count("{LCtrl Up}"), "B must retain its own independently balanced final release")
	} finally {
		if _TH_SyntheticHeldKeys.Has("LCtrl")
			TapHoldSyntheticKeyUp("LCtrl")
		Suspend(WasSuspended)
		_TSUH_End()
	}
}
Test("taphold-synthetic: a retired modifier owner preserves a post-resume acquisition (synthetic-owner-epoch)",
	_TSUH_RetiredOwnerPreservesSuccessor)

_TSUH_OwnerReleaseIsOnce() {
	global _TH_SyntheticHeldKeys
	_TSUH_Begin(Map(), Map())
	try {
		A := TapHoldNewOwner(), B := TapHoldNewOwner()
		AssertTrue(TapHoldSyntheticKeyDown("LCtrl", A))
		AssertTrue(TapHoldSyntheticKeyDown("LCtrl", B))
		AssertEqual(2, _TH_SyntheticHeldKeys["LCtrl"])
		AssertTrue(TapHoldSyntheticKeyUp("LCtrl", A))
		AssertTrue(TapHoldSyntheticKeyUp("LCtrl", A), "A repeated release must retain its acknowledged verdict")
		AssertEqual(1, _TH_SyntheticHeldKeys["LCtrl"], "The same gesture cannot consume B's reference on a second terminal path")
		AssertEqual(0, _TSUH_Count("{LCtrl Up}"))
		AssertFalse(TapHoldSyntheticKeyDown("LCtrl", A), "A completed owner cannot acquire again")
		AssertTrue(TapHoldSyntheticKeyUp("LCtrl", B))
		AssertTrue(TapHoldSyntheticKeyUp("LCtrl", A))
		AssertEqual(1, _TSUH_Count("{LCtrl Up}"), "Only B's final balancing release may reach the sender")
		AssertEqual(0, _TH_SyntheticHeldKeys.Count)
	} finally _TSUH_End()
}
Test("taphold-synthetic: repeated owner release preserves its receipt and peer reference (synthetic-owner-once)", _TSUH_OwnerReleaseIsOnce)

_TSUH_RevokedBeforeDown() {
	global _TH_SyntheticHeldKeys
	_TSUH_Begin(Map(), Map())
	WasSuspended := A_IsSuspended, Waits := 0
	Now() {
		Suspend(true)
		try AssertTrue(TapHoldReleaseSyntheticKeys())
		finally Suspend(false)
		AssertTrue(TapHoldSyntheticKeyDown("LCtrl"))
		return 1000
	}
	Wait(*) {
		Waits += 1
		return true
	}
	try {
		Suspend(false)
		Result := TapHoldOwnImmediateModifier("caps_lock", "CapsLock", "LCtrl", 0.2,
			Wait, (*) => false, Now, 0, 0, (*) => "")
		AssertFalse(Result["activated"])
		AssertFalse(Result["tap"])
		AssertEqual(0, Waits, "A producer revoked before Down must not start its release wait")
		AssertEqual(1, _TH_SyntheticHeldKeys["LCtrl"], "Only the fresh B acquisition may remain")
		AssertEqual(1, _TSUH_Count("{LCtrl Down}"))
		AssertEqual(0, _TSUH_Count("{LCtrl Up}"), "The old frame must not release the fresh key on early refusal")
		AssertFalse(TapHoldPressIsOwned("caps_lock"))
		AssertTrue(TapHoldSyntheticKeyUp("LCtrl"))
	} finally {
		Suspend(WasSuspended)
		_TSUH_End()
	}
}
Test("taphold-synthetic: teardown before the first Down rejects the old producer (synthetic-owner-before-down)", _TSUH_RevokedBeforeDown)

_TSUH_RetiredOwnerLeavesNewPhysicalKey() {
	global _TSUH_Logical, _TSUH_Physical
	_TSUH_Begin(Map(), Map())
	WasSuspended := A_IsSuspended, Clock := 900
	Wait(*) {
		Suspend(true)
		try AssertTrue(TapHoldReleaseSyntheticKeys())
		finally Suspend(false)
		; This is an explicit key-state observation port, not injected desktop input.
		_TSUH_Logical["LCtrl"] := true, _TSUH_Physical["LCtrl"] := true
		return true
	}
	try {
		Suspend(false)
		Result := TapHoldOwnImmediateModifier("caps_lock", "CapsLock", "LCtrl", 0.2,
			Wait, (*) => false, (*) => (Clock += 100), 0, 0, (*) => "")
		AssertFalse(Result["tap"])
		AssertEqual(1, _TSUH_Count("{LCtrl Up}"),
			"Only teardown may release A; an untracked old Up must never lift the newly delivered physical key")
		AssertTrue(_TSUH_Logical.Has("LCtrl") && _TSUH_Physical.Has("LCtrl"))
	} finally {
		Suspend(WasSuspended)
		_TSUH_End()
	}
}
Test("taphold-synthetic: a revoked frame cannot release a new physical key observation (synthetic-owner-physical)", _TSUH_RetiredOwnerLeavesNewPhysicalKey)

_TSUH_OwnerFailureRetainsDebt() {
	global _AHK_SendInput, _TSUH_Sent, _TH_SyntheticReleasePendingKeys, _TH_SyntheticHeldKeys
	_TSUH_Begin(Map(), Map())
	FailUp(Keys) {
		_TSUH_Sent.Push(Keys)
		if InStr(Keys, " Up}")
			throw Error("Controlled owner release refusal")
	}
	try {
		A := TapHoldNewOwner(), B := TapHoldNewOwner()
		AssertTrue(TapHoldSyntheticKeyDown("LCtrl", A))
		_AHK_SendInput := FailUp
		AssertFalse(TapHoldSyntheticKeyUp("LCtrl", A))
		AssertTrue(_TH_SyntheticReleasePendingKeys.Has("LCtrl"), "A consumed reference must transfer its unproved native Up to the actual debt ledger")
		_AHK_SendInput := (Keys) => _TSUH_Sent.Push(Keys)
		AssertTrue(TapHoldSyntheticKeyDown("LCtrl", B), "B must repair the native debt before acquiring the key")
		AssertFalse(_TH_SyntheticReleasePendingKeys.Has("LCtrl"))
		Before := _TSUH_Count("{LCtrl Up}")
		AssertFalse(TapHoldSyntheticKeyUp("LCtrl", A), "A repeated refused receipt must not fabricate success or consume B")
		AssertEqual(Before, _TSUH_Count("{LCtrl Up}"))
		AssertEqual(1, _TH_SyntheticHeldKeys["LCtrl"])
		AssertTrue(TapHoldSyntheticKeyUp("LCtrl", B))
		AssertEqual(Before + 1, _TSUH_Count("{LCtrl Up}"))
	} finally _TSUH_End()
}
Test("taphold-synthetic: consumed owner release retains native debt without consuming its successor (synthetic-owner-debt)", _TSUH_OwnerFailureRetainsDebt)

_TSUH_TabFallbackAndFinallyShareReceipt() {
	global _TH_TabAltOwner, _TH_SyntheticHeldKeys
	_TSUH_Begin(Map(), Map())
	Saved := _TH_TabAltOwner
	try {
		A := TapHoldNewOwner(), B := TapHoldNewOwner()
		_TH_TabAltOwner := A
		AssertTrue(TapHoldSyntheticKeyDown("LAlt", A))
		AssertTrue(TapHoldSyntheticKeyDown("LAlt", B))
		AssertTrue(_TapHoldReleaseTabAltOwner(), "The actual static Up fallback must acknowledge A")
		AssertTrue(_TapHoldReleaseOwnedModifier("LAlt", A), "The waiting frame must read the same acknowledged receipt")
		AssertEqual(1, _TH_SyntheticHeldKeys["LAlt"])
		AssertEqual(0, _TSUH_Count("{LAlt Up}"), "The two terminal paths must leave B's Alt held")
		AssertTrue(_TapHoldReleaseOwnedModifier("LAlt", B))
		AssertEqual(1, _TSUH_Count("{LAlt Up}"))
	} finally {
		_TH_TabAltOwner := Saved
		_TSUH_End()
	}
}
Test("taphold-synthetic: Tab Up and its waiting frame share one acknowledged release (synthetic-owner-tab)", _TSUH_TabFallbackAndFinallyShareReceipt)
