; tests/unit/core/network/adapters/test_native_http_forward_proxy.ahk
; A configured remote HTTP provider reaches the actual credentialed relay hop.
; The independent native oracle receives an authenticated forward response from
; the same owned proxy that refuses CONNECT to the destination's plain port.
_NativeHttpForwardProxy_Controls() {
	global _DriverDir, _VendorDir, _SharedDir
	Resolved := _LLMRemoteResolveEntry(Map("Provider", "openai", "Token", "owned-provider-key",
		"Model", "owned-model", "BaseUrl", "http://forward-fixture.invalid/v1"))
	AssertTrue(Resolved is Map, "The actual API entry resolver must admit the remote HTTP provider")
	Endpoint := _LLMRemoteBuildUrl(Resolved["BaseUrl"], Resolved["Format"], Resolved["Token"], Resolved["Model"])
	AssertEqual("http://forward-fixture.invalid/v1/chat/completions", Endpoint)
	AssertFalse(SystemProxy_IsLoopbackUrl(Endpoint), "The admitted provider must reach proxy routing")
	; _LLMRemote_ReadySend uses this admitted base for its real GET /models.
	ReadyUrl := RTrim(Resolved["BaseUrl"], "/") . "/models"
	AssertEqual("http://forward-fixture.invalid/v1/models", ReadyUrl)
	Observed := [], Handle := 0
	try {
		Handle := ShellRunner_SpawnTreeOwned(_Updater_PowerShellPath(),
			["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
				_DriverDir . "\tests\fixtures\native_http_forward_proxy.ps1",
				"-RoutesPath", _VendorDir . "\ergopti_network_routes.ps1",
				"-TransportPath", _VendorDir . "\ergopti_winhttp_transport.ps1",
				"-PolicyPath", _SharedDir . "\core\network\data\proxy_policy.json",
				"-UpdaterDefaultsPath", _SharedDir . "\updater\data\defaults.json"],
			(Code, Out, Err) => Observed.Push(Map("exit", Code, "stdout", Out, "stderr", Err)), , , 8192)
		AssertTrue(Handle.start(), "The private native forward-proxy fixture must start")
		Started := A_TickCount
		while Observed.Length == 0 && !TickExpired64(Started, 45000) {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, Observed.Length, "The exact forward-proxy Job must settle once within its bound")
		if Observed.Length != 1
			return
		AssertEqual("", Observed[1]["stderr"], "Native refusal diagnostics must stay red")
		Prefix := "HTTP_FORWARD_PROXY_RECEIPT:"
		Receipt := 0, ReceiptCount := 0
		for Line in StrSplit(StrReplace(Observed[1]["stdout"], "`r`n", "`n"), "`n") {
			if SubStr(Line, 1, StrLen(Prefix)) == Prefix {
				ReceiptCount += 1
				Receipt := JsonParse(SubStr(Line, StrLen(Prefix) + 1))
			}
		}
		AssertEqual(1, ReceiptCount, "One physically settled fixture must publish one terminal receipt")
		AssertTrue(Receipt is Map)
		AssertEqual(1, Receipt.Get("schema_version", 0))
		AssertEqual(200, Receipt.Get("oracle_status", 0), "A received 403 or 407 cannot qualify the oracle")
		AssertTrue(Receipt.Get("oracle_body_exact", false), "The independent native oracle must receive its exact response")
		AssertTrue(Receipt.Get("route_admitted", false), "The actual credentialed proxy route must be admitted")
		AssertEqual(80, Receipt.Get("target_port", 0), "CONNECT's target is distinct from the settings proxy port")
		AssertTrue(Receipt.Get("settings_proxy_ephemeral", false))
		AssertEqual(2, Receipt.Get("authenticated", 0), "Both protocol controls must reach the owned proxy with the fixture identity")
		AssertEqual(0, Receipt.Get("proxy_failures", -1))
		AssertTrue(Receipt.Get("native_retired", false) && Receipt.Get("proxy_joined", false))
		AssertEqual(0, Receipt.Get("connect_refused", -1),
			"A plain HTTP API request must use the proxy's supported forward protocol; receipt=" . Observed[1]["stdout"])
		AssertEqual(2, Receipt.Get("forwarded", 0))
		AssertEqual(200, Receipt.Get("actual_status", 0))
		AssertTrue(Receipt.Get("actual_body_exact", false))
		AssertEqual(0, Observed[1]["exit"], "The actual forward request must complete after exact native retirement")
	} finally {
		if IsObject(Handle)
			AssertTrue(Handle.terminate(), "The exact forward-proxy fixture Job must physically retire")
	}
}
Test("network: authenticated HTTP proxy forwards an admitted remote HTTP API request (native-http-forward-proxy1)",
	_NativeHttpForwardProxy_Controls)
