; tests/meta/test_plc_stop_clears_callbacks.ahk

; ==============================================================================
; MODULE: PLC_Stop Callback Arrays Clear Guard
; DESCRIPTION:
; Static source guard for the PLC_Stop callback-clear fix in
; adapters/process_lifecycle.ahk.
;
; ROOT CAUSE ENCODED:
; When PLC_Stop() was called (e.g. on script reload or explicit lifecycle
; shutdown), it stopped the polling timer but left the three callback arrays
; (PLC_FocusCallbacks, PLC_LaunchCallbacks, PLC_QuitCallbacks) intact. On the
; next PLC_Start() call the accumulated callbacks from the previous lifecycle
; were still present, causing duplicate fires for every registered callback.
;
; The fix clears all three arrays to [] inside PLC_Stop() so a fresh start
; begins with an empty slate. This test verifies all three clear assignments
; are present in the PLC_Stop function body.
; ==============================================================================

#Requires AutoHotkey v2.0

_TPSCC_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path, "UTF-8")
}

_TPSCC_StripLineComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}


; ================================================================
; ================================================================
; ======= 1/ All three callback arrays cleared in PLC_Stop ========
; ================================================================
; ================================================================

_TPSCC_AllCallbacksCleared() {
	Src := _TPSCC_StripLineComments(_TPSCC_ReadSource("adapters/process_lifecycle.ahk"))
	Assert(Src != "", "adapters/process_lifecycle.ahk must be readable")

	Body := _DriverFuncBody("PLC_Stop")
	Assert(Body != "", "PLC_Stop must be defined in adapters/process_lifecycle.ahk")

	; All three arrays must be reset
	Assert(InStr(Body, "PLC_FocusCallbacks  := []") > 0,
		"PLC_Stop must clear PLC_FocusCallbacks := [] to prevent duplicate fires on restart")
	Assert(InStr(Body, "PLC_LaunchCallbacks := []") > 0,
		"PLC_Stop must clear PLC_LaunchCallbacks := [] to prevent duplicate fires on restart")
	Assert(InStr(Body, "PLC_QuitCallbacks   := []") > 0,
		"PLC_Stop must clear PLC_QuitCallbacks := [] to prevent duplicate fires on restart")
}
Test("process_lifecycle: PLC_Stop clears all three callback arrays to prevent duplicate fires", _TPSCC_AllCallbacksCleared)
