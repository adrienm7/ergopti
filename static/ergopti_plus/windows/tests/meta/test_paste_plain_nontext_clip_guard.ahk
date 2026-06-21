; tests/meta/test_paste_plain_nontext_clip_guard.ahk

; ==============================================================================
; MODULE: Paste-Plain Non-Text Clipboard Guard Meta Test
; DESCRIPTION:
; Static source guard for finding paste-plain-destroys-nontext-clip.
;
; Both PasteWithoutFormatting (modules/shortcuts/ctrl.ahk) and GesturePastePlain
; (modules/gestures.ahk) strip rich formatting with the documented idiom
; A_Clipboard := A_Clipboard. A_Clipboard is text-only in AHK v2, so that
; round-trip DESTROYS a non-text clipboard payload (image / file list). The fix
; guards the self-assignment behind a CB_Read() != "" text-availability check so
; non-text content is left intact and pasted as-is.
;
; This is a meta-static test (scans source text). The two functions call
; WinActive / SendFinalResult / mutate the clipboard, so invoking them in the
; headless runner would have real OS side effects. If either guard is removed,
; this test fails -- the destructive strip must never run unconditionally again.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_PPNC_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ==================================================
; ==================================================
; ======= 2/ Guard assertions ======================
; ==================================================
; ==================================================

_PPNC_PasteWithoutFormattingHasTextGuard() {
	Src := _PPNC_ReadSource("modules/shortcuts/ctrl.ahk")
	Seg := _DriverFuncBody("PasteWithoutFormatting")
	Assert(Seg != "", "PasteWithoutFormatting(*) declaration must exist in modules/shortcuts/ctrl.ahk")
	StripIdx := InStr(Seg, "A_Clipboard := A_Clipboard")
	Assert(StripIdx > 0, "PasteWithoutFormatting must still strip rich formatting via A_Clipboard := A_Clipboard")
	Before := SubStr(Seg, 1, StripIdx - 1)
	Assert(InStr(Before, "CB_Read()") > 0,
		"PasteWithoutFormatting must guard the A_Clipboard := A_Clipboard strip with a CB_Read() text-availability check -- otherwise it destroys a non-text clipboard payload")
}
Test("ctrl: PasteWithoutFormatting guards strip on non-text clipboard (paste-plain-destroys-nontext-clip)", _PPNC_PasteWithoutFormattingHasTextGuard)

_PPNC_GesturePastePlainHasTextGuard() {
	Src := _PPNC_ReadSource("modules/gestures.ahk")
	Seg := _DriverFuncBody("GesturePastePlain")
	Assert(Seg != "", "GesturePastePlain() declaration must exist in modules/gestures.ahk")
	StripIdx := InStr(Seg, "A_Clipboard := A_Clipboard")
	Assert(StripIdx > 0, "GesturePastePlain must still strip rich formatting via A_Clipboard := A_Clipboard")
	Before := SubStr(Seg, 1, StripIdx - 1)
	Assert(InStr(Before, "CB_Read()") > 0,
		"GesturePastePlain must guard the A_Clipboard := A_Clipboard strip with a CB_Read() text-availability check -- otherwise it destroys a non-text clipboard payload")
}
Test("gestures: GesturePastePlain guards strip on non-text clipboard (paste-plain-destroys-nontext-clip)", _PPNC_GesturePastePlainHasTextGuard)
