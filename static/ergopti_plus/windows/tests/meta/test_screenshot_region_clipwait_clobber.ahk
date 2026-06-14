; tests/meta/test_screenshot_region_clipwait_clobber.ahk

; ==============================================================================
; MODULE: Screenshot Region Clipwait Clobber Meta Test
; DESCRIPTION:
; Static source guard for the "screenshot-region-clipwait-clobber" finding.
; ==============================================================================

#Requires AutoHotkey v2.0

_TSC_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_TSC_Check() {
	Src := _TSC_ReadSource("modules/gestures.ahk")
	Assert(Src != "", "Source file gestures.ahk must exist")
	Assert(InStr(Src, "OldClip := ClipboardAll()") > 0, "gestures.ahk must backup clipboard")
	Assert(InStr(Src, "finally {") > 0, "gestures.ahk must use finally block to restore clipboard")
	Assert(InStr(Src, "A_Clipboard := OldClip") > 0, "gestures.ahk must restore clipboard")
}

Test("Gestures: screenshot region preserves clipboard", _TSC_Check)
