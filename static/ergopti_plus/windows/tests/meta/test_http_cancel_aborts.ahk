; tests/meta/test_http_cancel_aborts.ahk

; ==============================================================================
; MODULE: HTTPCancel Abort-Before-Zero Guard
; DESCRIPTION:
; Static source guard for the HTTPCancel Abort() ordering fix in
; adapters/http_client.ahk.
;
; ROOT CAUSE ENCODED:
; The original HTTPCancel zeroed the _HTTP_ACTIVE_REQUEST slot before calling
; Abort(), meaning a concurrent thread checking _HTTP_ACTIVE_REQUEST would see
; 0 and proceed without waiting for the in-flight request to actually terminate.
; The COM object could also outlive any reference, leaking the WinHttp handle.
;
; The fix calls try _HTTP_ACTIVE_REQUEST.Abort() BEFORE zeroing the slot, so:
;   1. The Abort() interrupts the synchronous Send() call in the other thread.
;   2. The slot is only cleared after the cancel signal has been dispatched.
; This test verifies that Abort() appears before the zero-assignment in the
; HTTPCancel function body.
; ==============================================================================

#Requires AutoHotkey v2.0

_THCA_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path, "UTF-8")
}

_THCA_StripLineComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}





; ===============================================================
; ===============================================================
; ======= 1/ HTTPCancel calls Abort() before zeroing slot =======
; ===============================================================
; ===============================================================

_THCA_AbortBeforeZero() {
	Src := _THCA_StripLineComments(_THCA_ReadSource("adapters/http_client.ahk"))
	Assert(Src != "", "adapters/http_client.ahk must be readable")

	Body := _DriverFuncBody("HTTPCancel")
	Assert(Body != "", "HTTPCancel must be defined in adapters/http_client.ahk")

	; Abort() must be called
	Assert(InStr(Body, ".Abort()") > 0,
		"HTTPCancel must call .Abort() on the active request before zeroing the slot")

	; The zero-assignment must follow Abort()
	AbortPos := InStr(Body, ".Abort()")
	ZeroPos  := InStr(Body, "_HTTP_ACTIVE_REQUEST := 0")
	Assert(ZeroPos > 0,
		"HTTPCancel must zero _HTTP_ACTIVE_REQUEST := 0 after aborting")
	Assert(AbortPos < ZeroPos,
		"HTTPCancel must call .Abort() BEFORE zeroing _HTTP_ACTIVE_REQUEST := 0 (abort-before-zero fix)")
}
Test("http_client: HTTPCancel calls .Abort() before zeroing the active-request slot", _THCA_AbortBeforeZero)
