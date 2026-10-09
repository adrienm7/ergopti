; tests/unit/test_tap_hold_owned_press.ahk

; ==============================================================================
; MODULE: A tap-hold owner claims its physical press until release
; DESCRIPTION:
; Tab, Space, Enter, Escape, Backspace and Delete fire their tap-hold only with
; no modifier held, so their hotkeys carry no * wildcard. The key's own
; auto-repeat then arrives while the owner holds its synthetic modifier (or its
; layer), matches no hotkey, and reached the application as that chord: Enter
; held as Ctrl typed Ctrl+Enter repeatedly (measured with AutoHotkey 2.0.26).
; Each key's repeat swallower is gated on TapHoldPressIsOwned, which the two
; owners must publish for exactly the lifetime of the press they resolve,
; exceptions included (owned-press-repeat-2026-09-25).
; ==============================================================================

#Requires AutoHotkey v2.0

global _THOP_SeenOwned := []

_THOP_Reset() {
	global _THOP_SeenOwned := []
	global _TH_OwnedPresses := Map()
}

_THOP_WaitRecordingOwnership(KeyId, KeyName, TimeoutSec) {
	global _THOP_SeenOwned
	_THOP_SeenOwned.Push(TapHoldPressIsOwned(KeyId))
	return true
}

_THOP_WaitThrows(KeyName, TimeoutSec) {
	throw Error("release seam failed")
}

_THOP_KeyIsDown(KeyName) => false
_THOP_Tick() => 1000
_THOP_Accept(Key) => true
_THOP_NoCancel(KeyId, GuardMs) => ""
_THOP_NotSuspended() => false
_THOP_LayerOn() => true
_THOP_LayerOff() => ""

_THOP_ModifierOwnerClaimsItsPress() {
	global _THOP_SeenOwned
	_THOP_Reset()
	AssertFalse(TapHoldPressIsOwned("enter"), "no press is owned before its owner runs")
	TapHoldOwnImmediateModifier("enter", "Enter", "LCtrl", 0.2,
		_THOP_WaitRecordingOwnership.Bind("enter"), _THOP_KeyIsDown, _THOP_Tick,
		_THOP_Accept, _THOP_Accept, _THOP_NoCancel, false, _THOP_NotSuspended)
	AssertEqual(1, _THOP_SeenOwned.Length, "the release wait must run once")
	AssertTrue(_THOP_SeenOwned[1],
		"the press must be owned while its owner waits for the release, or the key's auto-repeat reaches the application")
	AssertFalse(TapHoldPressIsOwned("enter"), "the claim must end with the press")
	AssertFalse(TapHoldPressIsOwned("space"), "the claim names only the owner's key")
}
Test("tap-hold owned press: the modifier owner claims its press until release (owned-press-repeat-2026-09-25)",
	_THOP_ModifierOwnerClaimsItsPress)

_THOP_LayerOwnerClaimsItsPress() {
	global _THOP_SeenOwned, LayerEnabled := false
	_THOP_Reset()
	TapHoldOwnImmediateLayer("delete", "Delete", 0.2,
		_THOP_WaitRecordingOwnership.Bind("delete"), _THOP_KeyIsDown, _THOP_Tick,
		_THOP_LayerOn, _THOP_LayerOff, _THOP_NotSuspended)
	AssertEqual(1, _THOP_SeenOwned.Length, "the release wait must run once")
	AssertTrue(_THOP_SeenOwned[1],
		"the press must be owned while the layer owner waits for the release")
	AssertFalse(TapHoldPressIsOwned("delete"), "the claim must end with the press")
}
Test("tap-hold owned press: the layer owner claims its press until release (owned-press-repeat-2026-09-25)",
	_THOP_LayerOwnerClaimsItsPress)

_THOP_ClaimsEndWhenTheOwnerThrows() {
	global LayerEnabled := false
	_THOP_Reset()
	AssertThrows(() => TapHoldOwnImmediateModifier("tab", "SC00F", "LAlt", 0.2,
		_THOP_WaitThrows, _THOP_KeyIsDown, _THOP_Tick,
		_THOP_Accept, _THOP_Accept, _THOP_NoCancel, false, _THOP_NotSuspended),
		"a release seam exception must propagate")
	AssertFalse(TapHoldPressIsOwned("tab"),
		"a modifier owner that throws must still end its claim, or the key's next native press is swallowed")
	AssertThrows(() => TapHoldOwnImmediateLayer("space", "SC039", 0.2,
		_THOP_WaitThrows, _THOP_KeyIsDown, _THOP_Tick,
		_THOP_LayerOn, _THOP_LayerOff, _THOP_NotSuspended),
		"a release seam exception must propagate")
	AssertFalse(TapHoldPressIsOwned("space"),
		"a layer owner that throws must still end its claim")
}
Test("tap-hold owned press: claims end even when the owner throws (owned-press-repeat-2026-09-25)",
	_THOP_ClaimsEndWhenTheOwnerThrows)

; A pass-through press (LShift held as LShift through ~) already reached the
; system, and so must its repeats and release: a swallowed repeat would make AHK
; suppress the physical release too and leave Shift down in the system
; (owned-press-repeat-all-2026-09-25).
_THOP_PassThroughPressIsNotClaimed() {
	global _THOP_SeenOwned
	_THOP_Reset()
	TapHoldOwnImmediateModifier("left_shift", "SC02A", "LShift", 0.2,
		_THOP_WaitRecordingOwnership.Bind("left_shift"), _THOP_KeyIsDown, _THOP_Tick,
		_THOP_Accept, _THOP_Accept, _THOP_NoCancel, true, _THOP_NotSuspended)
	AssertEqual(1, _THOP_SeenOwned.Length, "the release wait must run once")
	AssertFalse(_THOP_SeenOwned[1],
		"a pass-through press must never be claimed, or its repeat swallower strands the physical modifier down")
	AssertFalse(TapHoldPressIsOwned("left_shift"), "no claim may remain after the press")
}
Test("tap-hold owned press: a pass-through press is never claimed (owned-press-repeat-all-2026-09-25)",
	_THOP_PassThroughPressIsNotClaimed)

_THOP_RefusedModifierDoesNotLeaveAClaim() {
	_THOP_Reset()
	Result := TapHoldOwnImmediateModifier("backspace", "BackSpace", "LCtrl", 0.2,
		_THOP_WaitRecordingOwnership.Bind("backspace"), _THOP_KeyIsDown, _THOP_Tick,
		(Key) => false, _THOP_Accept, _THOP_NoCancel, false, _THOP_NotSuspended)
	AssertFalse(Result["activated"], "a refused Down must not activate the hold")
	AssertFalse(TapHoldPressIsOwned("backspace"), "a refused hold must not leave its press claimed")
}
Test("tap-hold owned press: a refused hold leaves no claim (owned-press-repeat-2026-09-25)",
	_THOP_RefusedModifierDoesNotLeaveAClaim)
