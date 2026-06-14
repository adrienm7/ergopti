; tests/meta/test_av_mute_heuristic.ahk

; ==============================================================================
; MODULE: AV Mute Heuristic Meta Test
; DESCRIPTION:
; Static source guard for the "av-mute-heuristic-and-doc-mismatch" finding.
; ==============================================================================

#Requires AutoHotkey v2.0

_TAV_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_TAV_Check() {
	Src := _TAV_ReadSource("modules/keylogger/keylogger_av_state.ahk")
	Assert(Src != "", "Source file keylogger_av_state.ahk must exist")
	Assert(InStr(Src, "KL_AV_GetMasterMuted(vol)") > 0, "keylogger_av_state.ahk must take vol parameter")
	Assert(InStr(Src, "heuristic") > 0, "keylogger_av_state.ahk must document the heuristic")
}

Test("Keylogger: AV mute uses heuristic without double-call", _TAV_Check)
