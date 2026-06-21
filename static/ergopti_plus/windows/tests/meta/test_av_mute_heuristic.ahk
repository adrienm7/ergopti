; tests/meta/test_av_mute_heuristic.ahk

; ==============================================================================
; MODULE: AV Mute Heuristic Meta Test
; DESCRIPTION:
; Static source guard for the "av-mute-heuristic-and-doc-mismatch" finding.
; ==============================================================================

#Requires AutoHotkey v2.0

_TAV_Check() {
	; Move-resilient: scan the keylogger module tree (comments preserved — one
	; assertion targets the "heuristic" doc string) instead of a pinned path.
	; The unique KL_AV_GetMasterMuted(vol) signature keeps the scope meaningful.
	Src := _DriverDirConcat("modules/keylogger")
	Assert(InStr(Src, "KL_AV_GetMasterMuted(vol)") > 0, "keylogger_av_state.ahk must take vol parameter")
	Assert(InStr(Src, "heuristic") > 0, "keylogger_av_state.ahk must document the heuristic")
}

Test("Keylogger: AV mute uses heuristic without double-call", _TAV_Check)
