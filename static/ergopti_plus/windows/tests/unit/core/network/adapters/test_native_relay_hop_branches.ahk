; tests/unit/core/network/adapters/test_native_relay_hop_branches.ahk
; Real RelayHop branches retain CONNECT and SOCKS while HTTP forwarding changes.
_NativeRelayHopBranches_Controls() {
	global _DriverDir, _VendorDir, _SharedDir
	Observed := [], Handle := 0
	try {
		Handle := ShellRunner_SpawnTreeOwned(_Updater_PowerShellPath(),
			["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
				_DriverDir . "\tests\fixtures\native_relay_hop_branches.ps1",
				"-RoutesPath", _VendorDir . "\ergopti_network_routes.ps1",
				"-PolicyPath", _SharedDir . "\core\network\data\proxy_policy.json"],
			(Code, Out, Err) => Observed.Push(Map("exit", Code, "stdout", Out, "stderr", Err)), , , 8192)
		AssertTrue(Handle.start(), "The private actual-hop branch fixture must start")
		Started := A_TickCount
		while Observed.Length == 0 && !TickExpired64(Started, 45000) {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, Observed.Length, "The exact branch fixture Job must finish once within its total bound")
		if Observed.Length != 1
			return
		AssertEqual("", Observed[1]["stderr"], "Owned protocol or retirement failures must stay red")
		AssertEqual(0, Observed[1]["exit"], "Actual-hop fixture output: " . Observed[1]["stdout"])
		Receipt := 0, ReceiptCount := 0
		for Line in StrSplit(StrReplace(Observed[1]["stdout"], "`r`n", "`n"), "`n") {
			if SubStr(Line, 1, 25) == "RELAY_HOP_BRANCH_RECEIPT:" {
				ReceiptCount += 1
				Receipt := JsonParse(SubStr(Line, 26))
			}
		}
		AssertEqual(1, ReceiptCount, "Both joined protocol peers must publish one settled receipt")
		AssertTrue(Receipt is Map, "The actual-hop fixture must publish a structured receipt")
		AssertEqual(1, Receipt.Get("schema_version", 0))
		for Name, Expected in Map("independent_oracles", 3, "actual_hops", 2, "http_connect", 2,
			"http_authenticated", 2, "http_requests", 2, "socks_connect", 4, "socks_authenticated", 4,
			"socks_requests", 4, "domain_frames", 2, "ipv4_explicit_frames", 2)
			AssertEqual(Expected, Receipt.Get(Name, 0), "Exact branch observation: " . Name)
		AssertEqual(0, Receipt.Get("peer_failures", -1))
		AssertTrue(Receipt.Get("component_bodies_exact", false) && Receipt.Get("fixture_peers_joined", false),
			"The real CONNECT and SOCKS branches must deliver exact private bodies before their peers join")
	} finally {
		if IsObject(Handle)
			AssertTrue(Handle.terminate(), "The exact Job must physically retire both production hop listeners")
	}
}
Test("network: actual RelayHop preserves authenticated CONNECT and SOCKS branches (native-relay-hop-branches1)",
	_NativeRelayHopBranches_Controls)
