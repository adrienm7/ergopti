; tests/meta/test_tap_hold_suspend_boundary.ahk

; ==============================================================================
; MODULE: Tap-Hold Suspend Boundary Meta Tests
; DESCRIPTION:
; Prevents an in-flight KeyWait from activating a synthetic modifier or the
; navigation layer after native Suspend. Suspend unregisters future hotkeys but
; does not cancel the pseudo-thread already waiting on a physical key.
; ==============================================================================

#Requires AutoHotkey v2.0

_THSB_HoldModifierGateChecksSuspendBeforeInjection() {
	Body := _DriverFuncBody("TapHoldShouldSuppressHold")
	Assert(Body != "", "TapHoldShouldSuppressHold must remain the common hold-modifier gate")
	SuspendPos := InStr(Body, "if A_IsSuspended")
	SuccessPos := InStr(Body, "if (CancelReason != " . Chr(34) . Chr(34) . ")")
	Assert(SuspendPos > 0,
		"TapHoldShouldSuppressHold must reject candidates when Suspend occurs during KeyWait")
	Assert(SuccessPos > SuspendPos,
		"the suspend veto must run before the normal hold activation path can report success")
}
Test("tap-holds: in-flight hold-modifier candidates are cancelled by Suspend (tap-hold-suspend-boundary)",
	_THSB_HoldModifierGateChecksSuspendBeforeInjection)

_THSB_HoldLayerGateChecksSuspendBeforeMutation() {
	Body := _DriverFuncBody("ActivateLayer")
	Assert(Body != "", "ActivateLayer must remain the common hold-layer activation boundary")
	SuspendPos := InStr(Body, "if A_IsSuspended")
	WritePos := InStr(Body, "global LayerEnabled := True")
	Assert(SuspendPos > 0,
		"ActivateLayer must reject stale hold candidates after Suspend")
	Assert(WritePos > SuspendPos,
		"ActivateLayer must check A_IsSuspended before setting LayerEnabled true")
	Assert(InStr(Body, "return false") > SuspendPos,
		"ActivateLayer must return without mutating state when the driver is suspended")
}
Test("tap-holds: in-flight hold-layer candidates cannot activate after Suspend (tap-hold-suspend-boundary)",
	_THSB_HoldLayerGateChecksSuspendBeforeMutation)

_THSB_PreArmedSyntheticKeysAreSuspendOwned() {
	Src := _DriverDirConcat("modules/tap_holds")
	Lifecycle := _DriverFuncBody("Ergopti_OnSuspendEnter")
	Assert(InStr(Lifecycle, "TapHoldReleaseSyntheticKeys()") > 0,
		"Ergopti_OnSuspendEnter must immediately release synthetic tap-hold keys that were armed before an in-flight KeyWait")

	; A direct TextPressKey(..., "Down") in a tap-hold module cannot be
	; released by the suspend transition. The ownership helper is deliberately
	; the sole producer of that raw output; its own implementation lives in
	; constants.ahk and is excluded from this sibling scan.
	SplitPath(A_ScriptDir, , &Root)
	Q := Chr(34)
	Loop Files, Root . "\\modules\\tap_holds\\*.ahk", "FR" {
		if (A_LoopFileName = "constants.ahk")
			continue
		FileSrc := FileRead(A_LoopFileFullPath)
		Assert(!RegExMatch(FileSrc, "TextPressKey\\([^`r`n]+,\\s*" . Q . "Down" . Q . "\\)"),
			A_LoopFileName . " must acquire synthetic keys through TapHoldSyntheticKeyDown so Suspend can release an in-flight candidate immediately")
	}
	Assert(InStr(Src, "TapHoldSyntheticKeyDown") > 0 and InStr(Src, "TapHoldSyntheticKeyUp") > 0,
		"tap-hold modules must use the synthetic-key ownership pair around every cross-KeyWait modifier")
}
Test("tap-holds: every pre-armed synthetic key is released by the suspend owner (tap-hold-suspend-boundary)",
	_THSB_PreArmedSyntheticKeysAreSuspendOwned)
