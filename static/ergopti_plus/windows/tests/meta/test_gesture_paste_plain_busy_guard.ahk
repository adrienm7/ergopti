; tests/meta/test_gesture_paste_plain_busy_guard.ahk

; ==============================================================================
; MODULE: GesturePastePlain Busy Guard Meta Test
; DESCRIPTION:
; Static source guard for GesturePastePlain's shared exact-owner paste lease.
;
; GesturePastePlain has its own save/paste/deferred-restore lifecycle but
; previously did not participate in the process-wide guard that SendInstant
; uses. This meant a GesturePastePlain arriving while
; SendInstant was mid-flight (clipboard coerced, restore not yet fired) would
; launch a second save/restore cycle on top of the first, corrupting the
; user's original clipboard.
;
; The fix makes GesturePastePlain claim the lease before saving (skip the
; dance if busy) and makes the deferred restore release the exact token. This
; meta-static test scans the source so a regression that removes either half
; fails the suite immediately.
; ==============================================================================

#Requires AutoHotkey v2.0




; ========================================
; ========================================
; ======= 1/ Source scan helpers =========
; ========================================
; ========================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.




; ==========================================
; ==========================================
; ======= 2/ Busy-guard assertions =========
; ==========================================
; ==========================================

_GPPBG_AssertGesturePastePlainChecksGuard() {
	Body := _DriverFuncBody("GesturePastePlain")
	Assert(Body != "", "GesturePastePlain() declaration must exist in gestures.ahk")
	ClaimPos := InStr(Body, "CB_TryBeginPasteTransaction(")
	SnapshotPos := InStr(Body, "CB_SaveAll()")
	Assert(ClaimPos > 0 and SnapshotPos > ClaimPos,
		"GesturePastePlain must claim the exact-owner lease before snapshotting the clipboard")
}
Test("gestures: GesturePastePlain participates in the clipboard reentrancy guard (gesture-paste-plain-bypass-busy-guard)", _GPPBG_AssertGesturePastePlainChecksGuard)

_GPPBG_AssertRestoreClearsGuard() {
	Body := _DriverFuncBody("_GesturePastePlainRestore")
	Assert(Body != "", "_GesturePastePlainRestore(OldClip) declaration must exist in gestures.ahk")
	Assert(InStr(Body, "finally") > 0
		and InStr(Body, "CB_EndOwnedTransaction(OwnerToken)") > 0,
		"_GesturePastePlainRestore must release its exact owner token in finally")
}
Test("gestures: deferred restore releases the reentrancy guard (gesture-paste-plain-bypass-busy-guard)", _GPPBG_AssertRestoreClearsGuard)

; HIGH-03: the paste block (clipboard coerce + ^v + restore-timer arm) is wrapped
; in try/catch. If the send throws, the catch must restore the original clipboard
; AND release its exact token, otherwise every subsequent plain-paste remains
; excluded from the clipboard route.
_GPPBG_AssertCatchReleasesGuard() {
	Body := _DriverFuncBody("GesturePastePlain")
	Assert(Body != "", "GesturePastePlain() declaration must exist in gestures.ahk")
	Assert(RegExMatch(Body, "catch[\s\S]*?CB_EndOwnedTransaction\(OwnerToken\)") > 0,
		"GesturePastePlain catch must release only its exact transaction token (HIGH-03)")
}
Test("gestures: GesturePastePlain catch releases the busy guard on throw (HIGH-03)", _GPPBG_AssertCatchReleasesGuard)
