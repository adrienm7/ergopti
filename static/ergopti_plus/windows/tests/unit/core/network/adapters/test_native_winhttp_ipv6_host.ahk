; tests/unit/core/network/adapters/test_native_winhttp_ipv6_host.ahk
; Raw native calls isolate server-name spelling from routing and production URL handling.
_NativeWinHttpIpv6Host_Success(Observation) {
	return Observation.Get("completed", false) && Observation.Get("status", 0) == 200
		&& Observation.Get("body_exact", false) && Observation.Get("closed", false)
}
_NativeWinHttpIpv6Host_Controls() {
	global _DriverDir, _VendorDir
	Resolved := _LLMRemoteResolveEntry(Map("Provider", "openai", "Token", "owned-provider-key",
		"Model", "owned-model", "BaseUrl", "http://[2001:db8::123]/v1"))
	AssertTrue(Resolved is Map, "The actual provider resolver must admit the remote IPv6 HTTP base")
	AssertEqual("http://[2001:db8::123]/v1/models", RTrim(Resolved["BaseUrl"], "/") . "/models")
	Observed := [], Handle := 0
	try {
		Handle := ShellRunner_SpawnTreeOwned(_Updater_PowerShellPath(),
			["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
				_DriverDir . "\tests\fixtures\core\native_winhttp_ipv6_host.ps1",
				"-TransportPath", _VendorDir . "\ergopti_winhttp_transport.ps1"],
			(Code, Out, Err) => Observed.Push(Map("exit", Code, "stdout", Out, "stderr", Err)), , , 16384)
		AssertTrue(Handle.start(), "The private native IPv6 host oracle must start")
		Started := A_TickCount
		while Observed.Length == 0 && !TickExpired64(Started, 45000) {
			_SR_TreePoll()
			Sleep(10)
		}
		_TestAppendProgress("# native-winhttp-ipv6-host1 callbacks=" . Observed.Length)
		if Observed.Length == 1 {
			_TestAppendProgress("# native-winhttp-ipv6-host1 exit=" . Observed[1]["exit"])
			_TestAppendProgress("# native-winhttp-ipv6-host1 stdout=" . JsonStringLiteral(Observed[1]["stdout"]))
			_TestAppendProgress("# native-winhttp-ipv6-host1 stderr=" . JsonStringLiteral(Observed[1]["stderr"]))
		}
		AssertEqual(1, Observed.Length, "The exact IPv6 host oracle Job must finish once within its bound")
		if Observed.Length != 1
			return
		AssertEqual("", Observed[1]["stderr"], "Private oracle startup and cleanup failures must stay red")
		Receipt := 0, ReceiptCount := 0
		for Line in StrSplit(StrReplace(Observed[1]["stdout"], "`r`n", "`n"), "`n") {
			if SubStr(Line, 1, 26) == "WINHTTP_IPV6_HOST_RECEIPT:" {
				ReceiptCount += 1
				Receipt := JsonParse(SubStr(Line, 27))
			}
		}
		AssertEqual(1, ReceiptCount, "The joined private proxy must publish one terminal native-host receipt")
		AssertTrue(Receipt is Map)
		AssertEqual(1, Receipt.Get("schema_version", 0))
		AssertTrue(Receipt.Get("peer_joined", false))
		AssertEqual(0, Receipt.Get("peer_failures", -1))
		for Name in ["dns", "bracketed", "unbracketed", "uri_host_case", "refusing_proxy"]
			AssertTrue(Receipt[Name].Get("closed", false), "Every raw native handle must close: " . Name)
		AssertTrue(_NativeWinHttpIpv6Host_Success(Receipt["dns"]), "The same owned named proxy must serve the DNS control")
		AssertEqual(1, Receipt.Get("wire_dns", 0))
		AcceptedBracketed := _NativeWinHttpIpv6Host_Success(Receipt["bracketed"])
		AcceptedUnbracketed := _NativeWinHttpIpv6Host_Success(Receipt["unbracketed"])
		AssertTrue(AcceptedBracketed || AcceptedUnbracketed,
			"An independently accepted IPv6 server spelling is required before product classification")
		AssertTrue(Receipt.Get("ipv6_spelling_accepted", false))
		if AcceptedBracketed
			AssertEqual(1, Receipt.Get("wire_bracketed", 0))
		if AcceptedUnbracketed
			AssertEqual(1, Receipt.Get("wire_unbracketed", 0))
		Refused := Receipt["refusing_proxy"]
		AssertTrue(!Refused.Get("completed", true) && Refused.Get("native_error", 0) != 0
			&& Refused.Get("native_error", 0) != 12005,
			"The accepted spelling must fail at a reserved refusing proxy rather than reach an IPv6 origin")
		AssertTrue(_NativeWinHttpIpv6Host_Success(Receipt["uri_host_case"]),
			"The actual Uri.Host representation must independently receive an exact native response")
		AssertEqual(1, Receipt.Get("wire_uri_host", 0))
		for Name in ["actual_dns", "actual_ipv4"] {
			Control := Receipt[Name]
			AssertTrue(Control.Get("retired", false) && Control.Get("completed", false)
				&& Control.Get("status", 0) == 200 && Control.Get("body_exact", false),
				"Production DNS and IPv4 routing must remain valid: " . Name)
			AssertEqual(1, Receipt.Get("wire_" . Name, 0))
		}
		Actual := Receipt["actual"]
		AssertTrue(Actual.Get("retired", false), "The production native callbacks must retire")
		AssertTrue(Actual.Get("completed", false) && Actual.Get("status", 0) == 200
			&& Actual.Get("body_exact", false),
			"The production transport must preserve an accepted IPv6 server name; receipt=" . Observed[1]["stdout"])
		AssertEqual(1, Receipt.Get("wire_actual", 0))
		AssertEqual(0, Observed[1]["exit"])
	} finally {
		if IsObject(Handle)
			AssertTrue(Handle.terminate(), "The exact native host oracle Job must physically retire")
	}
}
Test("network: native WinHTTP IPv6 server names preserve owned proxy routing (native-winhttp-ipv6-host1)",
	_NativeWinHttpIpv6Host_Controls)
