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
; Requests whose curl child refused termination. The request object and exact
; ShellRunner handle must survive callers that drop their local reference.
global _HTTP_CURL_ABORT_DEBTS := Map()
global _HTTP_CURL_ABORT_TIMER := 0
; curl.exe ignores the Windows (WinINet) proxy that browsers and WebView2 use,
; so a proxy-only corporate network saw every curl request fail while GitHub
; worked in the browser. Mirrors release_sources.proxy_resolve_timeout_sec in
; _shared/modules/updater/defaults.json (pinned by the JS drift gate).
global SYSTEM_PROXY_RESOLVE_TIMEOUT_MS := 10000
; PAC answers resolved this session, keyed by lower-case host ("" = direct).
global _SYSTEM_PROXY_PAC_CACHE := Map()
; Every waiter of the in-flight PAC resolution (0 = none running).
global _SYSTEM_PROXY_PAC_PENDING := 0




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

_HTTP_CurlSweepOrphans(Directory := A_Temp) {
	CurrentPid := DllCall("Kernel32\GetCurrentProcessId", "UInt")
	Loop Files Directory . "\ergopti_http_*.*", "F" {
		if !RegExMatch(A_LoopFileName,
				"^ergopti_http_([1-9]\d{0,9})_\d+\.(?:conf|body|headers)$", &Match)
			continue
		OwnerPid := Integer(Match[1])
		; Reject invalid ownership before liveness checks or age-based cleanup.
		if OwnerPid > 0xFFFFFFFF
			continue
		OwnerAlive := false
		if (OwnerPid == CurrentPid)
			OwnerAlive := true
		else
			try OwnerAlive := ProcessExist(OwnerPid) == OwnerPid
		; Active requests and deferred cleanup debts retain their files even
		; across clock changes. Only the owning request may retire them early.
		if !OwnerAlive
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

_HTTP_CurlRetainAbortDebt(Request) {
	global _HTTP_CURL_ABORT_DEBTS, _HTTP_CURL_ABORT_TIMER
	global HTTP_CURL_CLEANUP_RETRY_MS
	IsNewDebt := !_HTTP_CURL_ABORT_DEBTS.Has(Request.CleanupDebtId)
	_HTTP_CURL_ABORT_DEBTS[Request.CleanupDebtId] := Request
	if IsNewDebt
		try LoggerWarn("HttpClient",
			"Curl child termination was refused; retaining the exact request for retry.")
	if IsObject(_HTTP_CURL_ABORT_TIMER)
		return true
	RetryFn := _HTTP_CurlRetryDeferredAborts
	_HTTP_CURL_ABORT_TIMER := RetryFn
	try {
		SetTimer(RetryFn, -HTTP_CURL_CLEANUP_RETRY_MS)
		return true
	} catch as Err {
		_HTTP_CURL_ABORT_TIMER := 0
		try LoggerError("HttpClient",
			"Could not schedule deferred curl termination retry: {1}.", Err.Message)
		return false
	}
}

_HTTP_CurlReleaseAbortDebt(Request) {
	global _HTTP_CURL_ABORT_DEBTS
	if _HTTP_CURL_ABORT_DEBTS.Has(Request.CleanupDebtId)
		_HTTP_CURL_ABORT_DEBTS.Delete(Request.CleanupDebtId)
}

_HTTP_CurlRetryDeferredAborts(*) {
	global _HTTP_CURL_ABORT_DEBTS, _HTTP_CURL_ABORT_TIMER
	_HTTP_CURL_ABORT_TIMER := 0
	Pending := []
	for _, Request in _HTTP_CURL_ABORT_DEBTS
		Pending.Push(Request)
	for Request in Pending
		Request.Abort()
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
		this.Proxy := ""
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

	; Routes the request through an explicit proxy URL ("" = direct). Proxy
	; authentication uses the signed-in Windows account (SSPI), like a browser.
	SetProxy(Proxy) {
		if !(Proxy is String) || (Proxy != "" && !SystemProxy_IsValidProxyUrl(Proxy))
			throw ValueError("HTTP proxy must be an http, https or socks URL.")
		this.Proxy := Proxy
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
		; Schannel treats an unreachable revocation server as a TLS failure. A
		; corporate TLS-inspection CA often publishes none reachable from the
		; client, so check revocation best-effort, as browsers do.
		Config .= "ssl-revoke-best-effort`n"
		if (this.Proxy != "") {
			Config .= "proxy = " . _HTTP_CurlConfigQuote(this.Proxy) . "`n"
			Config .= "proxy-anyauth`n"
			Config .= "proxy-user = " . _HTTP_CurlConfigQuote(":") . "`n"
		}
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
			; Abort may have run while spawn() was still constructing this handle and
			; therefore observed no child. Re-open only the terminal bit, then retire
			; the newly returned exact handle through the normal debt-aware path.
			this.Completed := false
			this.Abort()
			return false
		}
		Started := false
		try Started := IsObject(Handle) && Handle.start()
		catch as StartErr {
			; start() may have admitted a process before reporting failure. Preserve
			; the exact handle if compensating termination is refused.
			this.Aborted := true
			this.Abort()
			throw StartErr
		}
		if this.Aborted
			return false
		if !Started {
			this.Aborted := true
			this.Abort()
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
		if this.Completed {
			_HTTP_CurlReleaseAbortDebt(this)
			return true
		}
		this.Aborted := true
		Succeeded := true
		Handle := this.Handle
		if IsObject(Handle) {
			try Succeeded := Handle.terminate()
			catch
				Succeeded := false
		}
		; terminate() may pump the completion callback. If it already proved the
		; child terminal, that callback owns cleanup and debt release.
		if this.Completed {
			_HTTP_CurlReleaseAbortDebt(this)
			return true
		}
		if !Succeeded {
			this.Handle := Handle
			_HTTP_CurlRetainAbortDebt(this)
			return false
		}
		this.Handle := 0
		this.Completed := true
		_HTTP_CurlReleaseAbortDebt(this)
		this._Cleanup()
		return true
	}

	_OnDone(ExitCode, Stdout, Stderr) {
		global HTTP_CURL_MAX_HEADER_BYTES
		; A failed Abort retains the child until either a retry succeeds or its
		; natural completion callback proves it terminal. Claim the latter without
		; materializing response artifacts that cancellation will discard.
		AbortedCompletion := false
		PreviousCritical := Critical("On")
		try {
			if this.Completed
				return
			if this.Aborted {
				this.Handle := 0
				this.Completed := true
				AbortedCompletion := true
			}
		} finally {
			Critical(PreviousCritical)
		}
		if AbortedCompletion {
			_HTTP_CurlReleaseAbortDebt(this)
			this._Cleanup()
			return
		}
		if this.Completed
			return
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
		DiscardedCompletion := false
		PreviousCritical := Critical("On")
		try {
			if this.Completed
				return
			this.Handle := 0
			if this.Aborted {
				DiscardedCompletion := true
			} else if (ExitCode == 0 && !HeaderOversize) {
				this.Status := Parsed["status"]
				this.ResponseHeaders := Parsed["headers"]
				this.ResponseText := Stdout
			}
			this.Completed := true
		} finally {
			Critical(PreviousCritical)
		}
		if DiscardedCompletion
			_HTTP_CurlReleaseAbortDebt(this)
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
; ======= 2/ System Proxy ===============================
; =======================================================
; =======================================================

; Returns whether a proxy URL is one curl accepts in its config file.
SystemProxy_IsValidProxyUrl(Url) {
	return (Url is String)
		&& RegExMatch(Url, "i)^(https?|socks4a?|socks5h?)://[A-Za-z0-9._-]+(:\d{1,5})?$") > 0
}

; Reads the signed-in user's Windows proxy settings (the WinINet settings that
; Edge, WebView2 and Internet Options share). Returns a Map with auto_detect,
; pac_url, proxy and bypass. A user without saved settings has none.
SystemProxy_ReadIEConfig() {
	Buf := Buffer(A_PtrSize * 4, 0)
	if !DllCall("winhttp\WinHttpGetIEProxyConfigForCurrentUser", "Ptr", Buf, "Int") {
		LastError := A_LastError
		if (LastError == 2)
			return Map("auto_detect", false, "pac_url", "", "proxy", "", "bypass", "")
		throw OSError(LastError, -1, "WinHttpGetIEProxyConfigForCurrentUser")
	}
	Config := Map("auto_detect", NumGet(Buf, 0, "Int") != 0)
	; BOOL is padded to pointer alignment, so the strings follow at pointer strides.
	for Index, Name in ["pac_url", "proxy", "bypass"] {
		Ptr := NumGet(Buf, A_PtrSize * Index, "Ptr")
		Config[Name] := Ptr ? StrGet(Ptr, "UTF-16") : ""
		if Ptr
			DllCall("GlobalFree", "Ptr", Ptr, "Ptr")
	}
	return Config
}

; Returns the scheme and lower-case host of an absolute http(s) URL.
_SystemProxy_UrlParts(Url) {
	if !(Url is String) || !RegExMatch(Url, "i)^(https?)://([A-Za-z0-9.-]+)(?::\d+)?(?:[/?#]|$)", &M)
		throw ValueError("System proxy selection requires an absolute http(s) URL.", -1, Url)
	return Map("scheme", StrLower(M[1]), "host", StrLower(M[2]))
}

; Adds the scheme WinINet omits ("host:port" means an HTTP proxy) and
; validates the result. Returns "" for an entry curl could not use.
_SystemProxy_NormalizeEndpoint(Endpoint, DefaultScheme) {
	Endpoint := RegExReplace(Trim(Endpoint), "/+$")
	if !RegExMatch(Endpoint, "i)^[a-z0-9]+://")
		Endpoint := DefaultScheme . "://" . Endpoint
	if SystemProxy_IsValidProxyUrl(Endpoint)
		return Endpoint
	try LoggerWarn("HttpClient", "Ignoring a system proxy entry curl cannot use.")
	return ""
}

; Selects the proxy for one scheme from a WinINet proxy list: either one
; "host:port" for every scheme or "http=h:p;https=h:p;socks=h:p".
SystemProxy_ParseProxyList(List, Scheme) {
	Generic := ""
	Specific := ""
	Socks := ""
	for Entry in StrSplit(Trim(List), [";", " "]) {
		Entry := Trim(Entry)
		if (Entry == "")
			continue
		if RegExMatch(Entry, "^([A-Za-z]+)=(.+)$", &M) {
			Key := StrLower(M[1])
			if (Key == Scheme)
				Specific := M[2]
			else if (Key == "socks")
				Socks := M[2]
		} else if (Generic == "") {
			Generic := Entry
		}
	}
	Chosen := (Specific != "") ? Specific : Generic
	if (Chosen != "")
		return _SystemProxy_NormalizeEndpoint(Chosen, "http")
	if (Socks != "")
		return _SystemProxy_NormalizeEndpoint(Socks, "socks4a")
	return ""
}

; Applies the WinINet bypass list: "<local>" matches dot-less hosts and "*"
; is a wildcard, both case-insensitive.
SystemProxy_IsBypassed(Bypass, Host) {
	Host := StrLower(Host)
	for Pattern in StrSplit(Bypass, [";", " ", ","]) {
		Pattern := StrLower(Trim(Pattern))
		if (Pattern == "")
			continue
		if (Pattern == "<local>") {
			if !InStr(Host, ".")
				return true
			continue
		}
		Pattern := RegExReplace(Pattern, "^[a-z]+://")
		Rx := "^" . StrReplace(RegExReplace(Pattern, "[.+?^$(){}\[\]|\\]", "\$0"), "*", ".*") . "$"
		if RegExMatch(Host, Rx)
			return true
	}
	return false
}

; Static selection for one URL. "pac" reports that a PAC script governs the
; URL; its answer then overrides the static proxy once resolved.
SystemProxy_SelectStatic(Config, Url) {
	Parts := _SystemProxy_UrlParts(Url)
	Proxy := ""
	if (Config["proxy"] != "" && !SystemProxy_IsBypassed(Config["bypass"], Parts["host"]))
		Proxy := SystemProxy_ParseProxyList(Config["proxy"], Parts["scheme"])
	return Map("proxy", Proxy, "pac", Config["pac_url"] != "")
}

; Reads the settings, logging and degrading to a direct connection when the
; OS refuses them.
_SystemProxy_Config(ReaderFn := 0) {
	try return IsObject(ReaderFn) ? ReaderFn.Call() : SystemProxy_ReadIEConfig()
	catch as Err {
		try LoggerWarn("HttpClient", "Windows proxy settings unreadable ({1}); connecting directly.", Err.Message)
		return Map("auto_detect", false, "pac_url", "", "proxy", "", "bypass", "")
	}
}

; Best proxy known now for Url without waiting: a PAC answer already resolved
; this session, otherwise the static setting. A PAC script not yet evaluated
; for the host is resolved in the background for the next request.
SystemProxy_ForUrl(Url, ReaderFn := 0, SpawnFn := 0) {
	global _SYSTEM_PROXY_PAC_CACHE
	; WinINet proxies only govern http(s); any other scheme connects as given.
	if !(Url is String) || !RegExMatch(Url, "i)^https?://")
		return ""
	Selection := SystemProxy_SelectStatic(_SystemProxy_Config(ReaderFn), Url)
	Host := _SystemProxy_UrlParts(Url)["host"]
	if !Selection["pac"]
		return Selection["proxy"]
	if _SYSTEM_PROXY_PAC_CACHE.Has(Host)
		return _SYSTEM_PROXY_PAC_CACHE[Host]
	SystemProxy_ResolveAsync([Url], (*) => 0, ReaderFn, SpawnFn)
	return Selection["proxy"]
}

; Resolves the proxy of every URL, running the configured PAC script when one
; governs them, then calls Callback(Map url -> proxy) exactly once. PAC is
; evaluated by .NET in a tree-owned PowerShell child bounded by
; SYSTEM_PROXY_RESOLVE_TIMEOUT_MS, so the keyboard thread never waits on the
; PAC download. A failed resolution is logged and keeps the static selection.
; Automatic detection (WPAD) alone is not probed: it is Windows' default on
; home machines, where it would cost a child process for a direct answer.
SystemProxy_ResolveAsync(Urls, Callback, ReaderFn := 0, SpawnFn := 0) {
	global _SYSTEM_PROXY_PAC_CACHE, _SYSTEM_PROXY_PAC_PENDING
	Config := _SystemProxy_Config(ReaderFn)
	Result := Map()
	Missing := []
	for Url in Urls {
		Selection := SystemProxy_SelectStatic(Config, Url)
		Result[Url] := Selection["proxy"]
		if !Selection["pac"]
			continue
		Host := _SystemProxy_UrlParts(Url)["host"]
		if _SYSTEM_PROXY_PAC_CACHE.Has(Host)
			Result[Url] := _SYSTEM_PROXY_PAC_CACHE[Host]
		else
			Missing.Push(Url)
	}
	if (Missing.Length == 0) {
		Callback.Call(Result)
		return true
	}
	Waiter := { Urls: Urls, Result: Result, Callback: Callback }
	if IsObject(_SYSTEM_PROXY_PAC_PENDING) {
		_SYSTEM_PROXY_PAC_PENDING.Waiters.Push(Waiter)
		return true
	}
	Origins := []
	for Url in Missing
		Origins.Push("https://" . _SystemProxy_UrlParts(Url)["host"] . "/")
	PacRun := { Origins: Origins, Waiters: [Waiter], Handle: 0, Done: false }
	_SYSTEM_PROXY_PAC_PENDING := PacRun
	try LoggerStart("HttpClient", "Resolving the Windows PAC proxy for {1} host(s)…", Origins.Length)
	Script := "$w=[System.Net.WebRequest]::GetSystemWebProxy();"
	for Origin in Origins
		Script .= "[Console]::Out.WriteLine($w.GetProxy([Uri]'" . Origin . "').AbsoluteUri);"
	Exe := A_WinDir . "\System32\WindowsPowerShell\v1.0\powershell.exe"
	Args := ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", Script]
	OnDone := _SystemProxy_FinishPac.Bind(PacRun)
	try {
		PacRun.Handle := IsObject(SpawnFn)
			? SpawnFn.Call(Exe, Args, OnDone)
			: ShellRunner_SpawnTreeOwned(Exe, Args, OnDone, 0, 0, 65536)
		if !(IsObject(PacRun.Handle) && PacRun.Handle.start())
			throw Error("the PowerShell child did not start")
	} catch as Err {
		_SystemProxy_FinishPac(PacRun, -1, "", "spawn failed: " . Err.Message)
		return true
	}
	SetTimer(_SystemProxy_PacDeadline.Bind(PacRun), -SYSTEM_PROXY_RESOLVE_TIMEOUT_MS)
	return true
}

_SystemProxy_PacDeadline(PacRun) {
	if PacRun.Done
		return
	try PacRun.Handle.terminate()
	catch as Err
		try LoggerWarn("HttpClient", "The timed-out PAC resolver could not be terminated: {1}.", Err.Message)
	_SystemProxy_FinishPac(PacRun, -1, "", "timed out after " . SYSTEM_PROXY_RESOLVE_TIMEOUT_MS . " ms")
}

; Completes one PAC run: caches every usable answer and releases all waiters.
_SystemProxy_FinishPac(PacRun, ExitCode, Stdout, Stderr) {
	global _SYSTEM_PROXY_PAC_CACHE, _SYSTEM_PROXY_PAC_PENDING
	if PacRun.Done
		return
	PacRun.Done := true
	if (_SYSTEM_PROXY_PAC_PENDING == PacRun)
		_SYSTEM_PROXY_PAC_PENDING := 0
	Lines := StrSplit(Trim(StrReplace(Stdout, "`r", ""), "`n"), "`n")
	Resolved := (ExitCode == 0 && Lines.Length == PacRun.Origins.Length)
	if Resolved {
		for Index, Origin in PacRun.Origins {
			Answer := RegExReplace(Trim(Lines[Index]), "/+$")
			if (Answer == RegExReplace(Origin, "/+$")) {
				Proxy := ""
			} else {
				Proxy := _SystemProxy_NormalizeEndpoint(Answer, "http")
				if (Proxy == "") {
					Resolved := false
					break
				}
			}
			_SYSTEM_PROXY_PAC_CACHE[_SystemProxy_UrlParts(Origin)["host"]] := Proxy
		}
	}
	if Resolved {
		try LoggerSuccess("HttpClient", "Windows PAC proxy resolved for {1} host(s).", PacRun.Origins.Length)
	} else {
		try LoggerDone("HttpClient", "Windows PAC proxy resolution failed (exit {1}: {2}); using the static proxy settings.",
			ExitCode, SubStr(Trim(Stderr), 1, 200))
	}
	for Waiter in PacRun.Waiters {
		for Url in Waiter.Urls {
			Host := _SystemProxy_UrlParts(Url)["host"]
			if _SYSTEM_PROXY_PAC_CACHE.Has(Host)
				Waiter.Result[Url] := _SYSTEM_PROXY_PAC_CACHE[Host]
		}
		try Waiter.Callback.Call(Waiter.Result)
		catch as Err
			LoggerError("HttpClient", "System proxy callback threw: {1}.", Err.Message)
	}
}




; =======================================================
; =======================================================
; ======= 3/ Adapter Methods ============================
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
