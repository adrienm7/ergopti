; tests/unit/platform/network/test_native_ipv6_relay_upstream.ahk
; A strict private IPv6 proxy has an explicit-family oracle and a real native route.
_NativeIpv6RelayUpstream_Controls() {
	global _DriverDir, _VendorDir, _SharedDir
	Observed := [], Handle := 0
	try {
		Handle := ShellRunner_SpawnTreeOwned(_Updater_PowerShellPath(),
			["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
				_DriverDir . "\tests\fixtures\native_relay_hop_branches.ps1", "-Ipv6Upstream",
				"-RoutesPath", _VendorDir . "\ergopti_network_routes.ps1",
				"-PolicyPath", _SharedDir . "\modules\network\proxy_policy.json",
				"-TransportPath", _VendorDir . "\ergopti_winhttp_transport.ps1",
				"-UpdaterDefaultsPath", _SharedDir . "\modules\updater\defaults.json"],
			(Code, Out, Err) => Observed.Push(Map("exit", Code, "stdout", Out, "stderr", Err)), , , 16384)
		AssertTrue(Handle.start(), "The private IPv6 upstream fixture must start")
		Started := A_TickCount
		while Observed.Length == 0 && !TickExpired64(Started, 45000) {
			_SR_TreePoll()
			Sleep(10)
		}
		_TestAppendProgress("# native-ipv6-relay-upstream1 callbacks=" . Observed.Length)
		if Observed.Length == 1 {
			_TestAppendProgress("# native-ipv6-relay-upstream1 exit=" . Observed[1]["exit"])
			_TestAppendProgress("# native-ipv6-relay-upstream1 stdout=" . JsonStringLiteral(Observed[1]["stdout"]))
			_TestAppendProgress("# native-ipv6-relay-upstream1 stderr=" . JsonStringLiteral(Observed[1]["stderr"]))
		}
		AssertEqual(1, Observed.Length, "The exact IPv6 upstream fixture Job must finish once within its bound")
		if Observed.Length != 1
			return
		AssertEqual("", Observed[1]["stderr"])
		Receipt := 0, ReceiptCount := 0
		for Line in StrSplit(StrReplace(Observed[1]["stdout"], "`r`n", "`n"), "`n") {
			if SubStr(Line, 1, 28) == "IPV6_RELAY_UPSTREAM_RECEIPT:" {
				ReceiptCount += 1
				Receipt := JsonParse(SubStr(Line, 29))
			}
		}
		AssertEqual(1, ReceiptCount, "The owned peers must publish one settled upstream receipt")
		AssertTrue(Receipt is Map)
		AssertEqual(1, Receipt.Get("schema_version", 0))
		AssertEqual(0, Receipt["setup_failure"].Count, "Fixture setup must qualify before product classification")
		AssertTrue(Receipt.Get("ipv4_oracle", false) && Receipt.Get("ipv6_oracle", false)
			&& Receipt.Get("ipv6_listener_strict", false), "An IPv6-only listener and explicit IPv6 client must first qualify")
		for Name in ["witness", "subject"] {
			AssertTrue(Receipt[Name].Get("route_admitted", false) && Receipt[Name].Get("retired", false),
				"The real route and native callbacks must settle: " . Name)
		}
		for Name in ["ipv4_peer", "ipv6_peer"]
			AssertTrue(Receipt[Name].Get("joined", false) && Receipt[Name].Get("failures", -1) == 0)
		Witness := Receipt["witness"]
		AssertTrue(Witness.Get("completed", false) && Witness.Get("status", 0) == 200 && Witness.Get("body_exact", false))
		for Name in ["connections", "authenticated", "requests", "domain_frames"]
			AssertEqual(2, Receipt["ipv4_peer"].Get(Name, 0), "The IPv4 witness must include oracle and actual route: " . Name)
		Subject := Receipt["subject"]
		AssertTrue(Subject.Get("completed", false) && Subject.Get("status", 0) == 200 && Subject.Get("body_exact", false),
			"An admitted IPv6 proxy must receive the native routed request; receipt=" . Observed[1]["stdout"])
		for Name in ["connections", "authenticated", "requests", "domain_frames"]
			AssertEqual(2, Receipt["ipv6_peer"].Get(Name, 0), "The IPv6 peer must include oracle and actual route: " . Name)
		AssertEqual(0, Observed[1]["exit"])
	} finally {
		if IsObject(Handle)
			AssertTrue(Handle.terminate(), "The exact Job must physically retire both production hops")
	}
}
Test("network: a strict IPv6 SOCKS upstream accepts the actual native route (native-ipv6-relay-upstream1)",
	_NativeIpv6RelayUpstream_Controls)
