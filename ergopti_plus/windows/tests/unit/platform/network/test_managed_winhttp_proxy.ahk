; tests/unit/platform/network/test_managed_winhttp_proxy.ahk
; The production request chain (CurlAsyncRequest, route lookup, managed worker, WinHTTP)
; against an owned loopback proxy that authenticates the current user through the actual
; Windows security package. Plain HTTP destinations only: a proxied HTTPS request needs a
; trusted root, which the native CA cases cover. What this proves on any Windows image:
; an NTLM-only proxy works (the case the System32 curl lost), Negotiate works, a
; Basic-only proxy receives no credentials, and an ordered PAC list fails over from a
; closed proxy to the authenticating one.

class _MWP_Proxy {
	__New(Mode, OrderedPac := false) {
		this.Mode := Mode
		this.OrderedPac := OrderedPac
		this.Identity := _ManagedRemoteFixtureGuid()
		this.Name := "Local\ErgoptiPlus.WinHttpProxy." . this.Identity
		this.Directory := ""
		this.Path := ""
		this.Event := 0
		this.Handle := 0
		this.Results := []
		this.State := Map()
	}

	OnDone(Code, Out, Err) => this.Results.Push(Map("exit", Code, "stdout", Out, "stderr", Err))

	Read() {
		try {
			State := JsonParse(FileRead(this.Path, "UTF-8"))
			if State is Map && State.Get("schema_version", 0) == 1 {
				this.State := State
				return true
			}
		}
		return false
	}

	Start() {
		global _DriverDir
		this.Directory := _SR_AcquireCaptureDirectory()
		this.Path := this.Directory . "proxy.json"
		this.Event := DllCall("Kernel32\CreateEventW", "Ptr", 0, "Int", true, "Int", false, "WStr", this.Name, "Ptr")
		AssertTrue(this.Event && A_LastError != 183, "a unique owned stop event")
		Args := ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
			_DriverDir . "\tests\fixtures\winhttp_proxy_service.ps1", "-StatePath", this.Path,
			"-StopEvent", this.Name, "-Mode", this.Mode]
		if this.OrderedPac
			Args.Push("-OrderedPac")
		this.Handle := ShellRunner_SpawnTreeOwned(_Updater_PowerShellPath(), Args,
			ObjBindMethod(this, "OnDone"), , , 8192)
		AssertTrue(this.Handle.start(), "the owned proxy Job must start")
		Started := A_TickCount
		while !TickExpired64(Started, 30000) {
			_SR_TreePoll()
			if this.Read() && this.State.Get("state", "") == "ready"
				return
			if this.Results.Length
				break
			Sleep(10)
		}
		throw Error("The owned proxy did not become ready: " . (this.Results.Length ? this.Results[1]["stdout"] . this.Results[1]["stderr"] : "no completion"))
	}

	Port => this.State["port"]

	; Signals the service, waits for its final counters and retires its Job and private state.
	Stop() {
		if this.Event
			DllCall("Kernel32\SetEvent", "Ptr", this.Event, "Int")
		Started := A_TickCount
		while this.Results.Length == 0 && IsObject(this.Handle) && !TickExpired64(Started, 15000) {
			_SR_TreePoll()
			Sleep(10)
		}
		if IsObject(this.Handle)
			AssertTrue(this.Handle.terminate(), "the owned proxy Job must physically retire")
		this.Handle := 0
		if this.Event {
			AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", this.Event, "Int"), "the stop event closes")
			this.Event := 0
		}
		AssertEqual(1, this.Results.Length, "the owned proxy must complete once")
		AssertEqual(0, this.Results[1]["exit"], "proxy output: " . this.Results[1]["stdout"] . " | " . this.Results[1]["stderr"])
		AssertEqual("OWNED_WINHTTP_PROXY_STOPPED", Trim(this.Results[1]["stdout"], "`r`n "))
		AssertTrue(this.Read(), "the final counters are readable")
		AssertEqual("stopped", this.State.Get("state", ""))
		if this.Directory != ""
			AssertEqual(0, _SR_CaptureRemove(Map("TmpFile", this.Path, "CaptureDir", this.Directory)), "private proxy state retires")
		this.Directory := ""
		return this.State
	}
}

_MWP_RequireNoProxyEnvironment() {
	for Name in ["http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY", "no_proxy", "NO_PROXY"]
		AssertEqual("", EnvGet(Name), "an inherited proxy variable makes this controlled qualification unavailable")
}

; Sends one GET through the production chain and waits for it.
_MWP_Get(Settings) {
	Request := CurlAsyncRequest()
	Request.SetManagedRouting(Settings)
	Request.SetDeadline(A_TickCount, 40000)
	Request.Open("GET", "http://origin.invalid/proxied", true)
	AssertTrue(Request.Send(), "the managed request must dispatch")
	Begin := A_TickCount
	while !Request.WaitForResponse(0) && TickElapsed(Begin) < 45000 {
		_SR_TreePoll()
		Sleep(10)
	}
	AssertTrue(Request.WaitForResponse(0), "the managed request must complete within its bound")
	return Request
}

_MWP_StaticSettings(Proxy) {
	return () => Map("auto_detect", false, "pac_url", "", "proxy", "127.0.0.1:" . Proxy.Port, "bypass", "")
}

_MWP_AuthenticatedProxy(Mode) {
	_MWP_RequireNoProxyEnvironment()
	Proxy := _MWP_Proxy(Mode)
	Final := 0
	try {
		Proxy.Start()
		Request := _MWP_Get(_MWP_StaticSettings(Proxy))
		AssertEqual(200, Request.Status, "the proxy-authenticated request must reach its answer")
		AssertEqual("proxied-authenticated", Request.ResponseText)
	} finally Final := Proxy.Stop()
	AssertEqual(1, Final["authenticated"], "Windows SSPI accepted exactly one current-user exchange")
	AssertTrue(Final["identity_matched"], "the accepted context belongs to the signed-in user")
	AssertEqual("", Final["failure"], "the proxy saw no unexpected scheme or SSPI failure")
	AssertEqual(0, Final["origin_authorizations"], "the origin never received credentials")
	if Mode == "Ntlm" {
		AssertEqual(1, Final["type_one"], "one NTLM Type1 and")
		AssertEqual(1, Final["type_three"], "one NTLM Type3 answered the proxy challenge")
	}
}
Test("managed WinHTTP proxy: an NTLM-only proxy authenticates the signed-in user through the production chain",
	_MWP_AuthenticatedProxy.Bind("Ntlm"))
Test("managed WinHTTP proxy: a Negotiate proxy authenticates the signed-in user through the production chain",
	_MWP_AuthenticatedProxy.Bind("Negotiate"))

_MWP_BasicOnlyProxy() {
	_MWP_RequireNoProxyEnvironment()
	; The application initializes the closed failure contract at boot; the headless runner does not.
	global _ManagedNetworkWindowsContract, _ManagedNetworkWindowsPorts, _ManagedNetworkWindowsInitializing
	SavedContract := _ManagedNetworkWindowsContract
	SavedPorts := _ManagedNetworkWindowsPorts
	SavedInitializing := _ManagedNetworkWindowsInitializing
	_ManagedNetworkWindowsContract := 0
	_ManagedNetworkWindowsPorts := 0
	_ManagedNetworkWindowsInitializing := false
	Proxy := _MWP_Proxy("Basic")
	Final := 0
	try {
		ManagedNetworkFailureWindows_Init()
		Proxy.Start()
		Request := _MWP_Get(_MWP_StaticSettings(Proxy))
		AssertEqual(0, Request.Status, "an unanswerable proxy challenge is a transport failure")
		Report := ManagedNetworkFailureWindows_FromTransport(Request, () => true)
		AssertTrue(Report is Map, "the failure keeps a closed receipt")
		AssertEqual("proxy", Report["cause"], "a Basic-only proxy is classified as a proxy problem")
		AssertEqual("winhttp", Request.NativeReceipt.Get("backend", ""))
		AssertEqual(407, Request.NativeReceipt.Get("http_status", 0))
		AssertEqual("proxy", Request.NativeReceipt.Get("http_response_source", ""))
	} finally {
		_ManagedNetworkWindowsContract := SavedContract
		_ManagedNetworkWindowsPorts := SavedPorts
		_ManagedNetworkWindowsInitializing := SavedInitializing
		Final := Proxy.Stop()
	}
	AssertEqual(0, Final["proxy_authorizations"], "no credential of any scheme was sent to a Basic-only proxy")
	AssertEqual(0, Final["basic_attempts"])
}
Test("managed WinHTTP proxy: a Basic-only proxy is classified as a proxy failure and gets no credentials",
	_MWP_BasicOnlyProxy)

_MWP_OrderedPacFailover() {
	_MWP_RequireNoProxyEnvironment()
	Proxy := _MWP_Proxy("Ntlm", true)
	Final := 0
	try {
		Proxy.Start()
		PacUrl := "http://127.0.0.1:" . Proxy.Port . "/ordered.pac"
		Request := _MWP_Get(() => Map("auto_detect", false, "pac_url", PacUrl, "proxy", "", "bypass", ""))
		AssertEqual(200, Request.Status, "the request must fail over from the closed proxy to the authenticating one")
		AssertEqual("proxied-authenticated", Request.ResponseText)
	} finally Final := Proxy.Stop()
	AssertEqual(1, Final["authenticated"], "the second ordered route authenticated the current user")
	AssertEqual(1, Final["type_one"])
	AssertEqual(1, Final["type_three"])
	AssertEqual("", Final["failure"])
}
Test("managed WinHTTP proxy: a PAC list fails over from a closed proxy to the authenticating one",
	_MWP_OrderedPacFailover)
