; adapters/http_client.ahk

; ==============================================================================
; MODULE: HttpClient Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the HttpClient port contract defined in
; static/ergopti_plus/_shared/core/ports/HttpClient.spec.js. Wraps WinHttp COM object
; (synchronous) behind the three canonical functions (HTTPPost, HTTPCancel,
; HTTPIsActive) so domain modules can make HTTP requests without coupling to
; the WinHttp COM API.
;
; NAMING CONVENTION:
; Port method → AHK name mapping:
;   post(url, headers, body, callback)  → HTTPPost(Url, Headers, Body, Callback)
;   cancel()                            → HTTPCancel()
;   isActive()                          → HTTPIsActive()
;
; AHK SYNC NOTE:
; AHK WinHttp calls are SYNCHRONOUS — the thread blocks until the response
; arrives or the timeout expires. The callback is therefore called inline
; before HTTPPost returns, matching the contract note: "on AHK, the callback
; is invoked inline before post() returns."
;
; TIMEOUT:
; The WinHttp timeout is set to HTTP_TIMEOUT_MS (30 s) to match the contract's
; DEFAULT_TIMEOUT_MS. A request can be aborted before it starts via HTTPCancel,
; but an in-flight synchronous request cannot be interrupted mid-transfer.
; ==============================================================================

; Active WinHttp object (0 = idle).
global _HTTP_ACTIVE_REQUEST := 0
; Timeout in milliseconds — matches HttpClient.spec.js DEFAULT_TIMEOUT_MS.
global HTTP_TIMEOUT_MS := 30000
; Monotonic counter guarding a reentrant HTTPPost call from clobbering a newer
; in-flight request's active-slot state (see HTTPPost's MyGeneration comment).
global _HTTP_REQUEST_GENERATION := 0




; =======================================================
; =======================================================
; ======= 1/ Adapter Methods ============================
; =======================================================
; =======================================================

; Sends a synchronous HTTP POST request and calls Callback with the result.
; @param Url      {String}   Absolute HTTPS URL.
; @param Headers  {Map}      Key→value header map.
; @param Body     {String}   JSON-encoded request body.
; @param Callback {Func}     Called with a Map: { ok, status, body, error }.
HTTPPost(Url, Headers, Body, Callback) {
	global _HTTP_ACTIVE_REQUEST, HTTP_TIMEOUT_MS, _HTTP_REQUEST_GENERATION
	if _HTTP_ACTIVE_REQUEST != 0 {
		LoggerWarn("HttpClient", "HTTPPost: reentrant call for '{1}' while a request is already active - cancelling the in-flight request first.", Url)
		HTTPCancel()
	}
	; A reentrant call can start AND finish while THIS call is still blocked
	; inside Req.Send() (WinHttp's synchronous COM call pumps Windows messages,
	; letting a timer/hotkey fire a nested HTTPPost). MyGeneration lets the
	; cleanup below detect that case and avoid clobbering the newer request's
	; HTTPCancel()/HTTPIsActive() visibility — mirrors the generation-counter
	; guard adapters/text_sender.ahk uses for its clipboard-restore race.
	_HTTP_REQUEST_GENERATION += 1
	MyGeneration := _HTTP_REQUEST_GENERATION
	Result := Map("ok", false, "status", 0, "body", "", "error", "")
	try {
		Req := ComObject("WinHttp.WinHttpRequest.5.1")
		_HTTP_ACTIVE_REQUEST := Req
		Req.SetTimeouts(HTTP_TIMEOUT_MS, HTTP_TIMEOUT_MS, HTTP_TIMEOUT_MS, HTTP_TIMEOUT_MS)
		Req.Open("POST", Url, false)
		; Set caller-supplied headers.
		if (Headers is Map) {
			for HName, HVal in Headers
				Req.SetRequestHeader(HName, HVal)
		}
		Req.Send(Body)
		Status := Req.Status
		RespBody := Req.ResponseText
		IsOk := Status >= 200 and Status < 300
		Result["ok"]     := IsOk
		Result["status"] := Status
		Result["body"]   := RespBody
		if !IsOk
			Result["error"] := "HTTP " . Status
	} catch as Err {
		Result["error"] := Err.Message
	}
	; Only clear the active-request slot if no newer call has taken over — see
	; the generation comment above.
	if (_HTTP_REQUEST_GENERATION == MyGeneration)
		_HTTP_ACTIVE_REQUEST := 0
	if Callback != 0 {
		try
			Callback(Result)
		catch as Err {
			LoggerError("HttpClient", "HTTPPost: completion callback threw: {1}", Err.Message)
		}
	}
}

; Aborts any in-flight WinHttp request and clears the active-request slot.
; Calling Abort() on the COM object interrupts the synchronous Send() call so
; the blocked HTTPPost thread unwinds immediately rather than waiting for the
; full HTTP_TIMEOUT_MS to elapse.
HTTPCancel() {
	global _HTTP_ACTIVE_REQUEST
	if _HTTP_ACTIVE_REQUEST != 0 {
		try _HTTP_ACTIVE_REQUEST.Abort()
		_HTTP_ACTIVE_REQUEST := 0
	}
}

; Returns true if a request is currently in flight.
; @return {Integer} 1 (true) or 0 (false).
HTTPIsActive() {
	global _HTTP_ACTIVE_REQUEST
	return _HTTP_ACTIVE_REQUEST != 0
}

; Machine-readable contract map - consumed by the generic adapter compliance test
; (tests/test_adapter_compliance_new.ahk) to verify every required method exists
; and is callable without manually listing functions per-adapter.
global ADAPTER_HTTP_CLIENT := Map(
    "post",     HTTPPost,
    "cancel",   HTTPCancel,
    "isActive", HTTPIsActive,
)
