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
; One source of truth for every curl response written or materialized by AHK.
; Eight MiB is far above metadata/model-list and bounded LLM completion payloads,
; while keeping a hostile endpoint from filling disk or allocating an arbitrary
; response-sized AHK string on the shared input thread.
global HTTP_CURL_MAX_RESPONSE_BYTES := 8 * 1024 * 1024
; Header dumps are separate from curl's response body, so --max-filesize does
; not cover them. Bound their terminal materialization independently.
global HTTP_CURL_MAX_HEADER_BYTES := 256 * 1024
; curl 8.4.0 made --max-filesize enforce the limit while receiving a response
; whose Content-Length is absent or dishonest. Older binaries only reject from
; the declared size and can therefore fill the output file until max-time.
global HTTP_CURL_RUNTIME_LIMIT_MIN_VERSION := "8.4.0"
; Retry transient sharing violations without dropping ownership of request
; artifacts that can contain request bodies or credentials.
global HTTP_CURL_CLEANUP_RETRY_MS := 50
; Monotonic counter guarding a reentrant HTTPPost call from clobbering a newer
; in-flight request's active-slot state (see HTTPPost's MyGeneration comment).
global _HTTP_REQUEST_GENERATION := 0
; Unique namespace for the private curl config/body/header artifacts used by
; CurlAsyncRequest. Secrets and URLs never travel through the process command line.
global _HTTP_CURL_REQUEST_COUNTER := 0
; Requests whose private curl artifacts could not yet be deleted. Retaining the
; request object prevents a canceled request from losing its cleanup owner.
global _HTTP_CURL_CLEANUP_DEBTS := Map()
global _HTTP_CURL_CLEANUP_TIMER := 0




; =======================================================
; =======================================================
; ======= 1/ Non-blocking internal transport ============
; =======================================================
; =======================================================

_HTTP_CurlNextRequestId() {
	global _HTTP_CURL_REQUEST_COUNTER
	PreviousCritical := Critical("On")
	try return ++_HTTP_CURL_REQUEST_COUNTER
	finally Critical(PreviousCritical)
}

_HTTP_CurlConfigQuote(Value) {
	Escaped := StrReplace(String(Value), "\", "\\")
	Escaped := StrReplace(Escaped, '"', '\"')
	return '"' . Escaped . '"'
}

_HTTP_CurlScalarIsSafe(Value) {
	return Value is String && !RegExMatch(Value, "[\x00-\x1F\x7F-\x9F]")
}

_HTTP_CurlVersionAtLeast(Candidate, Minimum) {
	if !RegExMatch(String(Candidate), "^\s*(\d+)\.(\d+)\.(\d+)", &CandidateMatch)
		return false
	if !RegExMatch(String(Minimum), "^\s*(\d+)\.(\d+)\.(\d+)", &MinimumMatch)
		return false
	loop 3 {
		CandidatePart := Integer(CandidateMatch[A_Index])
		MinimumPart := Integer(MinimumMatch[A_Index])
		if CandidatePart != MinimumPart
			return CandidatePart > MinimumPart
	}
	return true
}

_HTTP_CurlRuntimeLimitSupported(CurlExe, VersionFn := 0) {
	global HTTP_CURL_RUNTIME_LIMIT_MIN_VERSION
	if !IsObject(VersionFn)
		VersionFn := FileGetVersion
	try Version := VersionFn.Call(CurlExe)
	catch
		return false
	return _HTTP_CurlVersionAtLeast(Version,
		HTTP_CURL_RUNTIME_LIMIT_MIN_VERSION)
}

_HTTP_CurlSweepOrphans() {
	CurrentPid := DllCall("Kernel32\GetCurrentProcessId", "UInt")
	Loop Files A_Temp . "\ergopti_http_*.*", "F" {
		if !RegExMatch(A_LoopFileName,
				"^ergopti_http_(\d+)_\d+\.(?:conf|body|headers)$", &Match)
			continue
		OwnerPid := Integer(Match[1])
		TooOld := false
		try TooOld := DateDiff(A_Now, A_LoopFileTimeModified, "Seconds") > 86400
		OwnerAlive := false
		if (OwnerPid == CurrentPid)
			OwnerAlive := true
		else
			try OwnerAlive := ProcessExist(OwnerPid) == OwnerPid
		if (!OwnerAlive || TooOld)
			try FSDelete(A_LoopFileFullPath)
	}
}

_HTTP_CurlRetainCleanupDebt(Request) {
	global _HTTP_CURL_CLEANUP_DEBTS, _HTTP_CURL_CLEANUP_TIMER
	global HTTP_CURL_CLEANUP_RETRY_MS
	_HTTP_CURL_CLEANUP_DEBTS[Request.CleanupDebtId] := Request
	if IsObject(_HTTP_CURL_CLEANUP_TIMER)
		return true
	RetryFn := _HTTP_CurlRetryDeferredCleanup
	_HTTP_CURL_CLEANUP_TIMER := RetryFn
	try {
		SetTimer(RetryFn, -HTTP_CURL_CLEANUP_RETRY_MS)
		return true
	} catch as Err {
		_HTTP_CURL_CLEANUP_TIMER := 0
		try LoggerError("HttpClient",
			"Could not schedule deferred curl artifact cleanup: {1}.", Err.Message)
		return false
	}
}

_HTTP_CurlReleaseCleanupDebt(Request) {
	global _HTTP_CURL_CLEANUP_DEBTS
	if _HTTP_CURL_CLEANUP_DEBTS.Has(Request.CleanupDebtId)
		_HTTP_CURL_CLEANUP_DEBTS.Delete(Request.CleanupDebtId)
}

_HTTP_CurlRetryDeferredCleanup(*) {
	global _HTTP_CURL_CLEANUP_DEBTS, _HTTP_CURL_CLEANUP_TIMER
	_HTTP_CURL_CLEANUP_TIMER := 0
	Pending := []
	for _, Request in _HTTP_CURL_CLEANUP_DEBTS
		Pending.Push(Request)
	for _, Request in Pending
		Request._Cleanup()
}

_HTTP_CurlParseHeaders(RawHeaders) {
	Result := Map("status", 0, "headers", Map())
	Normalized := StrReplace(RawHeaders, "`r`n", "`n")
	for Block in StrSplit(Normalized, "`n`n") {
		if !RegExMatch(Block, "m)^HTTP/\S+\s+(\d{3})(?:\s|$)", &Match)
			continue
		Headers := Map()
		for Line in StrSplit(Block, "`n") {
			Colon := InStr(Line, ":")
			if (Colon <= 1)
				continue
			Name := StrLower(Trim(SubStr(Line, 1, Colon - 1)))
			Headers[Name] := Trim(SubStr(Line, Colon + 1))
		}
		Result := Map("status", Integer(Match[1]), "headers", Headers)
	}
	return Result
}

/**
 * WinHttpRequest async mode can still block its caller during DNS/connect/Send.
 * This compatibility transport performs every network phase in a tree-owned
 * curl child while retaining the small WinHTTP-like surface used by existing
 * updater and LLM state machines.
 */
class CurlAsyncRequest {
	__New(DispatchPort := 0) {
		Id := DllCall("Kernel32\GetCurrentProcessId", "UInt") . "_"
			. _HTTP_CurlNextRequestId()
		Base := A_Temp . "\ergopti_http_" . Id
		this.ConfigPath := Base . ".conf"
		this.BodyPath := Base . ".body"
		this.HeaderPath := Base . ".headers"
		this.Method := ""
		this.Url := ""
		this.Headers := Map()
		this.ConnectTimeoutMs := 5000
		this.TotalTimeoutMs := 30000
		this.Handle := 0
		this.Completed := false
		this.Aborted := false
		this.CleanupDebtId := Id
		this.CleanupPending := false
		this.Status := 0
		this.ResponseText := ""
		this.ResponseHeaders := Map()
		; The transport writes its private request files before it starts curl. File
		; I/O can pump a competing cancellation callback, so tests need a deterministic
		; pre-launch boundary rather than a timing-sensitive scheduler race.
		this.DispatchPort := DispatchPort is Map ? DispatchPort : 0
	}

	Open(Method, Url, Async := true) {
		if !Async
			throw ValueError("CurlAsyncRequest only supports asynchronous dispatch.")
		Method := StrUpper(String(Method))
		if !(Method == "GET" || Method == "POST" || Method == "DELETE")
			throw ValueError("Unsupported asynchronous HTTP method.", -1, Method)
		if !_HTTP_CurlScalarIsSafe(Url)
			throw ValueError("HTTP URL contains a control character.")
		this.Method := Method
		this.Url := Url
	}

	SetRequestHeader(Name, Value) {
		if !_HTTP_CurlScalarIsSafe(Name) || !_HTTP_CurlScalarIsSafe(Value)
			throw ValueError("HTTP header contains a control character.")
		this.Headers[String(Name)] := String(Value)
	}

	SetTimeouts(ResolveMs, ConnectMs, SendMs, ReceiveMs) {
		this.ConnectTimeoutMs := Max(1, Integer(ResolveMs) + Integer(ConnectMs))
		this.TotalTimeoutMs := Max(1, Integer(ResolveMs) + Integer(ConnectMs)
			+ Integer(SendMs) + Integer(ReceiveMs))
	}

	Send(Body := "") {
		if (this.Method == "" || this.Url == "")
			throw Error("CurlAsyncRequest.Open must succeed before Send.")
		if IsObject(this.Handle)
			throw Error("CurlAsyncRequest.Send may run only once.")
		if this.Completed {
			if this.Aborted
				return false
			throw Error("CurlAsyncRequest.Send may run only once.")
		}
		CurlExe := A_WinDir . "\System32\curl.exe"
		if !FileExist(CurlExe)
			throw Error("The Windows curl transport is unavailable.")
		if !_HTTP_CurlRuntimeLimitSupported(CurlExe)
			throw Error("The Windows curl transport cannot enforce the live response-size limit.")
		_HTTP_CurlSweepOrphans()
		if this.Aborted
			return false

		Config := "url = " . _HTTP_CurlConfigQuote(this.Url) . "`n"
		Config .= "request = " . _HTTP_CurlConfigQuote(this.Method) . "`n"
		Config .= "silent`nshow-error`n"
		Config .= "connect-timeout = " . Ceil(this.ConnectTimeoutMs / 1000) . "`n"
		Config .= "max-time = " . Ceil(this.TotalTimeoutMs / 1000) . "`n"
		Config .= "max-filesize = " . HTTP_CURL_MAX_RESPONSE_BYTES . "`n"
		Config .= "dump-header = " . _HTTP_CurlConfigQuote(this.HeaderPath) . "`n"
		Config .= "output = " . _HTTP_CurlConfigQuote("-") . "`n"
		for Name, Value in this.Headers
			Config .= "header = "
				. _HTTP_CurlConfigQuote(Name . ": " . Value) . "`n"
		if (Body != "") {
			if !FSWrite(this.BodyPath, String(Body)) {
				this._Cleanup()
				throw Error("Could not stage the asynchronous HTTP request body.")
			}
			if this.Aborted
				return false
			Config .= "data-binary = "
				. _HTTP_CurlConfigQuote("@" . this.BodyPath) . "`n"
		}
		if !FSWrite(this.ConfigPath, Config) {
			this._Cleanup()
			throw Error("Could not stage the asynchronous HTTP request config.")
		}
		BeforeLaunchFn := this._DispatchPortFn("before_launch")
		if IsObject(BeforeLaunchFn)
			BeforeLaunchFn.Call(this)
		if this.Aborted
			return false

		SpawnFn := this._DispatchPortFn("spawn")
		Handle := IsObject(SpawnFn)
			? SpawnFn.Call(CurlExe, ["--config", this.ConfigPath],
				ObjBindMethod(this, "_OnDone"), 0, 0, HTTP_CURL_MAX_RESPONSE_BYTES)
			: ShellRunner_SpawnTreeOwned(CurlExe,
				["--config", this.ConfigPath], ObjBindMethod(this, "_OnDone"), 0, 0,
				HTTP_CURL_MAX_RESPONSE_BYTES)
		this.Handle := Handle
		if this.Aborted {
			if IsObject(Handle)
				try Handle.terminate()
			this.Handle := 0
			return false
		}
		Started := IsObject(Handle) && Handle.start()
		if this.Aborted
			return false
		if !Started {
			if this.Aborted
				return false
			this.Handle := 0
			this.Completed := true
			this._Cleanup()
			throw Error("Could not launch the asynchronous HTTP child.")
		}
		return true
	}

	_DispatchPortFn(Name) {
		if !(this.DispatchPort is Map) || !this.DispatchPort.Has(Name)
			return 0
		Fn := this.DispatchPort[Name]
		if !IsObject(Fn)
			throw TypeError("CurlAsyncRequest dispatch port entry must be callable.", -1, Name)
		return Fn
	}

	WaitForResponse(TimeoutSeconds := 0) {
		return this.Completed
	}

	GetResponseHeader(Name) {
		return this.ResponseHeaders.Get(StrLower(String(Name)), "")
	}

	Abort() {
		if this.Completed
			return true
		this.Aborted := true
		Succeeded := true
		Handle := this.Handle
		this.Handle := 0
		if IsObject(Handle) {
			try Succeeded := Handle.terminate()
			catch
				Succeeded := false
		}
		this.Completed := true
		this._Cleanup()
		return Succeeded
	}

	_OnDone(ExitCode, Stdout, Stderr) {
		global HTTP_CURL_MAX_HEADER_BYTES
		if this.Completed
			return
		this.Handle := 0
		HeaderText := ""
		HeaderOversize := false
		try {
			HeaderBytes := FileGetSize(this.HeaderPath)
			if (HeaderBytes > HTTP_CURL_MAX_HEADER_BYTES) {
				HeaderOversize := true
				try LoggerError("HttpClient",
					"Curl response headers exceeded the {1}-byte ceiling; response was rejected.",
					HTTP_CURL_MAX_HEADER_BYTES)
			} else {
				HeaderText := FileRead(this.HeaderPath, "UTF-8-RAW")
			}
		}
		Parsed := _HTTP_CurlParseHeaders(HeaderText)
		BeforePublishFn := this._DispatchPortFn("before_response_publish")
		if IsObject(BeforePublishFn)
			BeforePublishFn.Call(this)
		PreviousCritical := Critical("On")
		try {
			if this.Completed || this.Aborted
				return
			if (ExitCode == 0 && !HeaderOversize) {
				this.Status := Parsed["status"]
				this.ResponseHeaders := Parsed["headers"]
				this.ResponseText := Stdout
			}
			this.Completed := true
		} finally {
			Critical(PreviousCritical)
		}
		this._Cleanup()
	}

	_Cleanup() {
		Failed := false
		for Path in [this.ConfigPath, this.BodyPath, this.HeaderPath]
			try {
				if !FSDelete(Path)
					Failed := true
			} catch {
				Failed := true
			}
		if Failed {
			if !this.CleanupPending {
				this.CleanupPending := true
				try LoggerWarn("HttpClient",
					"Deferring curl artifact cleanup until the temporary file lock is released.")
			}
			_HTTP_CurlRetainCleanupDebt(this)
			return false
		}
		if this.CleanupPending {
			this.CleanupPending := false
			_HTTP_CurlReleaseCleanupDebt(this)
			try LoggerInfo("HttpClient", "Deferred curl artifact cleanup completed.")
		}
		return true
	}
}




; =======================================================
; =======================================================
; ======= 2/ Adapter Methods ============================
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
