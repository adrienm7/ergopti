; tests/meta/test_http_post_reentrancy_guard.ahk

; ==============================================================================
; MODULE: HTTPPost Reentrancy Guard
; DESCRIPTION:
; Static source guard verifying HTTPPost (adapters/http_client.ahk) protects
; its shared _HTTP_ACTIVE_REQUEST slot against a reentrant call finishing
; while an outer call is still blocked inside the synchronous Req.Send() COM
; call (WinHttp's synchronous request pumps Windows messages while blocked,
; letting a timer/hotkey fire a nested HTTPPost).
;
; ROOT CAUSE ENCODED:
; The original HTTPPost unconditionally zeroed _HTTP_ACTIVE_REQUEST on exit,
; regardless of whether a newer reentrant call had since taken over the slot —
; the outer call's cleanup could clobber the inner call's HTTPCancel()/
; HTTPIsActive() visibility. HTTPPost has zero live callers today (confirmed
; via `grep -rn "HTTPPost(" .` across the whole windows/ tree) but is a
; required method of the cross-platform HttpClient port contract
; (_shared/core/ports/contracts.json), so it cannot be deleted — this guards
; the latent risk instead. No WinHttp mocking seam exists to force genuine
; message-pump reentrancy in the headless test harness, so this is a
; source-scan test, matching the existing precedent in
; tests/meta/test_http_cancel_aborts.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0

_MetaHttpPostReentrancyGuard() {
	Body := _DriverFuncBody("HTTPPost")
	Assert(Body != "", "HTTPPost must be defined in adapters/http_client.ahk")

	Assert(InStr(Body, "_HTTP_REQUEST_GENERATION") > 0,
		"HTTPPost must guard its cleanup with a generation counter so a reentrant call cannot clobber a newer request's active-slot state")

	ClearPos := InStr(Body, "_HTTP_ACTIVE_REQUEST := 0")
	Assert(ClearPos > 0, "HTTPPost must still clear the active-request slot on the happy path")
	GuardPos := InStr(Body, "if (_HTTP_REQUEST_GENERATION == MyGeneration)")
	Assert(GuardPos > 0 && GuardPos < ClearPos,
		"HTTPPost's active-slot clear must be preceded by a generation-match guard, not run unconditionally")
}
Test("http_client: HTTPPost guards its active-slot cleanup against reentrant clobbering", _MetaHttpPostReentrancyGuard)
