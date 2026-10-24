; ui/field_check/network_check.ahk

; ==============================================================================
; MODULE: Network Check (Windows)
; DESCRIPTION:
; The Debug menu's one-click « Test network (PAC, proxy, download) »: reads the
; Windows proxy settings (the WinINet settings Edge and Internet Options share),
; downloads and judges the PAC file, asks the managed route lookup which route a
; download would take, then makes one request through the managed WinHTTP
; transport. It writes one evidence record and shows one line per step with a
; « Copy report » button. macOS and Linux run the same steps in Lua
; (_shared/lua/network/field_check_network.lua).
;
; FEATURES & RATIONALE:
; 1. Company-proxy failures are the ones a user cannot diagnose alone: the report
;    names the step that failed (settings, PAC download, PAC verdict, route, TLS,
;    transfer) with a closed token, never a URL, a host or PAC content.
; 2. The managed path, not a probe of its own: the route is the one the updater
;    and the downloads use (SystemProxy_ResolveCurlAsync) and the request goes
;    through CurlAsyncRequest, so its failure receipt (stage, TLS status) is the
;    one a real download would get.
; 3. The PAC address is handed to the function that fetches it and goes nowhere
;    else. The PAC verdict mirrors network/pac_check.lua: HTTP 200, at most one
;    mebibyte, strict UTF-8 (or a UTF-16 byte-order mark) and FindProxyForURL.
; 4. Every collaborator is injectable, so the unit suite replays each failure
;    without a network, a proxy or a window. The report machinery is the Debug
;    check family's (ui/layout_manager/composer_check.ahk).
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

; Logger tag of every line the check writes; the maintainer filters on it.
global NETWORK_CHECK_TAG := "NetworkCheck"

; Identity of the check in its evidence record (macOS and Linux carry the same).
global NETWORK_CHECK_ID := "network"

; Step identities in report order. Pinned against the Lua definition by
; tools/test/test-network-field-check-parity.cjs.
global NETWORK_CHECK_STEPS := ["proxy_settings", "pac_download", "pac_script", "route_lookup", "tls", "transfer", "digest"]

; Largest PAC accepted, mirroring native_pac.max_script_bytes of proxy_policy.json.
global NETWORK_CHECK_PAC_MAX_BYTES := 1048576

; Budgets in milliseconds.
global NETWORK_CHECK_PAC_TIMEOUT_MS := 15000
global NETWORK_CHECK_REQUEST_TIMEOUT_MS := 20000
global NETWORK_CHECK_POLL_MS := 100

; The environment variables a managed download honours before the system settings.
global NETWORK_CHECK_ENV_PROXY_NAMES := ["https_proxy", "http_proxy", "all_proxy"]

; At most one check runs at a time.
global _NetworkCheckBusy := false

; One run of the check.
class NetworkCheckRun {
	__New(OnDone, Deps) {
		this.OnDone := OnDone
		this.Deps := Deps
		this.Report := ComposerCheck_NewReport()
		this.Settled := false
	}
}





; ==================================
; ==================================
; ======= 2/ Pure judgements =======
; ==================================
; ==================================

/**
 * Names the kinds of proxy configured.
 * @param {Map} Config - From SystemProxy_ReadIEConfig: auto_detect, pac_url, proxy.
 * @param {Func} EnvFn - Reads an environment variable.
 * @returns {string} Tokens joined by "+" (env, pac, discovery, fixed), or "none".
 */
NetworkCheck_ProxyKinds(Config, EnvFn := EnvGet) {
	global NETWORK_CHECK_ENV_PROXY_NAMES
	Kinds := []
	for Name in NETWORK_CHECK_ENV_PROXY_NAMES {
		if EnvFn.Call(Name) != "" {
			Kinds.Push("env")
			break
		}
	}
	if Config.Get("pac_url", "") != ""
		Kinds.Push("pac")
	if Config.Get("auto_detect", false)
		Kinds.Push("discovery")
	if Config.Get("proxy", "") != ""
		Kinds.Push("fixed")
	if Kinds.Length == 0
		return "none"
	Joined := ""
	for Kind in Kinds
		Joined .= (Joined == "" ? "" : "+") . Kind
	return Joined
}

/**
 * Whether the bytes are strictly valid UTF-8 (no overlong form, no surrogate).
 * @param {Buffer} Bytes
 * @param {Integer} Size
 * @returns {boolean}
 */
_NetworkCheck_IsStrictUtf8(Bytes, Size) {
	if Size == 0
		return true
	; MB_ERR_INVALID_CHARS makes the conversion fail on any invalid sequence
	return DllCall("Kernel32\MultiByteToWideChar", "UInt", 65001, "UInt", 0x8, "Ptr", Bytes, "Int", Size,
		"Ptr", 0, "Int", 0, "Int") > 0
}

/**
 * Judges one PAC answer the way the managed download does.
 * @param {Integer} Status - HTTP status; 0 when the request failed.
 * @param {Buffer|String} Bytes - The response body, "" when absent.
 * @returns {string} "ok" or "error".
 */
NetworkCheck_JudgePac(Status, Bytes) {
	global NETWORK_CHECK_PAC_MAX_BYTES
	if Status != 200 || !(Bytes is Buffer) || Bytes.Size == 0 || Bytes.Size > NETWORK_CHECK_PAC_MAX_BYTES
		return "error"
	First := NumGet(Bytes, 0, "UChar")
	Second := Bytes.Size > 1 ? NumGet(Bytes, 1, "UChar") : 0
	if (First == 0xFF && Second == 0xFE) || (First == 0xFE && Second == 0xFF)
		return "ok"
	Offset := (Bytes.Size >= 3 && First == 0xEF && Second == 0xBB && NumGet(Bytes, 2, "UChar") == 0xBF) ? 3 : 0
	Body := Buffer(Bytes.Size - Offset)
	DllCall("RtlMoveMemory", "Ptr", Body, "Ptr", Bytes.Ptr + Offset, "UPtr", Body.Size)
	if !_NetworkCheck_IsStrictUtf8(Body, Body.Size)
		return "error"
	return InStr(StrGet(Body, Body.Size, "UTF-8"), "FindProxyForURL") ? "ok" : "error"
}

/**
 * The token a failed request is reported as. Closed vocabulary: the receipt's
 * stage names, never its detail.
 * @param {Map} Result - ok, status, stage, tls_status, timed_out.
 * @returns {string}
 */
NetworkCheck_FailureToken(Result) {
	if Result.Get("timed_out", false)
		return "timeout"
	Stage := Result.Get("stage", "")
	if Stage == "tls"
		return "certificate"
	if Stage == "proxy_resolve" || Stage == "proxy_connect" || Stage == "connect"
		return Stage
	Status := Result.Get("status", 0)
	if Status > 0
		return "http_" . Status
	return "failed"
}





; ==========================
; ==========================
; ======= 3/ The run =======
; ==========================
; ==========================

/**
 * Production collaborators; tests replace any entry.
 * @returns {Map}
 */
_NetworkCheck_DefaultDeps() {
	return Map(
		"settings", _NetworkCheck_ReadSettings,
		"fetch_pac", _NetworkCheck_FetchPac,
		"feed_url", () => _CLW_SourceUrl("feed"),
		"route", (Url, Callback) => SystemProxy_ResolveCurlAsync(Url, Callback),
		"request", _NetworkCheck_Request)
}

/**
 * Runs the check.
 * @param {Func} OnDone - Receives the finished report.
 * @param {Map|Integer} Deps - Collaborators; production ones when 0.
 * @returns {boolean} False when a check is already running.
 */
NetworkCheck_Run(OnDone, Deps := 0) {
	global _NetworkCheckBusy, NETWORK_CHECK_TAG
	if _NetworkCheckBusy {
		LoggerWarn(NETWORK_CHECK_TAG, "Network check refused: another one is still running.")
		return false
	}
	_NetworkCheckBusy := true
	LoggerStart(NETWORK_CHECK_TAG, "Network check started…")
	Merged := _NetworkCheck_DefaultDeps()
	if (Deps is Map)
		for Name, Value in Deps
			Merged[Name] := Value
	Run := NetworkCheckRun(OnDone, Merged)
	try {
		_NetworkCheck_Settings(Run)
	} catch as Err {
		LoggerError(NETWORK_CHECK_TAG, "Network check raised: {1}", Err.Message)
		if !Run.Report["seen"].Has("internal_error")
			ComposerCheck_Step(Run.Report, "internal_error", "fail", "raised")
		_NetworkCheck_Finish(Run)
	}
	return true
}

; Step 1: the proxy settings; a PAC address is handed to the next step only.
_NetworkCheck_Settings(Run) {
	PacUrl := ""
	try {
		Settings := Run.Deps["settings"].Call()
		ComposerCheck_Step(Run.Report, "proxy_settings", "info", Settings["kinds"])
		PacUrl := Settings.Get("pac_url", "")
	} catch {
		ComposerCheck_Step(Run.Report, "proxy_settings", "fail", "unreadable")
	}
	if PacUrl == "" {
		ComposerCheck_Step(Run.Report, "pac_download", "skip", "no_pac")
		ComposerCheck_Step(Run.Report, "pac_script", "skip", "no_pac")
		return _NetworkCheck_Route(Run)
	}
	Run.Deps["fetch_pac"].Call(PacUrl, _NetworkCheck_OnPac.Bind(Run))
}

; Steps 2 and 3: the PAC download and its verdict.
_NetworkCheck_OnPac(Run, Status, Bytes) {
	ComposerCheck_Step(Run.Report, "pac_download", Status == 200 ? "pass" : "fail",
		Status > 0 ? "http_" . Status : "failed")
	Verdict := NetworkCheck_JudgePac(Status, Bytes)
	ComposerCheck_Step(Run.Report, "pac_script", Verdict == "ok" ? "pass" : "fail",
		Verdict == "ok" ? "valid" : "invalid")
	_NetworkCheck_Route(Run)
}

; Step 4: the route the managed transport would take for a real download.
_NetworkCheck_Route(Run) {
	global NETWORK_CHECK_TAG
	Url := ""
	try Url := Run.Deps["feed_url"].Call()
	if Url == "" {
		ComposerCheck_Step(Run.Report, "route_lookup", "fail", "no_target")
		return _NetworkCheck_Transfer(Run, "")
	}
	Started := false
	try Started := Run.Deps["route"].Call(Url, _NetworkCheck_OnRoute.Bind(Run, Url))
	catch as Err
		LoggerWarn(NETWORK_CHECK_TAG, "The route lookup could not start: {1}", Err.Message)
	if !Started && !Run.Report["seen"].Has("route_lookup")
		_NetworkCheck_OnRoute(Run, Url, Map("ok", false, "source", "native_refused"))
}

_NetworkCheck_OnRoute(Run, Url, Route) {
	if Run.Report["seen"].Has("route_lookup")
		return
	if Route.Get("ok", false) {
		Sources := Map("system_direct", "selected_direct", "system_static", "selected_proxy",
			"environment", "selected_environment", "loopback", "selected_direct")
		ComposerCheck_Step(Run.Report, "route_lookup", "pass", Sources.Get(Route.Get("source", ""), "selected"))
	} else {
		ComposerCheck_Step(Run.Report, "route_lookup", "fail", "native_refused")
	}
	_NetworkCheck_Transfer(Run, Url)
}

; Steps 5 to 7: TLS, the transfer, and the digest (a GET proves no checksum).
_NetworkCheck_Transfer(Run, Url) {
	if Url == "" {
		ComposerCheck_Step(Run.Report, "tls", "skip", "not_reached")
		ComposerCheck_Step(Run.Report, "transfer", "fail", "no_target")
		ComposerCheck_Step(Run.Report, "digest", "skip", "get_only")
		return _NetworkCheck_Finish(Run)
	}
	Run.Deps["request"].Call(Url, _NetworkCheck_OnRequest.Bind(Run))
}

_NetworkCheck_OnRequest(Run, Result) {
	if Result.Get("ok", false) {
		Status := Result.Get("status", 0)
		ComposerCheck_Step(Run.Report, "tls", "pass", "trusted")
		ComposerCheck_Step(Run.Report, "transfer", Status < 400 ? "pass" : "fail", "http_" . Status)
	} else {
		Token := NetworkCheck_FailureToken(Result)
		if Token == "certificate"
			ComposerCheck_Step(Run.Report, "tls", "fail", "certificate")
		else
			ComposerCheck_Step(Run.Report, "tls", "skip", "not_reached")
		ComposerCheck_Step(Run.Report, "transfer", "fail", Token)
	}
	ComposerCheck_Step(Run.Report, "digest", "skip", "get_only")
	_NetworkCheck_Finish(Run)
}

; Settles once: the evidence record, the closing log line and the callback.
_NetworkCheck_Finish(Run) {
	global _NetworkCheckBusy, NETWORK_CHECK_TAG, NETWORK_CHECK_ID
	if Run.Settled
		return
	Run.Settled := true
	_NetworkCheckBusy := false
	Passed := ComposerCheck_Passed(Run.Report)
	LoggerEvidence(NETWORK_CHECK_TAG, "Network check result: {1}", ComposerCheck_LogLine(Run.Report, NETWORK_CHECK_ID))
	LoggerSuccess(NETWORK_CHECK_TAG, "Network check finished: {1}.", Passed ? "pass" : "fail")
	Run.OnDone.Call(Run.Report)
}





; ==================================
; ==================================
; ======= 4/ Native bindings =======
; ==================================
; ==================================

; Reads the signed-in user's proxy settings and names their kinds.
_NetworkCheck_ReadSettings() {
	Config := SystemProxy_ReadIEConfig()
	return Map("kinds", NetworkCheck_ProxyKinds(Config), "pac_url", Config["pac_url"])
}

; Downloads the PAC directly, as the managed download does. Calls
; Callback(Status, Bytes) once; Status is 0 and Bytes "" when the request fails.
_NetworkCheck_FetchPac(Url, Callback) {
	global NETWORK_CHECK_PAC_TIMEOUT_MS, NETWORK_CHECK_POLL_MS, NETWORK_CHECK_PAC_MAX_BYTES
	Whr := ""
	try {
		Whr := ComObject("WinHttp.WinHttpRequest.5.1")
		Whr.SetTimeouts(5000, 5000, NETWORK_CHECK_PAC_TIMEOUT_MS, NETWORK_CHECK_PAC_TIMEOUT_MS)
		Whr.Open("GET", Url, true)
		Whr.Send()
	} catch {
		Callback.Call(0, "")
		return
	}
	State := { Poll: 0 }
	State.Poll := _NetworkCheck_PollPac.Bind(Whr, A_TickCount + NETWORK_CHECK_PAC_TIMEOUT_MS, Callback, State)
	SetTimer(State.Poll, -NETWORK_CHECK_POLL_MS)
}

_NetworkCheck_PollPac(Whr, Deadline, Callback, State) {
	global NETWORK_CHECK_POLL_MS, NETWORK_CHECK_PAC_MAX_BYTES
	Done := false
	try Done := Whr.WaitForResponse(0)
	if !Done && A_TickCount < Deadline {
		SetTimer(State.Poll, -NETWORK_CHECK_POLL_MS)
		return
	}
	State.Poll := 0
	if !Done {
		try Whr.Abort()
		Callback.Call(0, "")
		return
	}
	try {
		Status := Whr.Status
		Body := Whr.ResponseBody
		Size := Body.MaxIndex() + 1
		if Size > NETWORK_CHECK_PAC_MAX_BYTES + 1
			Size := NETWORK_CHECK_PAC_MAX_BYTES + 1
		Bytes := Buffer(Size)
		Loop Size
			NumPut("UChar", Body[A_Index - 1], Bytes, A_Index - 1)
		Callback.Call(Status, Bytes)
	} catch {
		Callback.Call(0, "")
	}
}

; One GET through the managed WinHTTP transport. Calls Callback(Map) once with
; ok, status, stage, tls_status and timed_out from the request's own receipt.
_NetworkCheck_Request(Url, Callback) {
	global NETWORK_CHECK_REQUEST_TIMEOUT_MS, NETWORK_CHECK_POLL_MS
	Started := A_TickCount
	Req := ""
	try {
		Req := CurlAsyncRequest()
		Req.SetTimeouts(5000, 5000, NETWORK_CHECK_REQUEST_TIMEOUT_MS, NETWORK_CHECK_REQUEST_TIMEOUT_MS)
		Req.Open("GET", Url, true)
		Req.SetRequestHeader("Accept", "application/atom+xml")
		Req.SetManagedRouting(0, () => !A_IsSuspended)
		Req.SetDeadline(Started, NETWORK_CHECK_REQUEST_TIMEOUT_MS)
		if !Req.Send("")
			throw Error("The managed request refused dispatch.")
	} catch {
		Callback.Call(Map("ok", false, "status", 0, "stage", ""))
		return
	}
	State := { Poll: 0 }
	State.Poll := _NetworkCheck_PollRequest.Bind(Req, Started, Callback, State)
	SetTimer(State.Poll, -NETWORK_CHECK_POLL_MS)
}

_NetworkCheck_PollRequest(Req, Started, Callback, State) {
	global NETWORK_CHECK_REQUEST_TIMEOUT_MS, NETWORK_CHECK_POLL_MS
	if !(Req.Completed || Req.Aborted) && (A_TickCount - Started) < NETWORK_CHECK_REQUEST_TIMEOUT_MS + 2000 {
		SetTimer(State.Poll, -NETWORK_CHECK_POLL_MS)
		return
	}
	State.Poll := 0
	Receipt := Req.NativeReceipt is Map ? Req.NativeReceipt : Map()
	Result := Map("ok", Req.Completed && !Req.Aborted && Req.Status >= 100, "status", Req.Status,
		"stage", Receipt.Get("stage", ""), "tls_status", Receipt.Get("tls_status", ""),
		"timed_out", Req.Aborted)
	Callback.Call(Result)
}





; =============================
; =============================
; ======= 5/ The window =======
; =============================
; =============================

/**
 * Debug menu: « Test network (PAC, proxy, download) ». Runs the check and shows
 * its report.
 */
NetworkCheck_Command(*) {
	Started := NetworkCheck_Run(NetworkCheck_ShowReport)
	if !Started
		Ui_MsgBox(t("field_check.busy"), t("menu.debug.field_check_network"), "Icon!")
}

/**
 * Shows a finished report, one line per step, with a « Copy report » button.
 * @param {Map} Report
 * @param {Func} ShowFn - Opens the window; tests replace it.
 */
NetworkCheck_ShowReport(Report, ShowFn := 0) {
	ComposerCheck_ShowReport(Report, ShowFn, "menu.debug.field_check_network")
}
