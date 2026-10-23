; tests/unit/platform/network/test_http_post_replacement_validation.ahk

; ==============================================================================
; MODULE: HTTPPost Replacement Validation Tests
; DESCRIPTION:
; HTTPPost owns one active request and replaces it when called again. It
; cancelled the active request first and only then validated the new URL and
; headers, so a refused call (a CR, LF or NUL in the URL or a header, or a
; header name the native transport rejects) still killed a valid request in
; flight. The replacement must be composed and validated completely before
; the active request is touched; the refused call reports its error through
; the callback and leaves the active request owned and running.
; ==============================================================================

#Requires AutoHotkey v2.0

class _HPRV_ActiveRequest {
	__New() {
		this.Aborts := 0
	}
	Abort() {
		this.Aborts += 1
		return true
	}
}

_HPRV_Case(Label, Url, Headers) {
	global _HTTP_ACTIVE_REQUEST, _HTTP_REQUEST_GENERATION
	SavedActive := _HTTP_ACTIVE_REQUEST, SavedGeneration := _HTTP_REQUEST_GENERATION
	Active := _HPRV_ActiveRequest()
	Results := []
	try {
		_HTTP_ACTIVE_REQUEST := Active
		HTTPPost(Url, Headers, "{}", (Result) => Results.Push(Result))
		AssertEqual(0, Active.Aborts, Label . ": a refused replacement must not cancel the active request")
		AssertTrue(_HTTP_ACTIVE_REQUEST == Active, Label . ": the active request must stay owned")
		AssertEqual(1, Results.Length, Label . ": the refused call must report through its callback once")
		AssertFalse(Results[1]["ok"], Label . ": the refused call must not report success")
		AssertTrue(Results[1]["error"] != "", Label . ": the refused call must carry its error")
	} finally {
		_HTTP_ACTIVE_REQUEST := SavedActive
		_HTTP_REQUEST_GENERATION := SavedGeneration
	}
}

_HPRV_InvalidReplacementsKeepTheActiveRequest() {
	Url := "http://127.0.0.1:9/replacement"
	Failures := []
	Cases := []
	for Name, Unit in Map("LF", Chr(10), "CR", Chr(13), "NUL", Chr(0)) {
		Cases.Push(["URL with " . Name, Url . Unit . "x", Map()])
		; A native Map key stops at NUL, so no caller can pass a NUL header name.
		if Name != "NUL"
			Cases.Push(["header name with " . Name, Url, Map("X-Bad" . Unit . "Name", "v")])
		Cases.Push(["header value with " . Name, Url, Map("X-Header", "a" . Unit . "b")])
	}
	Cases.Push(["header name with a space", Url, Map("Bad Name", "v")])
	Cases.Push(["header name with a colon", Url, Map("X-Injected: yes", "v")])
	for Entry in Cases {
		try _HPRV_Case(Entry[1], Entry[2], Entry[3])
		catch as Err
			Failures.Push(Err.Message)
	}
	Report := ""
	for Message in Failures
		Report .= (Report == "" ? "" : " | ") . Message
	AssertEqual(0, Failures.Length, Failures.Length . " of " . Cases.Length . " refused replacements cancelled a valid request: " . Report)
}
Test("HTTPPost: a refused replacement never cancels the active request (http-post-replacement-preflight)",
	_HPRV_InvalidReplacementsKeepTheActiveRequest)

; Control: header names the native transport accepts still pass validation.
_HPRV_TokenNamesStillAccepted() {
	Request := CurlAsyncRequest()
	for Name in ["Authorization", "x-api-key", "anthropic-version", "Content-Type", "X-Ergopti_1.2~!#$%&'*+^``|"]
		Request.SetRequestHeader(Name, "value")
	AssertEqual(5, Request.Headers.Count, "every RFC 9110 token name must be accepted")
}
Test("HTTPPost: token header names are still accepted (http-post-replacement-preflight)",
	_HPRV_TokenNamesStillAccepted)
