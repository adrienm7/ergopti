; tests/unit/test_curl_proxy_discovery.ahk
; Actual production parser/lease bodies with controlled native process outputs.
_CurlProxyDiscoveryOwnedControls() {
	global _DriverDir
	Observed := []
	Handle := 0
	try {
		Handle := ShellRunner_SpawnTreeOwned(_Updater_PowerShellPath(),
			["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
				_DriverDir . "\tests\fixtures\curl_proxy_discovery_controls.ps1", "-EnginePath",
				_DriverDir . "\vendor\ergopti_curl_attempt.ps1"],
			(Code, Out, Err) => Observed.Push(Map("exit", Code, "stdout", Out, "stderr", Err)))
		AssertTrue(Handle.start(), "production discovery component owner starts")
		Started := A_TickCount
		while Observed.Length == 0 && !TickExpired64(Started, 15000) {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, Observed.Length, "exact child and Job retire before receiving")
		AssertEqual(0, Observed[1]["exit"])
		AssertEqual("CURL_PROXY_DISCOVERY_CONTROLLED_PORTS:34", Trim(Observed[1]["stdout"], "`r`n "))
		AssertEqual("", Observed[1]["stderr"])
	} finally {
		if IsObject(Handle)
			AssertTrue(Handle.terminate(), "production discovery component Job physically retires")
	}
}
Test("curl proxy: anonymous CONNECT and one requalified selected transport (proxy-connect-discovery-owner)", _CurlProxyDiscoveryOwnedControls)
