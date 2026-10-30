; tests/meta/modules/shortcuts/test_paste_without_formatting_restore.ahk

; ==============================================================================
; MODULE: GesturePastePlain Restore Meta Test
; DESCRIPTION:
; Static source guard for the clipboard restore fix in GesturePastePlain.
;
; GesturePastePlain used to coerce A_Clipboard to plain text and then
; paste, permanently destroying the user's original rich clipboard content
; (images, HTML, RTF). The fix snapshots the full clipboard via CB_SaveAll()
; before the coercion and schedules a deferred restore via SetTimer, exactly
; mirroring the pattern already used by GesturePastePlain.
;
; This meta-static test scans the source so a regression that drops either
; the snapshot or the deferred restore fails the suite immediately.
; ==============================================================================

#Requires AutoHotkey v2.0




; ========================================
; ========================================
; ======= 1/ Source scan helpers =========
; ========================================
; ========================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_PWF_ReadSource(FileName) {
	return _DriverFileSource(FileName)
}




; ================================================================
; ================================================================
; ======= 2/ Paste-without-formatting assertions =================
; ================================================================
; ================================================================

_PWF_AssertSnapshot() {
	Src := _PWF_ReadSource("actions.ahk")
	Body := _DriverFuncBody("GesturePastePlain")
	Assert(Body != "", "GesturePastePlain(*) declaration must exist in actions.ahk")
	Assert(InStr(Body, "CB_SavePlainSnapshot(OwnerToken, &Captured)") > 0,
		"GesturePastePlain must snapshot the full clipboard via CB_SavePlainSnapshot() before coercion (paste-without-formatting-no-restore)")
}
Test("ctrl: GesturePastePlain snapshots clipboard before coercion (paste-without-formatting-no-restore)", _PWF_AssertSnapshot)

_PWF_AssertDeferredRestore() {
	Src := _PWF_ReadSource("actions.ahk")
	Body := _DriverFuncBody("GesturePastePlain")
	Assert(Body != "", "GesturePastePlain(*) declaration must exist in actions.ahk")
	Assert(InStr(Body, "SetTimer") > 0,
		"GesturePastePlain must schedule a deferred restore via SetTimer (paste-without-formatting-no-restore)")
}
Test("ctrl: GesturePastePlain schedules deferred clipboard restore (paste-without-formatting-no-restore)", _PWF_AssertDeferredRestore)

; Regression: GesturePastePlain's own comment claimed parity with
; GesturePastePlain's save/paste/deferred-restore guarantee, but it never
; actually participated in the shared clipboard transaction guard -- overlapping with a
; hotstring's clipboard-mode expansion (which also uses this guard) could
; corrupt either the user's clipboard or the hotstring's paste.
_PWF_AssertClipBusyGuardChecked() {
	Body := _DriverFuncBody("GesturePastePlain")
	GuardPos := InStr(Body, "CB_TryBeginPasteTransaction(")
	Assert(GuardPos > 0,
		"GesturePastePlain must participate in the shared exact-owner clipboard lease")

	SnapshotPos := InStr(Body, "CB_SavePlainSnapshot(OwnerToken, &Captured)")
	Assert(GuardPos < SnapshotPos,
		"GesturePastePlain must claim the lease BEFORE snapshotting/coercing the clipboard")
}
Test("ctrl: GesturePastePlain checks the shared clipboard-reentrancy guard before coercing (paste-without-formatting-clip-busy-race)",
	_PWF_AssertClipBusyGuardChecked)

_PWF_AssertClipBusyGuardSetAndCleared() {
	Body := _DriverFuncBody("GesturePastePlain")
	Assert(InStr(Body, "CB_TryBeginPasteTransaction(") > 0,
		"GesturePastePlain must acquire the shared exact-owner lease")

	RestoreBody := _DriverFuncBody("_GesturePastePlainRestore")
	Assert(RestoreBody != "", "_GesturePastePlainRestore must exist in actions.ahk")
	Assert(InStr(RestoreBody, "CB_RestorePlainSnapshotEventually") > 0
		and InStr(RestoreBody, "OwnerToken") > 0,
		"_GesturePastePlainRestore must retain its exact owner until cleanup settles")

	Assert(InStr(Body, "catch as e") > 0
		and RegExMatch(Body, "catch[\s\S]*?CB_RestorePlainSnapshotEventually\(OldClip, OwnedSequence,[\s\S]*?OwnerToken") > 0,
		"GesturePastePlain must transfer its snapshot and exact token on a thrown paste")
}
Test("ctrl: GesturePastePlain sets and clears the clip-busy guard on every exit path (paste-without-formatting-clip-busy-race)",
	_PWF_AssertClipBusyGuardSetAndCleared)
