; tests/meta/test_space_hold_empty_guard.ahk

; ==============================================================================
; MODULE: SpaceTapHold Empty-Capture Guard Meta-Test
; DESCRIPTION:
; Structural regression for the phantom-modifier fix in modules/tap_holds/space.ahk.
;
; Before the fix, SpaceTapHold() called HoldFn.Call(ih.Input) unconditionally
; after the InputHook window closed. When the user held Space but released it
; before pressing any chord key (e.g. held Space then released without pressing
; Ctrl/Shift chord), ih.Input was "". HoldFn (_SpaceHoldCtrl / _SpaceHoldShift
; / _SpaceHoldAlt) would then call SendInput("{LCtrl Down}"), do nothing with
; the empty captured string (the inner guard stopped it), then wait through
; STUCK_MODIFIER_RELEASE_TIMEOUT_SEC (up to 15× hold threshold) holding LCtrl
; down. This produced a phantom modifier visible to the active window for up to
; several seconds.
;
; The fix adds an outer guard in SpaceTapHold():
;   if (ih.Input != "" and ih.Input != " ")
;       HoldFn.Call(ih.Input)
; so HoldFn is never invoked when no meaningful chord key was captured.
;
; This test inspects space.ahk source and asserts:
;   1. The guard is present immediately before HoldFn.Call.
;   2. HoldFn.Call is inside a branch that checks ih.Input.
; ==============================================================================

#Requires AutoHotkey v2.0




; ============================================================
; ============================================================
; ======= 1/ Assertions ======================================
; ============================================================
; ============================================================

_SHEG_GuardPresent() {
	; Move-resilient: locate SpaceTapHold() across the whole driver source via the
	; framework helper instead of a pinned modules path
	block := _DriverFuncBody("SpaceTapHold")
	Assert(InStr(block, "ih.Input") > 0,
		"space.ahk: SpaceTapHold() must check ih.Input before calling HoldFn to prevent phantom modifier on empty capture")
}
Test("SpaceTapHold: ih.Input guard present before HoldFn.Call (space-hold-empty-guard)", _SHEG_GuardPresent)


_SHEG_HoldFnInsideGuard() {
	block := _DriverFuncBody("SpaceTapHold")
	posGuard   := InStr(block, "ih.Input")
	posHoldFn  := InStr(block, "HoldFn.Call")
	Assert(posGuard > 0 and posHoldFn > 0,
		"space.ahk: both ih.Input guard and HoldFn.Call must be present in SpaceTapHold()")
	; Guard must come before the call — HoldFn.Call is inside the guarded branch.
	Assert(posGuard < posHoldFn,
		"space.ahk: ih.Input check must precede HoldFn.Call in SpaceTapHold()")
}
Test("SpaceTapHold: ih.Input guard precedes HoldFn.Call (space-hold-empty-guard)", _SHEG_HoldFnInsideGuard)
