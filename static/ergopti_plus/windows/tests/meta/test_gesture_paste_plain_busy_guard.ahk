; tests/meta/test_gesture_paste_plain_busy_guard.ahk

; ==============================================================================
; MODULE: GesturePastePlain Busy Guard Meta Test
; DESCRIPTION:
; Static source guard for the _SEND_INSTANT_CLIP_BUSY reentrancy fix applied
; to GesturePastePlain.
;
; GesturePastePlain has its own save/paste/deferred-restore lifecycle but
; previously did not participate in the process-wide _SEND_INSTANT_CLIP_BUSY
; flag that SendInstant uses. This meant a GesturePastePlain arriving while
; SendInstant was mid-flight (clipboard coerced, restore not yet fired) would
; launch a second save/restore cycle on top of the first, corrupting the
; user's original clipboard.
;
; The fix makes GesturePastePlain check the flag before saving (skip the
; dance if busy) and makes the deferred restore clear it. This meta-static
; test scans the source so a regression that removes either half fails the
; suite immediately.
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
	Assert(InStr(Body, "_SEND_INSTANT_CLIP_BUSY") > 0,
		"GesturePastePlain must read/set _SEND_INSTANT_CLIP_BUSY to participate in the clipboard reentrancy guard (gesture-paste-plain-bypass-busy-guard)")
}
Test("gestures: GesturePastePlain participates in the clipboard reentrancy guard (gesture-paste-plain-bypass-busy-guard)", _GPPBG_AssertGesturePastePlainChecksGuard)

_GPPBG_AssertRestoreClearsGuard() {
	Body := _DriverFuncBody("_GesturePastePlainRestore")
	Assert(Body != "", "_GesturePastePlainRestore(OldClip) declaration must exist in gestures.ahk")
	Assert(InStr(Body, "_SEND_INSTANT_CLIP_BUSY") > 0,
		"_GesturePastePlainRestore must clear _SEND_INSTANT_CLIP_BUSY so the next operation can take the clipboard route (gesture-paste-plain-bypass-busy-guard)")
}
Test("gestures: deferred restore releases the reentrancy guard (gesture-paste-plain-bypass-busy-guard)", _GPPBG_AssertRestoreClearsGuard)

; HIGH-03: the paste block (clipboard coerce + ^v + restore-timer arm) is wrapped
; in try/catch. If the send throws, the catch must restore the original clipboard
; AND clear _SEND_INSTANT_CLIP_BUSY — otherwise the guard latches true forever and
; every subsequent plain-paste silently falls through to the bypass branch.
_GPPBG_AssertCatchReleasesGuard() {
	Body := _DriverFuncBody("GesturePastePlain")
	Assert(Body != "", "GesturePastePlain() declaration must exist in gestures.ahk")
	Assert(RegExMatch(Body, "catch[\s\S]*?_SEND_INSTANT_CLIP_BUSY := false") > 0,
		"GesturePastePlain catch block must reset _SEND_INSTANT_CLIP_BUSY := false so a throw mid-paste does not latch the guard forever (HIGH-03)")
}
Test("gestures: GesturePastePlain catch releases the busy guard on throw (HIGH-03)", _GPPBG_AssertCatchReleasesGuard)