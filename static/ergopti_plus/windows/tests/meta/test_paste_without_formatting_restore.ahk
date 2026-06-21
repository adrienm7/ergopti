; tests/meta/test_paste_without_formatting_restore.ahk

; ==============================================================================
; MODULE: PasteWithoutFormatting Restore Meta Test
; DESCRIPTION:
; Static source guard for the clipboard restore fix in PasteWithoutFormatting.
;
; PasteWithoutFormatting used to coerce A_Clipboard to plain text and then
; paste, permanently destroying the user's original rich clipboard content
; (images, HTML, RTF). The fix snapshots the full clipboard via ClipboardAll()
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
	Assert(InStr(Body, "ClipboardAll()") > 0,
		"PasteWithoutFormatting must snapshot the full clipboard via ClipboardAll() before coercion (paste-without-formatting-no-restore)")
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