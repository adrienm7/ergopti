; tests/meta/test_clipboard_sentinel.ahk

; ==============================================================================
; MODULE: Clipboard Save Error Sentinel Guard
; DESCRIPTION:
; Static source guard for the CB_Save error-sentinel fix in
; adapters/clipboard.ahk.
;
; ROOT CAUSE ENCODED:
; CB_Save() previously returned "" (empty string) on clipboard-lock failure,
; which is indistinguishable from a legitimately empty clipboard. CB_Restore("")
; then cleared the clipboard when the lock had released, silently discarding
; the clipboard content. The fix makes CB_Save return the sentinel string
; "__CB_SAVE_ERROR__" on failure, and CB_Restore skips the restore when it
; receives the sentinel, so a failed save never overwrites the clipboard.
; ==============================================================================

#Requires AutoHotkey v2.0

_TCBS_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path, "UTF-8")
}

_TCBS_StripLineComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}


; ===========================================================
; ===========================================================
; ======= 1/ CB_Save returns the error sentinel =============
; ===========================================================
; ===========================================================

_TCBS_SaveReturnsSentinel() {
	Src := _TCBS_StripLineComments(_TCBS_ReadSource("adapters/clipboard.ahk"))
	Assert(Src != "", "adapters/clipboard.ahk must be readable")

	Body := _DriverFuncBody("CB_Save")
	Assert(Body != "", "CB_Save() must be defined in adapters/clipboard.ahk")

	Assert(InStr(Body, "__CB_SAVE_ERROR__") > 0,
		'CB_Save must return "__CB_SAVE_ERROR__" on failure so callers can distinguish a lock error from an empty clipboard')
}
Test("clipboard: CB_Save returns __CB_SAVE_ERROR__ sentinel on clipboard-lock failure", _TCBS_SaveReturnsSentinel)


; ===========================================================
; ===========================================================
; ======= 2/ CB_Restore guards on the sentinel ==============
; ===========================================================
; ===========================================================

_TCBS_RestoreGuardsOnSentinel() {
	Src := _TCBS_StripLineComments(_TCBS_ReadSource("adapters/clipboard.ahk"))

	Body := _DriverFuncBody("CB_Restore")
	Assert(Body != "", "CB_Restore(Saved) must be defined in adapters/clipboard.ahk")

	Assert(InStr(Body, "__CB_SAVE_ERROR__") > 0,
		"CB_Restore must check for the __CB_SAVE_ERROR__ sentinel and skip the restore when it is the saved value")
}
Test("clipboard: CB_Restore skips restore when passed the __CB_SAVE_ERROR__ sentinel", _TCBS_RestoreGuardsOnSentinel)
