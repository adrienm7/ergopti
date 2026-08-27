; tests/meta/test_paste_without_formatting_restore.ahk

; ==============================================================================
; MODULE: PasteWithoutFormatting Restore Meta Test
; DESCRIPTION:
; Static source guard for the clipboard restore fix in PasteWithoutFormatting.
;
; PasteWithoutFormatting used to coerce A_Clipboard to plain text and then
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
_PWF_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ================================================================
; ================================================================
; ======= 2/ Paste-without-formatting assertions =================
; ================================================================
; ================================================================

_PWF_AssertSnapshot() {
	Src := _PWF_ReadSource("modules/shortcuts/ctrl.ahk")
	Body := _DriverFuncBody("PasteWithoutFormatting")
	Assert(Body != "", "PasteWithoutFormatting(*) declaration must exist in ctrl.ahk")
	Assert(InStr(Body, "CB_SaveAll()") > 0,
		"PasteWithoutFormatting must snapshot the full clipboard via CB_SaveAll() before coercion (paste-without-formatting-no-restore)")
}
Test("ctrl: PasteWithoutFormatting snapshots clipboard before coercion (paste-without-formatting-no-restore)", _PWF_AssertSnapshot)

_PWF_AssertDeferredRestore() {
	Src := _PWF_ReadSource("modules/shortcuts/ctrl.ahk")
	Body := _DriverFuncBody("PasteWithoutFormatting")
	Assert(Body != "", "PasteWithoutFormatting(*) declaration must exist in ctrl.ahk")
	Assert(InStr(Body, "SetTimer") > 0,
		"PasteWithoutFormatting must schedule a deferred restore via SetTimer (paste-without-formatting-no-restore)")
}
Test("ctrl: PasteWithoutFormatting schedules deferred clipboard restore (paste-without-formatting-no-restore)", _PWF_AssertDeferredRestore)

; Regression: PasteWithoutFormatting's own comment claimed parity with
; GesturePastePlain's save/paste/deferred-restore guarantee, but it never
; actually participated in the shared clipboard transaction guard -- overlapping with a
; hotstring's clipboard-mode expansion (which also uses this guard) could
; corrupt either the user's clipboard or the hotstring's paste.
_PWF_AssertClipBusyGuardChecked() {
	Body := _DriverFuncBody("PasteWithoutFormatting")
	GuardPos := InStr(Body, "CB_TryBeginPasteTransaction(")
	Assert(GuardPos > 0,
		"PasteWithoutFormatting must participate in the shared exact-owner clipboard lease")

	SnapshotPos := InStr(Body, "CB_SaveAll()")
	Assert(GuardPos < SnapshotPos,
		"PasteWithoutFormatting must claim the lease BEFORE snapshotting/coercing the clipboard")
}
Test("ctrl: PasteWithoutFormatting checks the shared clipboard-reentrancy guard before coercing (paste-without-formatting-clip-busy-race)",
	_PWF_AssertClipBusyGuardChecked)

_PWF_AssertClipBusyGuardSetAndCleared() {
	Body := _DriverFuncBody("PasteWithoutFormatting")
	Assert(InStr(Body, "CB_TryBeginPasteTransaction(") > 0,
		"PasteWithoutFormatting must acquire the shared exact-owner lease")

	RestoreBody := _DriverFuncBody("_PasteWithoutFormattingRestore")
	Assert(RestoreBody != "", "_PasteWithoutFormattingRestore must exist in ctrl.ahk")
	Assert(InStr(RestoreBody, "CB_EndOwnedTransaction(OwnerToken)") > 0,
		"_PasteWithoutFormattingRestore must release its exact owner token")

	Assert(InStr(Body, "catch as e") > 0
		and RegExMatch(Body, "catch[\s\S]*?CB_EndOwnedTransaction\(OwnerToken\)") > 0,
		"PasteWithoutFormatting must release its exact token on a thrown paste")
}
Test("ctrl: PasteWithoutFormatting sets and clears the clip-busy guard on every exit path (paste-without-formatting-clip-busy-race)",
	_PWF_AssertClipBusyGuardSetAndCleared)
