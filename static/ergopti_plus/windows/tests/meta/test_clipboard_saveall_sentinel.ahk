; tests/meta/test_clipboard_saveall_sentinel.ahk

; ==============================================================================
; MODULE: Clipboard SaveAll/RestoreAll Error Sentinel Guard
; DESCRIPTION:
; Static source guard for the CB_SaveAll/CB_RestoreAll error-sentinel fix in
; adapters/clipboard.ahk — the sibling of CB_Save/CB_Restore's existing
; sentinel, guarded by tests/meta/test_clipboard_sentinel.ahk.
;
; ROOT CAUSE ENCODED:
; CB_SaveAll() previously returned "" on clipboard-lock failure, which is
; indistinguishable from a legitimately empty clipboard. CB_RestoreAll() had
; zero sentinel check and unconditionally executed A_Clipboard := Saved,
; wiping the user's real clipboard content (including non-text formats) on a
; failed save. The fix mirrors CB_Save/CB_Restore's "__CB_SAVE_ERROR__"
; sentinel pattern.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===========================================================
; ===========================================================
; ======= 1/ CB_SaveAll returns the error sentinel ==========
; ===========================================================
; ===========================================================

_TCSAS_SaveAllReturnsSentinel() {
	Body := _DriverFuncBody("CB_SaveAll")
	Assert(Body != "", "CB_SaveAll must be defined in adapters/clipboard.ahk")

	Assert(InStr(Body, "__CB_SAVE_ERROR__") > 0,
		'CB_SaveAll must return "__CB_SAVE_ERROR__" on failure so callers can distinguish a lock error from an empty clipboard')
}
Test("clipboard: CB_SaveAll returns __CB_SAVE_ERROR__ sentinel on clipboard-lock failure", _TCSAS_SaveAllReturnsSentinel)




; ===========================================================
; ===========================================================
; ======= 2/ CB_RestoreAll guards on the sentinel ============
; ===========================================================
; ===========================================================

_TCSAS_RestoreAllGuardsOnSentinel() {
	Body := _DriverFuncBody("CB_RestoreAll")
	Assert(Body != "", "CB_RestoreAll must be defined in adapters/clipboard.ahk")

	Assert(InStr(Body, "__CB_SAVE_ERROR__") > 0,
		"CB_RestoreAll must check for the __CB_SAVE_ERROR__ sentinel and skip the restore when it is the saved value")
	Assert(InStr(Body, "LoggerWarn") > 0,
		"CB_RestoreAll must log a WARNING when it skips a restore because CB_SaveAll failed")
}
Test("clipboard: CB_RestoreAll skips restore and warns when passed the __CB_SAVE_ERROR__ sentinel", _TCSAS_RestoreAllGuardsOnSentinel)
