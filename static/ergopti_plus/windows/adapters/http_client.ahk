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
; PAC answers resolved this session, keyed by exact destination URL ("" = direct).
global _SYSTEM_PROXY_PAC_CACHE := Map()
; Every waiter of the in-flight PAC resolution (0 = none running).
global _SYSTEM_PROXY_PAC_PENDING := 0
global _SYSTEM_PROXY_PAC_CONFIG := ""




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


; Actual curl build observation runs in an exact owned Job. The owning request
; publishes this object before Start, so immediate completion cannot lose it.
_HTTP_CurlCapabilityCreate(OnReady, StartTick, TimeoutMs, TickFn := 0) {
	return CurlCapabilityAdmission(OnReady, StartTick, TimeoutMs, TickFn)
}

_HTTP_CurlRemaining(StartTick, TimeoutMs, TickFn := 0) {
	Now := IsObject(TickFn) ? TickFn.Call() : A_TickCount
	return Max(0, TimeoutMs - TickElapsed64(StartTick, Now))
}

_HTTP_CurlIntegratedProxyAuthConfig(CapabilityReceipt) {
	if !(CapabilityReceipt is Map) || CapabilityReceipt.Get("schema_version", 0) != 1
		return ""
	Quiesced := CapabilityReceipt.Get("child_quiesced", false)
	if !(Quiesced is Integer) || Quiesced != true
		return ""
	if CapabilityReceipt.Get("state", "") != "ready"
		|| CapabilityReceipt.Get("backend", "") != "curl"
		return ""
	Capability := CapabilityReceipt.Get("capability", 0)
	if !(Capability is Map) || Capability.Get("tls_backend", "") != "schannel"
		return ""
	Sspi := Capability.Get("sspi", false)
	Spnego := Capability.Get("spnego", false)
	if !(Sspi is Integer) || Sspi != true || !(Spnego is Integer) || Spnego != true
		return ""
	; curl's CLI cannot encode a Negotiate|NTLM-only auth mask. Negotiate
	; permits the current user's SSPI Negotiate package; no ANYAUTH downgrade.
	return "proxy-negotiate`nproxy-user = " . _HTTP_CurlConfigQuote(":") . "`n"
}

class CurlCapabilityAdmission {
	__New(OnReady, StartTick, TimeoutMs, TickFn := 0) {
		this.OnReady := OnReady
		this.StartTick := StartTick
		this.TimeoutMs := TimeoutMs
		this.TickFn := TickFn
		this.Handle := 0
		this.Capture := 0
		this.Started := false
		this.Completed := false
		this.Cancelled := false
		this.Published := false
		this.DeadlineFn := ObjBindMethod(this, "_Deadline")
		this.RetireFn := ObjBindMethod(this, "Abort")
	}

	Remaining() {
		return _HTTP_CurlRemaining(this.StartTick, this.TimeoutMs, this.TickFn)
	}

	Start() {
		global _VendorDir
		if this.Started || this.Completed || this.Cancelled
			return false
		this.Started := true
		try {
			Remaining := this.Remaining()
			if Remaining <= 0 {
				this.Completed := true
				this._ReleaseTimers()
				this._Publish(0)
				return true
			}
			Directory := _SR_AcquireCaptureDirectory()
			this.Capture := Map("TmpFile", Directory . "output.tmp", "CaptureDir", Directory)
			if !FSWrite(this.Capture["TmpFile"], '{"schema_version":1,"budget_ms":' . Remaining . '}')
				throw Error("Capability input could not be staged.")
			if this.Cancelled
				return this.Abort()
			this.Handle := ShellRunner_SpawnTreeOwned(
				A_WinDir . "\System32\WindowsPowerShell\v1.0\powershell.exe",
				["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
					_VendorDir . "\ergopti_curl_capabilities_worker.ps1", "-InputPath", this.Capture["TmpFile"]],
				ObjBindMethod(this, "_OnDone"), 0, 0, 8192)
			if this.Cancelled
				return this.Abort()
			if !(IsObject(this.Handle) && this.Handle.start())
				throw Error("Capability worker could not start.")
			if !this.Completed && !this.Cancelled
				SetTimer(this.DeadlineFn, -Max(1, this.Remaining()))
			return true
		} catch {
			; No native exception, environment or version output reaches logging.
			this._Publish(0)
			this.Cancel()
			return true
		}
	}

	_Publish(Receipt) {
		if this.Published || this.Cancelled
			return false
		this.Published := true
		Callback := this.OnReady
		this.OnReady := 0
		try Callback.Call(this, Receipt)
		catch {
			try LoggerError("HttpClient", "Curl capability continuation failed.")
		}
		return true
	}

	_OnDone(Code, Out, Err) {
		if this.Completed
			return
		; ShellRunner only dispatches tree completion after zero Job accounting.
		this.Completed := true
		this.Handle := 0
		this._ReleaseTimers()
		_SystemProxy_CleanupInput(this)
		if this.Cancelled
			return
		Receipt := 0
		if Code == 0 && Err == "" && StrLen(Out) <= 8192 && this.Remaining() > 0 {
			try Receipt := JsonParse(Out)
			catch
				Receipt := 0
		}
		this._Publish(Receipt)
	}

	_Deadline(*) {
		if this.Completed || this.Cancelled
			return
		Remaining := this.Remaining()
		if this.Completed || this.Cancelled
			return
		if Remaining > 0 {
			if IsObject(this.DeadlineFn)
				SetTimer(this.DeadlineFn, -Remaining)
			return
		}
		this._Publish(0)
		this.Cancel()
	}

	Cancel(*) {
		global HTTP_CURL_CLEANUP_RETRY_MS
		this.Cancelled := true
		this.OnReady := 0
		if IsObject(this.DeadlineFn) {
			SetTimer(this.DeadlineFn, 0)
			this.DeadlineFn := 0
		}
		if this.Completed
			return _SystemProxy_CleanupInput(this)
		; Cancellation is reached from the input hook. Physical termination runs
		; in a timer; the bound object retains the exact child and cleanup debt.
		SetTimer(this.RetireFn, -HTTP_CURL_CLEANUP_RETRY_MS)
		return true
	}

	Abort(*) {
		global HTTP_CURL_CLEANUP_RETRY_MS
		this.Cancelled := true
		this.OnReady := 0
		if IsObject(this.Handle) && !IsObject(this.RetireFn)
			this.RetireFn := ObjBindMethod(this, "Abort")
		RetireFn := this.RetireFn
		if IsObject(this.DeadlineFn) {
			SetTimer(this.DeadlineFn, 0)
			this.DeadlineFn := 0
		}
		Retired := !IsObject(this.Handle)
		if !Retired
			try Retired := this.Handle.terminate() == true
			catch
				Retired := false
		if !Retired {
			SetTimer(RetireFn, -HTTP_CURL_CLEANUP_RETRY_MS)
			return false
		}
		this.Handle := 0
		this.Completed := true
		this._ReleaseTimers()
		return _SystemProxy_CleanupInput(this)
	}

	_ReleaseTimers() {
		for Name in ["DeadlineFn", "RetireFn"] {
			Fn := this.%Name%
			if IsObject(Fn)
				SetTimer(Fn, 0)
			this.%Name% := 0
		}
	}
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
		this.ProxySelected := false
		this.ProxyResolver := 0
		this.ProxySelection := 0
		this.CapabilityOwner := 0
		this.ManagedRouting := false
		this.ManagedTransport := false
		this.ManagedOwnerCurrent := 0
		this.ManagedSettingsReader := 0
		this.ManagedCapture := 0
		this.ManagedAdmissionFn := 0
		this.ManagedTransportImage := ""
		this.ManagedPayloadPublished := false
		this.NativeReceipt := Map()
		this.RevocationBestEffort := true
		this.SendStarted := false
		this.DeadlineStart := 0
		this.DeadlineTimeout := 0
		this.DeadlineFn := 0
		; "" = the body arrives on stdout as ResponseText (see SetOutputFile).
		this.OutputPath := ""
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
		this.ProxySelected := true
	}

	; A readiness owner supplies its original deadline and actual resolver.
	; SetProxy alone remains an explicit fixed-route compatibility API.
	; Actual production routes and transport share one request-owned Job. The
	; legacy fixed-route/fake-port surface remains available to its explicit owner.
	SetManagedRouting(SettingsReader := 0, OwnerCurrent := 0) {
		if this.SendStarted
			throw Error("Managed routing must be configured before dispatch.")
		this.ManagedRouting := true
		this.ManagedSettingsReader := SettingsReader
		this.ManagedOwnerCurrent := OwnerCurrent
	}

	_ManagedIsLive() {
		if this.Completed || this.Aborted || A_IsSuspended || this._Remaining() <= 0
			return false
		Current := true
		try {
			if IsObject(this.ManagedOwnerCurrent)
				Current := this.ManagedOwnerCurrent.Call() == true
		} catch {
			Current := false
		}
		; A captured owner check may itself reenter cancellation. Recheck the
		; facade and the original clock after it returns, before any effect.
		return Current && !this.Completed && !this.Aborted && !A_IsSuspended && this._Remaining() > 0
	}

	_SendManaged(Body) {
		global _VendorDir, _SharedDir, HTTP_CURL_MAX_RESPONSE_BYTES, HTTP_CURL_MAX_HEADER_BYTES
		this.ManagedTransport := true
		Directory := _SR_AcquireCaptureDirectory()
		this.ManagedCapture := Map("TmpFile", Directory . "request.json", "CaptureDir", Directory)
		Input := '{"schema_version":1,"budget_ms":' . this._Remaining()
		Input .= ',"started_tick":' . this.DeadlineStart . ',"deadline_ms":' . this.DeadlineTimeout
		Input .= ',"url":' . JsonStringLiteral(this.Url) . ',"method":' . JsonStringLiteral(this.Method)
		this.ManagedTransportImage := '{"schema_version":1,"request_id":' . JsonStringLiteral(this.CleanupDebtId)
		this.ManagedTransportImage .= ',"body":' . JsonStringLiteral(String(Body)) . ',"headers":['
		HeaderIndex := 0
		for Name, Value in this.Headers
			this.ManagedTransportImage .= (HeaderIndex++ > 0 ? "," : "") . '{"name":' . JsonStringLiteral(Name)
				. ',"value":' . JsonStringLiteral(Value) . '}'
		this.ManagedTransportImage .= ']}'
		Input .= ',"body":"","headers":[],"request_id":' . JsonStringLiteral(this.CleanupDebtId)
		Input .= ',"response_path":' . JsonStringLiteral(this.OutputPath != "" ? this.OutputPath : this.BodyPath)
		Input .= ',"header_path":' . JsonStringLiteral(this.HeaderPath)
		Input .= ',"policy_path":' . JsonStringLiteral(_SharedDir . "\modules\network\proxy_policy.json")
		Input .= ',"defaults_path":' . JsonStringLiteral(_SharedDir . "\modules\updater\defaults.json")
		Input .= ',"route_path":' . JsonStringLiteral(_VendorDir . "\ergopti_network_routes.ps1")
		Input .= ',"capability_path":' . JsonStringLiteral(_VendorDir . "\ergopti_curl_capabilities_worker.ps1")
		Input .= ',"max_response_bytes":' . HTTP_CURL_MAX_RESPONSE_BYTES
		Input .= ',"max_header_bytes":' . HTTP_CURL_MAX_HEADER_BYTES
		Input .= ',"connect_timeout_ms":' . this.ConnectTimeoutMs
		Input .= ',"revocation_best_effort":' . (this.RevocationBestEffort ? "true" : "false")
		if !this.ManagedRouting && this.ProxySelected
			Input .= ',"fixed_proxy":' . JsonStringLiteral(this.Proxy)
		if IsObject(this.ManagedSettingsReader) {
			Settings := this.ManagedSettingsReader.Call()
			if !(Settings is Map)
				throw TypeError("The native settings test reader must return its exact configuration map.")
			Input .= ',"settings_override":{"Ok":true,"Absent":false,"NativeError":0,"FailureOrigin":""'
			Input .= ',"AutoDetect":' . (Settings.Get("auto_detect", false) ? "true" : "false")
			Input .= ',"PacUrl":' . JsonStringLiteral(Settings["pac_url"])
			Input .= ',"Proxy":' . JsonStringLiteral(Settings["proxy"])
			Input .= ',"Bypass":' . JsonStringLiteral(Settings["bypass"]) . '}'
		}
		Input .= '}'
		if !this._ManagedIsLive()
			return this.Abort()
		if !FSWrite(this.ManagedCapture["TmpFile"], Input)
			throw Error("The exact managed request input could not be staged.")
		if !this._ManagedIsLive() {
			this._Cleanup()
			return false
		}
		BeforeLaunch := this._DispatchPortFn("before_launch")
		if IsObject(BeforeLaunch)
			BeforeLaunch.Call(this)
		if !this._ManagedIsLive() {
			this._Cleanup()
			return false
		}
		Executable := A_WinDir . "\System32\WindowsPowerShell\v1.0\powershell.exe"
		Args := ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
			_VendorDir . "\ergopti_managed_curl_worker.ps1", "-InputPath", this.ManagedCapture["TmpFile"]]
		SpawnFn := this._DispatchPortFn("spawn")
		Handle := IsObject(SpawnFn)
			? SpawnFn.Call(Executable, Args, ObjBindMethod(this, "_OnManagedDone"), 0, 0, 8192)
			: ShellRunner_SpawnTreeOwned(Executable, Args, ObjBindMethod(this, "_OnManagedDone"), 0, 0, 8192)
		this.Handle := Handle
		if !this._ManagedIsLive() {
			this.Completed := false
			this.Abort()
			return false
		}
		Started := IsObject(Handle) && Handle.start()
		if !Started {
			this.Abort()
			throw Error("The exact managed request Job did not start.")
		}
		if this._ManagedIsLive() {
			this.ManagedAdmissionFn := ObjBindMethod(this, "_PollManagedAdmission")
			SetTimer(this.ManagedAdmissionFn, -1)
		}
		return true
	}

	_PollManagedAdmission() {
		global HTTP_CURL_CLEANUP_RETRY_MS
		if this.Completed || this.Aborted || this.ManagedPayloadPublished
			return
		if !this._ManagedIsLive()
			return this.Abort()
		try {
			Directory := this.ManagedCapture["CaptureDir"]
			AckPath := Directory . "admission.json"
			if !FileExist(AckPath) {
				SetTimer(this.ManagedAdmissionFn, -Min(HTTP_CURL_CLEANUP_RETRY_MS, Max(1, this._Remaining())))
				return
			}
			if FileGetSize(AckPath) > 8192
				throw Error("Native managed admission exceeded its private bound.")
			Ack := JsonParse(FileRead(AckPath, "UTF-8"))
			if !(Ack is Map) || Ack.Get("schema_version", 0) != 1 || Ack.Get("request_id", "") != this.CleanupDebtId
					|| Ack.Get("state", "") != "ready" || Ack.Get("tls_backend", "") != "schannel"
					|| !(Ack.Get("child_quiesced", false) is Integer) || Ack["child_quiesced"] != true
				throw Error("The exact request's native capability admission was refused.")
			if !this._ManagedIsLive()
				return this.Abort()
			; Reserve once before filesystem calls can pump this timer again. Only
			; a capability receipt from this exact live Job admits secret staging.
			this.ManagedPayloadPublished := true
			PayloadImage := this.ManagedTransportImage
			StagedPath := Directory . "transport.pending"
			if !FSWrite(StagedPath, PayloadImage)
				throw Error("The exact admitted transport input could not be staged.")
			PreviousCritical := Critical("On")
			try {
				if !this._ManagedIsLive()
					throw Error("Native transport input lost its live admission before publication.")
				if !DllCall("Kernel32\MoveFileW", "WStr", StagedPath, "WStr", Directory . "transport.json", "Int")
					throw Error("The exact private transport input could not be published.")
			} finally Critical(PreviousCritical)
			this._StopManagedAdmission()
		} catch {
			this.Abort()
		}
	}

	_StopManagedAdmission() {
		if IsObject(this.ManagedAdmissionFn)
			SetTimer(this.ManagedAdmissionFn, 0)
		this.ManagedAdmissionFn := 0
		this.ManagedTransportImage := ""
	}

	_OnManagedDone(ExitCode, Stdout, Stderr) {
		global HTTP_CURL_MAX_RESPONSE_BYTES
		if this.Completed
			return
		this._StopManagedAdmission()
		; ShellRunner dispatches this callback only after the exact Job reaches
		; zero accounting. A late terminal never revives expired work.
		if !this._ManagedIsLive() {
			this.Aborted := true
			return this._OnDone(-1, "", "")
		}
		Body := ""
		Valid := false
		try {
			Receipt := JsonParse(Stdout)
			if Receipt is Map && Receipt.Get("schema_version", 0) == 1
					&& Receipt.Get("child_quiesced", false) is Integer
					&& Receipt["child_quiesced"] == true {
				this.NativeReceipt := Receipt.Get("receipt", Map())
				Valid := ExitCode == 0 && Stderr == "" && Receipt.Get("ok", false) == true
					&& Receipt.Get("status", 0) is Integer && Receipt["status"] >= 100 && Receipt["status"] <= 599
				if Valid && this.OutputPath == "" {
					if FileGetSize(this.BodyPath) > HTTP_CURL_MAX_RESPONSE_BYTES
						throw Error("The managed response exceeded the canonical byte bound.")
					Body := FileRead(this.BodyPath, "UTF-8-RAW")
				}
			}
		} catch {
			Valid := false
		}
		return this._OnDone(Valid ? 0 : -1, Body, "")
	}

	_CleanupManagedCapture() {
		if !(this.ManagedCapture is Map)
			return true
		Directory := this.ManagedCapture["CaptureDir"]
		for Name in ["capability.json", "payload.bin", "transport.conf", "admission.pending", "admission.json", "transport.pending", "transport.json"]
			if !FSDelete(Directory . Name)
				return false
		if _SR_CaptureRemove(this.ManagedCapture) != 0
			return false
		this.ManagedCapture := 0
		return true
	}

	SetDeadline(StartTick, TimeoutMs) {
		this.DeadlineStart := StartTick
		this.DeadlineTimeout := TimeoutMs
	}

	_StopDeadline() {
		if IsObject(this.DeadlineFn)
			SetTimer(this.DeadlineFn, 0)
		this.DeadlineFn := 0
	}

	SetProxyAdmission(Selection, Resolver) {
		this.ProxySelection := Selection
		this.ProxyResolver := Resolver
	}

	_Remaining() {
		return _HTTP_CurlRemaining(this.DeadlineStart, this.DeadlineTimeout)
	}

	_Deadline(*) {
		if this.Completed || this.Aborted
			return
		if this._Remaining() > 0 {
			SetTimer(this.DeadlineFn, -Max(1, this._Remaining()))
			return
		}
		this.Abort()
	}

	; Makes curl write the response body to Path, byte for byte, instead of
	; stdout: the stdout collector decodes and trims what it reads, which a
	; download verified against a checksum afterwards cannot afford. The caller
	; owns Path (ResponseText stays empty) and removes it when it is not wanted.
	SetOutputFile(Path) {
		if !(Path is String) || (Path == "") || !_HTTP_CurlScalarIsSafe(Path)
			throw ValueError("HTTP output path must be a non-empty path without control characters.")
		this.OutputPath := Path
	}

	SetTimeouts(ResolveMs, ConnectMs, SendMs, ReceiveMs) {
		this.ConnectTimeoutMs := Max(1, Integer(ResolveMs) + Integer(ConnectMs))
		this.TotalTimeoutMs := Max(1, Integer(ResolveMs) + Integer(ConnectMs)
			+ Integer(SendMs) + Integer(ReceiveMs))
	}

	Send(Body := "") {
		if (this.Method == "" || this.Url == "")
			throw Error("CurlAsyncRequest.Open must succeed before Send.")
		if this.Completed {
			if this.Aborted
				return false
			throw Error("CurlAsyncRequest.Send may run only once.")
		}
		if this.SendStarted || IsObject(this.Handle)
			throw Error("CurlAsyncRequest.Send may run only once.")
		CurlExe := A_WinDir . "\System32\curl.exe"
		if !FileExist(CurlExe)
			throw Error("The Windows curl transport is unavailable.")
		if !_HTTP_CurlRuntimeLimitSupported(CurlExe)
			throw Error("The Windows curl transport cannot enforce the live response-size limit.")
		_HTTP_CurlSweepOrphans()
		if this.Aborted
			return false
		this.SendStarted := true
		if this.DeadlineTimeout <= 0 {
			this.DeadlineStart := A_TickCount
			this.DeadlineTimeout := this.TotalTimeoutMs
		}
		if this._Remaining() <= 0
			return this.Abort()
		this.DeadlineFn := ObjBindMethod(this, "_Deadline")
		SetTimer(this.DeadlineFn, -Max(1, this._Remaining()))
		if this.ManagedRouting || !(this.DispatchPort is Map) {
			try return this._SendManaged(Body)
			catch {
				this.Abort()
				return false
			}
		}
		if this.Proxy == ""
			return this._SendCurl(Body)
		CreateFn := this._DispatchPortFn("create_curl_capability")
		if !IsObject(CreateFn)
			CreateFn := _HTTP_CurlCapabilityCreate
		Owner := CreateFn.Call(ObjBindMethod(this, "_OnCapability", Body),
			this.DeadlineStart, this.DeadlineTimeout)
		this.CapabilityOwner := Owner
		if this.Aborted || this.Completed
			return Owner.Abort()
		try Started := Owner.Start()
		catch
			Started := false
		if !Started
			this.Abort()
		return true
	}

	_OnCapability(Body, Owner, Receipt) {
		if !IsObject(this.CapabilityOwner) || ObjPtr(this.CapabilityOwner) != ObjPtr(Owner)
			return false
		this.CapabilityOwner := 0
		if this.Aborted || this.Completed || this._Remaining() <= 0
			return this.Abort()
		AuthConfig := _HTTP_CurlIntegratedProxyAuthConfig(Receipt)
		if AuthConfig == "" || !RegExMatch(this.Proxy, "i)^https?://")
			return this.Abort()
		if IsObject(this.ProxyResolver) {
			this.ProxyFreshPending := true
			try {
				if !this.ProxyResolver.Call(this.Url, ObjBindMethod(this, "_OnFreshProxy", Body, AuthConfig))
					this.Abort()
			} catch {
				this.Abort()
			}
			return true
		}
		try return this._SendCurl(Body, AuthConfig)
		catch
			return this.Abort()
	}

	_OnFreshProxy(Body, AuthConfig, Selection) {
		if !this.HasOwnProp("ProxyFreshPending") || !this.ProxyFreshPending
			return false
		this.ProxyFreshPending := false
		if this.Aborted || this.Completed || this._Remaining() <= 0
			return this.Abort()
		if !(Selection is Map) || !Selection.Get("ok", false)
			return this.Abort()
		this.ProxySelection := Selection
		this.ProxySelected := !Selection.Get("inherit", false)
		this.Proxy := this.ProxySelected ? Selection.Get("proxy", "") : ""
		if this.Proxy != "" && (!SystemProxy_IsValidProxyUrl(this.Proxy) || !RegExMatch(this.Proxy, "i)^https?://"))
			return this.Abort()
		try return this._SendCurl(Body, this.Proxy != "" ? AuthConfig : "")
		catch
			return this.Abort()
	}

	_SendCurl(Body, AuthConfig := "") {
		if this.Aborted || this.Completed || this._Remaining() <= 0
			return this.Abort()
		CurlExe := A_WinDir . "\System32\curl.exe"
		Config := "url = " . _HTTP_CurlConfigQuote(this.Url) . "`n"
		Config .= "request = " . _HTTP_CurlConfigQuote(this.Method) . "`n"
		Config .= "silent`nshow-error`n"
		Config .= "connect-timeout = " . Ceil(this.ConnectTimeoutMs / 1000) . "`n"
		Config .= "max-time = " . Format("{:.3f}", this._Remaining() / 1000) . "`n"
		Config .= "max-filesize = " . HTTP_CURL_MAX_RESPONSE_BYTES . "`n"
		Config .= "dump-header = " . _HTTP_CurlConfigQuote(this.HeaderPath) . "`n"
		Config .= "output = " . _HTTP_CurlConfigQuote(this.OutputPath != "" ? this.OutputPath : "-") . "`n"
		; Schannel treats an unreachable revocation server as a TLS failure. A
		; corporate TLS-inspection CA often publishes none reachable from the
		; client, so check revocation best-effort, as browsers do.
		Config .= "ssl-revoke-best-effort`n"
		if this.ProxySelected
			Config .= "proxy = " . _HTTP_CurlConfigQuote(this.Proxy) . "`n"
		if this.Proxy != "" {
			if AuthConfig == ""
				return this.Abort()
			Config .= AuthConfig
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
		if this.Aborted || this._Remaining() <= 0 {
			this.Abort()
			return false
		}
		if this.ProxySelection is Map {
			CurrentFn := this.ProxySelection.Get("current", 0)
			try Current := !IsObject(CurrentFn) || CurrentFn.Call()
			catch
				Current := false
			if !Current {
				if !this._Cleanup()
					return this.Abort()
				if IsObject(this.ProxyResolver) {
					this.ProxyFreshPending := true
					try {
						if !this.ProxyResolver.Call(this.Url, ObjBindMethod(this, "_OnFreshProxy", Body, AuthConfig))
							this.Abort()
					} catch
						this.Abort()
					return true
				}
				return this.Abort()
			}
		}

		SpawnFn := this._DispatchPortFn("spawn")
		Handle := IsObject(SpawnFn)
			? SpawnFn.Call(CurlExe, ["--disable", "--config", this.ConfigPath],
				ObjBindMethod(this, "_OnDone"), 0, 0, HTTP_CURL_MAX_RESPONSE_BYTES)
			: ShellRunner_SpawnTreeOwned(CurlExe,
				["--disable", "--config", this.ConfigPath], ObjBindMethod(this, "_OnDone"), 0, 0,
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
		this._StopManagedAdmission()
		if this.Completed {
			_HTTP_CurlReleaseAbortDebt(this)
			return true
		}
		this.Aborted := true
		this._StopDeadline()
		if IsObject(this.CapabilityOwner) {
			if !this.CapabilityOwner.Abort() {
				_HTTP_CurlRetainAbortDebt(this)
				return false
			}
			this.CapabilityOwner := 0
		}
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
		this._StopDeadline()
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
			if this.Aborted || (this.ManagedTransport && !this._ManagedIsLive()) {
				this.Aborted := true
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
		this.ManagedOwnerCurrent := 0
		Failed := false
		try {
			if !this._CleanupManagedCapture()
				Failed := true
		} catch {
			Failed := true
		}
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
	if !(Url is String) || !RegExMatch(Url, "i)^(https?)://(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9.-]+)(?::\d+)?(?:[/?#]|$)", &M)
		throw ValueError("System proxy selection requires an absolute http(s) URL.")
	return Map("scheme", StrLower(M[1]), "host", StrLower(Trim(M[2], "[]")))
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
SystemProxy_SelectStatic(Config, Url, IncludeAutoDetect := false) {
	Parts := _SystemProxy_UrlParts(Url)
	Proxy := ""
	if (Config["proxy"] != "" && !SystemProxy_IsBypassed(Config["bypass"], Parts["host"])) {
		Proxy := SystemProxy_ParseProxyList(Config["proxy"], Parts["scheme"])
		if IncludeAutoDetect && Proxy == ""
			throw ValueError("The system proxy configuration cannot be used by curl.")
	}
	return Map("proxy", Proxy, "pac", Config["pac_url"] != "" || (IncludeAutoDetect && Config.Get("auto_detect", false)))
}

; A relay, bypass or PAC change must invalidate earlier native selections.
_SystemProxy_RefreshCache(Config) {
	global _SYSTEM_PROXY_PAC_CACHE, _SYSTEM_PROXY_PAC_CONFIG
	Identity := Config.Get("auto_detect", false) . "`n" . Config["pac_url"]
		. "`n" . Config["proxy"] . "`n" . Config["bypass"]
	if Identity != _SYSTEM_PROXY_PAC_CONFIG {
		_SYSTEM_PROXY_PAC_CONFIG := Identity
		_SYSTEM_PROXY_PAC_CACHE := Map()
	}
	return Identity
}

; Reads the settings, logging and degrading to a direct connection when the
; OS refuses them.
_SystemProxy_Config(ReaderFn := 0, Strict := false) {
	try return IsObject(ReaderFn) ? ReaderFn.Call() : SystemProxy_ReadIEConfig()
	catch as Err {
		if Strict
			throw Err
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
	Config := _SystemProxy_Config(ReaderFn)
	_SystemProxy_RefreshCache(Config)
	Selection := SystemProxy_SelectStatic(Config, Url)
	if !Selection["pac"]
		return Selection["proxy"]
	if _SYSTEM_PROXY_PAC_CACHE.Has(Url)
		return _SYSTEM_PROXY_PAC_CACHE[Url]
	SystemProxy_ResolveAsync([Url], (*) => 0, ReaderFn, SpawnFn)
	return Selection["proxy"]
}

; Resolves the proxy of every URL, running the configured PAC script when one
; governs them, then calls Callback(Map url -> proxy) exactly once. PAC is
; evaluated in a tree-owned PowerShell child bounded by
; SYSTEM_PROXY_RESOLVE_TIMEOUT_MS, so the keyboard thread never waits on the
; PAC download. A failed resolution is logged and keeps the static selection.
; Strict admission uses documented WinHTTP receipts and resolves WPAD-only
; settings without reusing the application cache. It reports an unresolved
; receipt instead of allowing a caller to mistake static fallback for success.
SystemProxy_ResolveAsync(Urls, Callback, ReaderFn := 0, SpawnFn := 0, Strict := false, Budget := 0) {
	global _VendorDir, SYSTEM_PROXY_RESOLVE_TIMEOUT_MS
	if Strict && !(Budget is Map)
		Budget := Map("start", A_TickCount)
	global _SYSTEM_PROXY_PAC_CACHE, _SYSTEM_PROXY_PAC_PENDING
	Config := _SystemProxy_Config(ReaderFn, Strict)
	ConfigIdentity := _SystemProxy_RefreshCache(Config)
	Result := Map("_proxy_resolved", true, "_proxy_receipts", Map(), "_proxy_config_identity", ConfigIdentity)
	Missing := []
	for Url in Urls {
		Selection := SystemProxy_SelectStatic(Config, Url, Strict)
		Result[Url] := Selection["proxy"]
		Result["_proxy_receipts"][Url] := Map("source", Selection["proxy"] == "" ? "system_direct" : "system_static",
			"native_error", 0)
		if !Selection["pac"]
			continue
		if !Strict && _SYSTEM_PROXY_PAC_CACHE.Has(Url)
			Result[Url] := _SYSTEM_PROXY_PAC_CACHE[Url]
		else
			Missing.Push(Url)
	}
	if Strict && TickExpired64(Budget["start"], SYSTEM_PROXY_RESOLVE_TIMEOUT_MS) {
		Result["_proxy_resolved"] := false
		Callback.Call(Result)
		return true
	}
	if (Missing.Length == 0) {
		Callback.Call(Result)
		return true
	}
	Waiter := { Urls: Urls, Result: Result, Callback: Callback, Queued: false,
		Reader: ReaderFn, Spawn: SpawnFn, Strict: Strict, Budget: Budget }
	if IsObject(_SYSTEM_PROXY_PAC_PENDING) {
		Waiter.Queued := true
		_SYSTEM_PROXY_PAC_PENDING.Waiters.Push(Waiter)
		return true
	}
	PacRun := { Urls: Missing, Waiters: [Waiter], Handle: 0, Done: false,
		Reader: ReaderFn, Spawn: SpawnFn, Capture: 0, ConfigIdentity: ConfigIdentity,
		Config: Config, Strict: Strict }
	_SYSTEM_PROXY_PAC_PENDING := PacRun
	try LoggerStart("HttpClient", "Resolving the Windows PAC proxy for {1} destination(s)…", Missing.Length)
	; Destination queries can contain API keys. The native child reads its owned
	; input file; neither the URL nor an encoded credential enters process argv.
	Script := "$ErrorActionPreference='Stop';try{$w=[System.Net.WebRequest]::GetSystemWebProxy();"
		. "foreach($u in [IO.File]::ReadAllLines($args[0],[Text.Encoding]::UTF8)){"
		. "$p=$w.GetProxy([Uri]$u);if($p.AbsoluteUri -eq ([Uri]$u).AbsoluteUri){"
		. "[Console]::Out.WriteLine('DIRECT')}else{[Console]::Out.WriteLine($p.AbsoluteUri)}}}"
		. "catch{[Console]::Error.WriteLine('System proxy resolution failed.');exit 1}"
	Exe := A_WinDir . "\System32\WindowsPowerShell\v1.0\powershell.exe"
	OnDone := _SystemProxy_FinishPac.Bind(PacRun)
	try {
		Directory := _SR_AcquireCaptureDirectory()
		PacRun.Capture := Map("TmpFile", Directory . "output.tmp", "CaptureDir", Directory)
		Input := ""
		for Url in Missing {
			if !_HTTP_CurlScalarIsSafe(Url)
				throw ValueError("System proxy destination contains a control character.")
			Input .= Url . "`n"
		}
		if Strict {
			Input := '{"version":1,"auto_detect":' . (Config.Get("auto_detect", false) ? "true" : "false")
				. ',"pac_url":' . JsonStringLiteral(Config["pac_url"]) . ',"urls":['
			for Index, Url in Missing
				Input .= (Index == 1 ? "" : ",") . JsonStringLiteral(Url)
			Input .= "]}"
		}
		if !FSWrite(PacRun.Capture["TmpFile"], Input)
			throw Error("System proxy input could not be staged.")
		; Invoke a script block so its sole argument is the input path, whose
		; quotes are PowerShell literals inside one native argv element.
		Command := "& {" . Script . "} '" . StrReplace(PacRun.Capture["TmpFile"], "'", "''") . "'"
		Args := Strict
			? ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
				"-File", _VendorDir . "\ergopti_system_proxy_worker.ps1", "-InputPath", PacRun.Capture["TmpFile"]]
			: ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", Command]
		PacRun.Handle := IsObject(SpawnFn)
			? SpawnFn.Call(Exe, Args, OnDone)
			: ShellRunner_SpawnTreeOwned(Exe, Args, OnDone, 0, 0, 65536)
		if !(IsObject(PacRun.Handle) && PacRun.Handle.start())
			throw Error("the PowerShell child did not start")
	} catch as Err {
		_SystemProxy_FinishPac(PacRun, -1, "", "spawn failed")
		return true
	}
	Remaining := Strict ? TickRemaining64(Budget["start"], SYSTEM_PROXY_RESOLVE_TIMEOUT_MS)
		: SYSTEM_PROXY_RESOLVE_TIMEOUT_MS
	SetTimer(_SystemProxy_PacDeadline.Bind(PacRun), -Max(1, Remaining))
	return true
}

_SystemProxy_PacDeadline(PacRun) {
	global HTTP_CURL_CLEANUP_RETRY_MS
	if PacRun.Done
		return
	Terminated := false
	try Terminated := PacRun.Handle.terminate() == true
	catch {
		try LoggerError("HttpClient", "The exact PAC resolver termination failed.")
	}
	if !Terminated {
		if !PacRun.HasOwnProp("TerminationReported") {
			PacRun.TerminationReported := true
			try LoggerError("HttpClient", "The exact PAC resolver has not acknowledged retirement.")
		}
		SetTimer(_SystemProxy_PacDeadline.Bind(PacRun), -HTTP_CURL_CLEANUP_RETRY_MS)
		return
	}
	_SystemProxy_FinishPac(PacRun, -1, "", "timed out")
}

; Completes one PAC run, fencing strict receipts against current OS settings.
; Only the legacy non-blocking caller retains session cache compatibility.
_SystemProxy_FinishPac(PacRun, ExitCode, Stdout, Stderr) {
	global _SYSTEM_PROXY_PAC_CACHE, _SYSTEM_PROXY_PAC_PENDING, _SYSTEM_PROXY_PAC_CONFIG
	global SYSTEM_PROXY_RESOLVE_TIMEOUT_MS
	if PacRun.Done
		return
	PacRun.Done := true
	if (_SYSTEM_PROXY_PAC_PENDING == PacRun)
		_SYSTEM_PROXY_PAC_PENDING := 0
	Lines := StrSplit(Trim(StrReplace(Stdout, "`r", ""), "`n"), "`n")
	Resolved := (ExitCode == 0 && !PacRun.HasOwnProp("TerminationReported")
		&& Lines.Length == PacRun.Urls.Length)
	Answers := Map()
	Metadata := Map()
	if Resolved && !PacRun.Strict {
		for Index, Origin in PacRun.Urls {
			Answer := RegExReplace(Trim(Lines[Index]), "/+$")
			if (Answer == "DIRECT") {
				Proxy := ""
			} else {
				Proxy := _SystemProxy_NormalizeEndpoint(Answer, "http")
				if (Proxy == "") {
					Resolved := false
					break
				}
			}
			Answers[Origin] := Proxy
		}
	}
	if PacRun.Strict {
		Resolved := false
		if ExitCode == 0 && !PacRun.HasOwnProp("TerminationReported") {
			try {
				Answers := _SystemProxy_ParseNativeAnswers(PacRun, Stdout, &Metadata)
				Resolved := true
			} catch {
				try LoggerWarn("HttpClient", "Native automatic proxy receipt was refused.")
			}
		}
	}
	if Resolved {
		if !PacRun.Strict && PacRun.ConfigIdentity == _SYSTEM_PROXY_PAC_CONFIG {
			for Url, Proxy in Answers
				_SYSTEM_PROXY_PAC_CACHE[Url] := Proxy
		}
		try LoggerSuccess("HttpClient", "Windows PAC proxy resolved for {1} destination(s).", PacRun.Urls.Length)
	} else {
		Message := PacRun.Strict ? "Native automatic proxy admission failed (exit {1})."
			: "Windows PAC proxy resolution failed (exit {1}); using the static proxy settings."
		try LoggerDone("HttpClient", Message, ExitCode)
	}
	_SystemProxy_CleanupInput(PacRun)
	for Waiter in PacRun.Waiters {
		WaiterResolved := Resolved
		Redo := Waiter.Queued
		if Waiter.Strict {
			try {
				Current := _SystemProxy_Config(Waiter.Reader, true)
				Redo := Redo || _SystemProxy_RefreshCache(Current) != PacRun.ConfigIdentity
			} catch {
				WaiterResolved := false
				Redo := false
			}
			if TickExpired64(Waiter.Budget["start"], SYSTEM_PROXY_RESOLVE_TIMEOUT_MS) {
				WaiterResolved := false
				Redo := false
			}
		}
		if Redo {
			try SystemProxy_ResolveAsync(Waiter.Urls, Waiter.Callback, Waiter.Reader, Waiter.Spawn, Waiter.Strict, Waiter.Budget)
			catch {
				Waiter.Result["_proxy_resolved"] := false
				try Waiter.Callback.Call(Waiter.Result)
				catch
					LoggerError("HttpClient", "System proxy callback threw.")
			}
			continue
		}
		Waiter.Result["_proxy_resolved"] := WaiterResolved
		for Url in Waiter.Urls {
			if WaiterResolved && Answers.Has(Url)
				Waiter.Result[Url] := Answers[Url]
			if Metadata.Has(Url)
				Waiter.Result["_proxy_receipts"][Url] := Metadata[Url]
		}
		try Waiter.Callback.Call(Waiter.Result)
		catch as Err
			LoggerError("HttpClient", "System proxy callback threw.")
	}
}

; A successful native lookup carries an access type, not a guessed URI echo.
; Parse the complete receipt before admitting any destination from its cohort.
_SystemProxy_ParseNativeAnswers(PacRun, Stdout, &Metadata) {
	Metadata := Map()
	Receipt := JsonParse(Stdout)
	if !(Receipt is Map) || Receipt.Get("version", 0) != 1
			|| Receipt.Get("status", "") != "completed" || !(Receipt.Get("results", 0) is Array)
			|| Receipt["results"].Length != PacRun.Urls.Length
		throw ValueError("Native automatic proxy receipt is incomplete.")
	Answers := Map()
	for Index, Url in PacRun.Urls {
		Item := Receipt["results"][Index]
		if !(Item is Map) || !(Item.Get("proxy", 0) is String) || !(Item.Get("bypass", 0) is String)
				|| !_HTTP_CurlScalarIsSafe(Item["proxy"]) || !_HTTP_CurlScalarIsSafe(Item["bypass"])
			throw ValueError("Native automatic proxy answer is malformed.")
		Kind := Item.Get("kind", "")
		ErrorCode := Item.Get("native_error", -1)
		if !(ErrorCode is Integer) || ErrorCode < 0
			throw ValueError("Native automatic proxy error code is malformed.")
		Metadata[Url] := Map("source", "native_refused", "native_error", ErrorCode)
		if Kind == "no_auto_proxy" {
			; WinHTTP 12180 means no PAC URL was discovered. An explicitly
			; configured PAC never receives this home-network fallback.
			if PacRun.Config["pac_url"] != "" || !PacRun.Config.Get("auto_detect", false)
					|| Item.Get("ok", true) || ErrorCode != 12180 || Item.Get("stage", "") != "lookup"
					|| Item.Get("access_type", -1) != 0 || Item["proxy"] != "" || Item["bypass"] != ""
				throw ValueError("Native automatic proxy absence was not acknowledged.")
			Answers[Url] := SystemProxy_SelectStatic(PacRun.Config, Url, true)["proxy"]
			Metadata[Url]["source"] := Answers[Url] == "" ? "wpad_absent_direct" : "wpad_absent_static"
			continue
		}
		if !Item.Get("ok", false) || ErrorCode != 0
			throw ValueError("Native automatic proxy lookup failed.")
		if Kind == "no_proxy" && Item.Get("access_type", 0) == 1 && Item["proxy"] == "" {
			Answers[Url] := ""
			Metadata[Url]["source"] := "native_direct"
		} else if Kind == "named_proxy" && Item.Get("access_type", 0) == 3 && Item["proxy"] != "" {
			Proxy := _SystemProxy_UsableNativeProxy(Item["proxy"], _SystemProxy_UrlParts(Url)["scheme"])
			if !_SystemProxy_NativeBypassIsUsable(Item["bypass"])
				throw ValueError("Native proxy bypass requires an unsupported representation.")
			Answers[Url] := SystemProxy_IsBypassed(Item["bypass"], _SystemProxy_UrlParts(Url)["host"]) ? "" : Proxy
			Metadata[Url]["source"] := Answers[Url] == "" ? "native_bypass" : "native_proxy"
		} else {
			throw ValueError("Native automatic proxy access type is unsupported.")
		}
	}
	return Answers
}

; curl owns one relay per request. Refuse ambiguous native failover lists and
; unsupported endpoints rather than silently discarding network policy.
_SystemProxy_UsableNativeProxy(List, Scheme) {
	Candidates := []
	for Entry in StrSplit(Trim(List), [";", " "]) {
		Entry := Trim(Entry)
		if Entry == ""
			continue
		Key := ""
		Endpoint := Entry
		if RegExMatch(Entry, "^([A-Za-z]+)=(.+)$", &Match) {
			Key := StrLower(Match[1])
			Endpoint := Match[2]
			if Key != "http" && Key != "https" && Key != "socks"
				throw ValueError("Native proxy scheme is unsupported.")
		}
		DefaultScheme := Key == "socks" ? "socks4a" : "http"
		Proxy := _SystemProxy_NormalizeEndpoint(Endpoint, DefaultScheme)
		if Proxy == "" || (RegExMatch(Proxy, ":(\d+)$", &Port)
				&& (Integer(Port[1]) < 1 || Integer(Port[1]) > 65535))
			throw ValueError("Native proxy endpoint is unsupported.")
		if Key == "" || Key == Scheme
			Candidates.Push(Proxy)
	}
	if Candidates.Length != 1
		throw ValueError("Native proxy failover selection is unsupported.")
	return Candidates[1]
}

_SystemProxy_NativeBypassIsUsable(Bypass) {
	for Pattern in StrSplit(Bypass, [";", " ", ","]) {
		Pattern := RegExReplace(StrLower(Trim(Pattern)), "^https?://")
		if Pattern != "" && Pattern != "<local>" && !RegExMatch(Pattern, "^[a-z0-9.*_-]+$")
			return false
	}
	return true
}

; Retains the owned input until transient locks release it. It can carry keys.
_SystemProxy_CleanupInput(PacRun) {
	global HTTP_CURL_CLEANUP_RETRY_MS
	if !(PacRun.Capture is Map)
		return true
	try Removed := _SR_CaptureRemove(PacRun.Capture) == 0
	catch {
		Removed := false
		if !PacRun.HasOwnProp("CleanupReported") {
			PacRun.CleanupReported := true
			try LoggerError("HttpClient", "System proxy input cleanup was refused.")
		}
	}
	if Removed {
		PacRun.Capture := 0
		return true
	}
	SetTimer(_SystemProxy_CleanupInput.Bind(PacRun), -HTTP_CURL_CLEANUP_RETRY_MS)
	return false
}

; Explicit environment relay configuration wins over GUI settings, as curl's
; inherited environment does. Empty system DIRECT remains an explicit answer.
SystemProxy_ResolveCurlAsync(Url, Callback, ReaderFn := 0, SpawnFn := 0, EnvFn := EnvGet) {
	Parts := _SystemProxy_UrlParts(Url)
	Host := Parts["host"]
	if Host == "localhost" || Host == "127.0.0.1" || Host == "::1" {
		Callback.Call(Map("ok", true, "inherit", false, "proxy", "", "source", "loopback", "native_error", 0))
		return true
	}
	; Mirror curl's destination-specific environment precedence. Windows
	; environment lookup is case-insensitive, as curl's native getenv is.
	Names := Parts["scheme"] == "https"
		? ["https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY"]
		: ["http_proxy", "all_proxy", "ALL_PROXY"]
	for Name in Names {
		if EnvFn.Call(Name) != "" {
			Callback.Call(Map("ok", true, "inherit", true, "proxy", "", "source", "environment", "native_error", 0))
			return true
		}
	}
	return SystemProxy_ResolveAsync([Url], _SystemProxy_PublishCurlSelection.Bind(Url, Callback, ReaderFn, EnvFn), ReaderFn, SpawnFn, true)
}


; Preserve closed native diagnosis without exposing any captured URL or stderr.
_SystemProxy_PublishCurlSelection(Url, Callback, ReaderFn, EnvFn, Resolved) {
	Ok := Resolved.Get("_proxy_resolved", false)
	Metadata := Resolved.Get("_proxy_receipts", Map()).Get(Url, Map())
	Callback.Call(Map("ok", Ok, "inherit", false, "proxy", Resolved[Url],
		"source", Ok ? Metadata.Get("source", "system_direct") : "native_refused",
		"native_error", Metadata.Get("native_error", 0), "current",
		_SystemProxy_CurlSelectionIsCurrent.Bind(Url, ReaderFn, EnvFn,
			Resolved.Get("_proxy_config_identity", ""))))
}

_SystemProxy_CurlSelectionIsCurrent(Url, ReaderFn, EnvFn, Identity) {
	Parts := _SystemProxy_UrlParts(Url)
	Names := Parts["scheme"] == "https"
		? ["https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY"]
		: ["http_proxy", "all_proxy", "ALL_PROXY"]
	for Name in Names
		if EnvFn.Call(Name) != ""
			return false
	Config := _SystemProxy_Config(ReaderFn, true)
	return _SystemProxy_RefreshCache(Config) == Identity
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
	Started := A_TickCount
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
		Req := CurlAsyncRequest()
		_HTTP_ACTIVE_REQUEST := Req
		Req.SetManagedRouting(0, () => _HTTP_REQUEST_GENERATION == MyGeneration && _HTTP_ACTIVE_REQUEST == Req)
		Req.SetDeadline(Started, HTTP_TIMEOUT_MS * 4)
		Req.SetTimeouts(HTTP_TIMEOUT_MS, HTTP_TIMEOUT_MS, HTTP_TIMEOUT_MS, HTTP_TIMEOUT_MS)
		Req.Open("POST", Url, true)
		; Set caller-supplied headers.
		if (Headers is Map) {
			for HName, HVal in Headers
				Req.SetRequestHeader(HName, HVal)
		}
		if !Req.Send(Body) || !_HTTP_ManagedWait(Req)
			throw Error("The managed HTTP request refused dispatch or completion.")
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
	if Callback != 0 && _HTTP_REQUEST_GENERATION == MyGeneration && !A_IsSuspended {
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
	global _HTTP_ACTIVE_REQUEST, _HTTP_REQUEST_GENERATION
	_HTTP_REQUEST_GENERATION += 1
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

; Wait only for an already-owned managed request. Sleep serves AHK's message
; queue, while the original deadline/current owner still gates every effect.
_HTTP_ManagedWait(Request) {
	while !Request.WaitForResponse(0) {
		if !Request._ManagedIsLive() {
			Request.Abort()
			return false
		}
		Sleep(10)
	}
	return !Request.Aborted && !A_IsSuspended && Request._Remaining() > 0
}
