; tests/meta/test_oneshotshift_lalt_lshift_stuck.ahk

; ==============================================================================
; MODULE: One-Shot-Shift Stuck-LShift Guard Meta Test
; DESCRIPTION:
; Static source guard for the oneshotshift-lalt-lshift-stuck finding.
;
; The one_shot_shift tap on LAlt (lalt.ahk 4.1) and on RCtrl (rctrl.ahk 7.3)
; arms LShift Down, then waits on KeyWait for the PHYSICAL tap-hold key to be
; released, then sends LShift Up. The original code did this with an UNBOUNDED
; KeyWait and no try/finally: if the key-up event was lost (focus stolen by a
; UAC prompt, the global Suspend hotkey toggled mid-press) the LShift Up was
; skipped and Shift latched Down forever.
;
; The fix wraps the arm/release pair in try { KeyWait } finally { LShift Up }
; so the release ALWAYS runs, and caps the wait with a "U T<timeout>" form
; (STUCK_MODIFIER_RELEASE_TIMEOUT_SEC) so a lost key-up cannot block forever.
;
; This is a meta-static test (scans source text) because lalt.ahk / rctrl.ahk
; register top-level #HotIf hotkeys and cannot be #Included by the headless
; runner without arming real hotkeys / blocking clean exit. If the finally
; guard or the bounded wait regresses, this test fails.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Extracts the body of a single hotkey/function block: from the declaration to
; the first closing brace at column 0 (AHK top-level blocks close with `}`
; flush-left while inner blocks close indented). Returns "" when absent.
_OSLLS_Block(Src, Decl) {
	Idx := InStr(Src, Decl)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	End := InStr(Rest, "`n}")
	if End
		return SubStr(Rest, 1, End + 1)
	return Rest
}

; Asserts that, within Body, the LShift Up release sits AFTER a finally keyword
; (i.e. inside the finally block, not before it). Order check is a cheap proxy
; for "release is in finally" that does not need a real brace parser.
_OSLLS_AssertReleaseInFinally(Body, Where) {
	; Build the release call literal without a hard-coded glyph so the ASCII-only
	; rule holds; Chr(34) is the double-quote.
	Q := Chr(34)
	ReleaseCall := "TapHoldSyntheticKeyUp(" . Q . "LShift" . Q . ")"
	FinallyIdx := InStr(Body, "finally")
	ReleaseIdx := InStr(Body, ReleaseCall)
	Assert(FinallyIdx > 0, Where . " must wrap the LShift arm/release in a finally block so the Up can never be skipped (oneshotshift-lalt-lshift-stuck)")
	Assert(ReleaseIdx > 0, Where . " must still release LShift via the suspend-owned synthetic-key release helper " . ReleaseCall)
	Assert(ReleaseIdx > FinallyIdx, Where . " must place the LShift Up release INSIDE the finally block so a lost key-up or exception cannot leave Shift stuck Down")
}


; ==================================================
; ==================================================
; ======= 2/ LAlt 4.1 guard assertions =============
; ==================================================
; ==================================================

_OSLLS_LAltOneShotShiftGuarded() {
	; Move-resilient: scan the tap_holds module dir via the framework helper
	; instead of a pinned lalt.ahk path. The left_alt one_shot_shift #HotIf
	; declaration is unique to lalt.ahk, so the extracted block is unambiguous.
	Src := _DriverDirConcat("modules/tap_holds")
	Body := _OSLLS_Block(Src, "#HotIf TapHoldTapAction(TapHold, " . Chr(34) . "left_alt" . Chr(34) . ") == " . Chr(34) . "one_shot_shift" . Chr(34))
	Assert(Body != "", "lalt.ahk one_shot_shift #HotIf block must exist")
	_OSLLS_AssertReleaseInFinally(Body, "lalt.ahk one_shot_shift tap")
	Assert(InStr(Body, "STUCK_MODIFIER_RELEASE_TIMEOUT_SEC") > 0,
		"lalt.ahk one_shot_shift KeyWait must be capped by STUCK_MODIFIER_RELEASE_TIMEOUT_SEC so a lost key-up cannot block the LShift release forever")
}
Test("tap-holds: LAlt one_shot_shift releases LShift in a bounded finally (oneshotshift-lalt-lshift-stuck)", _OSLLS_LAltOneShotShiftGuarded)


; ==================================================
; ==================================================
; ======= 3/ RCtrl 7.3 guard assertions ============
; ==================================================
; ==================================================

_OSLLS_RCtrlOneShotShiftGuarded() {
	; Move-resilient: scan the tap_holds module dir via the framework helper
	; instead of a pinned rctrl.ahk path. The right_ctrl one_shot_shift #HotIf
	; declaration is unique to rctrl.ahk, so the extracted block is unambiguous.
	Src := _DriverDirConcat("modules/tap_holds")
	Body := _OSLLS_Block(Src, "#HotIf TapHoldTapAction(TapHold, " . Chr(34) . "right_ctrl" . Chr(34) . ") == " . Chr(34) . "one_shot_shift" . Chr(34))
	Assert(Body != "", "rctrl.ahk one_shot_shift #HotIf block must exist")
	_OSLLS_AssertReleaseInFinally(Body, "rctrl.ahk one_shot_shift tap")
	Assert(InStr(Body, "STUCK_MODIFIER_RELEASE_TIMEOUT_SEC") > 0,
		"rctrl.ahk one_shot_shift KeyWait must be capped by STUCK_MODIFIER_RELEASE_TIMEOUT_SEC so a lost key-up cannot block the LShift release forever")
}
Test("tap-holds: RCtrl one_shot_shift releases LShift in a bounded finally (oneshotshift-lalt-lshift-stuck)", _OSLLS_RCtrlOneShotShiftGuarded)


; ==================================================
; ==================================================
; ======= 4/ Constant source-of-truth =============
; ==================================================
; ==================================================

_OSLLS_TimeoutConstantDefined() {
	; Move-resilient: scan the tap_holds module dir via the framework helper.
	; The global STUCK_MODIFIER_RELEASE_TIMEOUT_SEC := definition is unique to
	; constants.ahk within tap_holds, so the present-string check is unambiguous.
	Src := _DriverDirConcat("modules/tap_holds")
	Assert(InStr(Src, "global STUCK_MODIFIER_RELEASE_TIMEOUT_SEC :=") > 0,
		"STUCK_MODIFIER_RELEASE_TIMEOUT_SEC must be defined in tap_holds/constants.ahk (the early-loaded constants layer) so both lalt.ahk and rctrl.ahk can reference it when their hotkeys fire")
}
Test("tap-holds: stuck-modifier release timeout constant is defined in constants.ahk (oneshotshift-lalt-lshift-stuck)", _OSLLS_TimeoutConstantDefined)
