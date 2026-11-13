; tests/unit/platform/network/test_native_ipv6_http_socks.ahk
; A real remote API URL retains its IPv6 host and default HTTP port through SOCKS.
_NativeIpv6HttpSocks_Controls(TargetPort := 80) {
	global _DriverDir, _VendorDir, _SharedDir
	BaseUrl := "http://[2001:db8::123]" . (TargetPort == 80 ? "" : ":" . TargetPort) . "/v1"
	Resolved := _LLMRemoteResolveEntry(Map("Provider", "openai", "Token", "owned-provider-key",
		"Model", "owned-model", "BaseUrl", BaseUrl))
	AssertTrue(Resolved is Map, "The actual API resolver must admit a nonloopback IPv6 HTTP base")
	Endpoint := _LLMRemoteBuildUrl(Resolved["BaseUrl"], Resolved["Format"], Resolved["Token"], Resolved["Model"])
	AssertEqual(BaseUrl . "/chat/completions", Endpoint)
	AssertFalse(SystemProxy_IsLoopbackUrl(Endpoint), "The admitted IPv6 provider must reach proxy routing")
	AssertEqual(BaseUrl . "/models", RTrim(Resolved["BaseUrl"], "/") . "/models")
	Observed := [], Handle := 0
	try {
		Handle := ShellRunner_SpawnTreeOwned(_Updater_PowerShellPath(),
			["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
				_DriverDir . "\tests\fixtures\native_ipv6_http_socks.ps1",
				"-RoutesPath", _VendorDir . "\ergopti_network_routes.ps1",
				"-TransportPath", _VendorDir . "\ergopti_winhttp_transport.ps1",
				"-PolicyPath", _SharedDir . "\core\network\data\proxy_policy.json",
				"-UpdaterDefaultsPath", _SharedDir . "\updater\data\defaults.json", "-TargetPort", String(TargetPort)],
			(Code, Out, Err) => Observed.Push(Map("exit", Code, "stdout", Out, "stderr", Err)), , , 8192)
		AssertTrue(Handle.start(), "The private IPv6 SOCKS fixture must start")
		Started := A_TickCount
		while Observed.Length == 0 && !TickExpired64(Started, 45000) {
			_SR_TreePoll()
			Sleep(10)
		}
		; Persist the private child's bounded streams before a missing receipt
		; assertion can hide the actual setup or production failure.
		_TestAppendProgress("# native-ipv6-http-socks1 callbacks=" . Observed.Length)
		if Observed.Length == 1 {
			_TestAppendProgress("# native-ipv6-http-socks1 exit=" . Observed[1]["exit"])
			_TestAppendProgress("# native-ipv6-http-socks1 stdout=" . JsonStringLiteral(Observed[1]["stdout"]))
			_TestAppendProgress("# native-ipv6-http-socks1 stderr=" . JsonStringLiteral(Observed[1]["stderr"]))
		}
		AssertEqual(1, Observed.Length, "The exact IPv6 fixture Job must settle once within its bound")
		if Observed.Length != 1
			return
		AssertEqual("", Observed[1]["stderr"], "Native startup and retirement failures must stay red")
		Receipt := 0, ReceiptCount := 0
		for Line in StrSplit(StrReplace(Observed[1]["stdout"], "`r`n", "`n"), "`n") {
			if SubStr(Line, 1, 24) == "IPV6_HTTP_SOCKS_RECEIPT:" {
				ReceiptCount += 1
				Receipt := JsonParse(SubStr(Line, 25))
			}
		}
		AssertEqual(1, ReceiptCount, "The joined receiver must publish one exact IPv6 protocol receipt")
		AssertTrue(Receipt is Map, "The private native fixture must publish a structured receipt")
		AssertEqual(1, Receipt.Get("schema_version", 0))
		AssertEqual(200, Receipt.Get("oracle_status", 0))
		AssertTrue(Receipt.Get("oracle_body_exact", false) && Receipt.Get("route_admitted", false)
			&& Receipt.Get("native_retired", false) && Receipt.Get("proxy_joined", false))
		AssertEqual(TargetPort, Receipt.Get("target_port", 0))
		AssertEqual(2, Receipt.Get("greetings", 0))
		AssertEqual(0, Receipt.Get("proxy_failures", -1))
		AssertTrue(Receipt.Get("connect_frames", 0) == 2 && Receipt.Get("requests", 0) == 2
			&& Receipt.Get("early_close", -1) == 0 && Receipt.Get("actual_status", 0) == 200
			&& Receipt.Get("actual_body_exact", false),
			"The IPv6 authority must preserve its actual HTTP port; native receipt=" . Observed[1]["stdout"])
		AssertEqual(0, Observed[1]["exit"])
	} finally {
		if IsObject(Handle)
			AssertTrue(Handle.terminate(), "The exact IPv6 fixture Job must physically retire")
	}
}
Test("network: admitted IPv6 HTTP API retains default port through real SOCKS (native-ipv6-http-socks1)",
	_NativeIpv6HttpSocks_Controls)
Test("network: admitted IPv6 HTTP API preserves explicit nondefault destination port through SOCKS (native-ipv6-http-socks-port1)",
	_NativeIpv6HttpSocks_Controls.Bind(18080))
