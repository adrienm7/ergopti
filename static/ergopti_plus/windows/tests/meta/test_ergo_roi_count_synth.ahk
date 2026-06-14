; tests/meta/test_ergo_roi_count_synth.ahk

; ==============================================================================
; MODULE: Ergo ROI Count Synth Meta Test
; DESCRIPTION:
; Static source guard for the "ergo-roi-count-synthetic-keystrokes" finding.
; ==============================================================================

#Requires AutoHotkey v2.0

_TES_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_TES_Check() {
	Src := _TES_ReadSource("modules/keylogger/keylogger_hook.ahk")
	Assert(Src != "", "Source file keylogger_hook.ahk must exist")
	Assert(InStr(Src, "!Keylogger.synth_active") > 0, "keylogger_hook.ahk must check synth_active before Ergo/ROI")
	Assert(InStr(Src, "KLHook.last_tick := 0") > 0, "keylogger_hook.ahk must reset last_tick on synth strokes")
}

Test("Keylogger: synthetic strokes bypass ergo/roi counting", _TES_Check)
