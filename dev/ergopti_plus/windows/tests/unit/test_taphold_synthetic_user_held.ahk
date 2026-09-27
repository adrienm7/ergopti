; tests/unit/test_taphold_synthetic_user_held.ahk

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

_TSUH_Begin(Logical, Physical) {
	global _AHK_SendInput, _TapHoldKeyIsDown, _TSUH_Sent, _TSUH_Logical, _TSUH_Physical
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys, _TH_SyntheticUserHeldKeys
	_TSUH_Sent := []
	_TSUH_Logical := Logical
	_TSUH_Physical := Physical
	_TH_SyntheticHeldKeys := Map()
	_TH_SyntheticReleasePendingKeys := Map()
	_TH_SyntheticUserHeldKeys := Map()
	_AHK_SendInput := (Keys) => _TSUH_Sent.Push(Keys)
	_TapHoldKeyIsDown := _TSUH_KeyIsDown
}

_TSUH_End() {
	global _AHK_SendInput, _TapHoldKeyIsDown
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys, _TH_SyntheticUserHeldKeys
	_AHK_SendInput := (Keys) => 0
	_TapHoldKeyIsDown := (Name, Mode) => (Mode == "") ? GetKeyState(Name) : GetKeyState(Name, Mode)
	_TH_SyntheticHeldKeys := Map()
	_TH_SyntheticReleasePendingKeys := Map()
	_TH_SyntheticUserHeldKeys := Map()
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
