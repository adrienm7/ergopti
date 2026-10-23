; tests/unit/modules/updater/test_updater_artifact_winhttp.ahk
; The real artifact download function over the real WinHTTP engine, against owned
; loopback services (no internet, no trust-store change). What the staging worker
; relies on when a transfer does not succeed: HTTPS only, closed receipts without a
; URL, no executable written, the private capture retired and no cleanup debt.
; Success over TLS needs a trusted root: the native CA staging cases cover it.

_UpdaterArtifactWinHttp_ExpectedControls() {
	return [
		"plain_http_artifact_url_is_refused_before_any_request",
		"untrusted_certificate_is_a_closed_tls_receipt_and_writes_nothing",
		"refused_connection_is_a_closed_connect_receipt",
		"refused_tunnel_names_the_proxy_in_a_closed_receipt",
		"basic_only_proxy_is_refused_without_credentials",
		"private_capture_directories_are_retired"
	]
}

_UpdaterArtifactWinHttp_Controls() {
	global _DriverDir, _VendorDir, _SharedDir
	Observed := []
	Handle := 0
	try {
		Handle := ShellRunner_SpawnTreeOwned(_Updater_PowerShellPath(),
			["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
				_DriverDir . "\tests\fixtures\updater_artifact_download_controls.ps1",
				"-VendorDirectory", _VendorDir,
				"-SchemaPath", _SharedDir . "\modules\network\managed_network.json",
				"-PolicyPath", _SharedDir . "\modules\network\proxy_policy.json",
				"-DefaultsPath", _SharedDir . "\modules\updater\defaults.json"],
			(Code, Out, Err) => Observed.Push(Map("exit", Code, "stdout", Out, "stderr", Err)), , , 16384)
		AssertTrue(Handle.start(), "the artifact download control fixture process must start")
		Started := A_TickCount
		while Observed.Length == 0 && !TickExpired64(Started, 120000) {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, Observed.Length, "the artifact download control fixture must finish once within its bound")
		if Observed.Length != 1
			return
		AssertEqual(0, Observed[1]["exit"], "fixture output: " . Observed[1]["stdout"] . " | " . Observed[1]["stderr"])
		Lines := StrSplit(StrReplace(Observed[1]["stdout"], "`r`n", "`n"), "`n")
		Expected := _UpdaterArtifactWinHttp_ExpectedControls()
		for Index, Name in Expected
			AssertEqual("CONTROL " . Name, Lines.Has(Index) ? Lines[Index] : "", "control " . Index . " must hold in order")
		AssertEqual("ARTIFACT_DOWNLOAD_CONTROLS:" . Expected.Length, Lines.Has(Expected.Length + 1) ? Lines[Expected.Length + 1] : "",
			"every expected control must have run")
		AssertEqual("", Observed[1]["stderr"], "the fixture must not write errors")
	} finally {
		if IsObject(Handle)
			AssertTrue(Handle.terminate(), "the artifact download control fixture Job must physically retire")
	}
}
Test("updater artifact: the real download over real WinHTTP refuses cleanly and writes nothing",
	_UpdaterArtifactWinHttp_Controls)
