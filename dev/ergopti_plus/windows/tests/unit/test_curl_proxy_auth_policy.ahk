; tests/unit/test_curl_proxy_auth_policy.ahk
_CurlAuth_Receipt() {
	return Map("schema_version", 1, "state", "ready", "backend", "curl",
		"child_quiesced", true, "capability", Map("tls_backend", "schannel",
			"sspi", true, "spnego", true, "ntlm", true, "version", "8.13.0"))
}
_CurlAuth_RefusesMissingNativeFeature() {
	for Field in ["tls_backend", "sspi", "spnego"] {
		Receipt := _CurlAuth_Receipt()
		Receipt["capability"].Delete(Field)
		AssertEqual("", _HTTP_CurlIntegratedProxyAuthConfig(Receipt), "native feature absence cannot be inferred from a version")
	}
	for Field in ["sspi", "spnego"] {
		Receipt := _CurlAuth_Receipt()
		Receipt["capability"][Field] := "1"
		AssertEqual("", _HTTP_CurlIntegratedProxyAuthConfig(Receipt), "string input cannot masquerade as an observed native feature")
	}
	Receipt := _CurlAuth_Receipt()
	Receipt["child_quiesced"] := false
	AssertEqual("", _HTTP_CurlIntegratedProxyAuthConfig(Receipt), "a live capability child cannot admit transport")
	Receipt := _CurlAuth_Receipt()
	Receipt["capability"]["tls_backend"] := "openssl"
	AssertEqual("", _HTTP_CurlIntegratedProxyAuthConfig(Receipt), "native Windows store support requires actual Schannel")
	Receipt := _CurlAuth_Receipt()
	Receipt["state"] := "unavailable"
	AssertEqual("", _HTTP_CurlIntegratedProxyAuthConfig(Receipt), "unavailable observation cannot be substituted by a guessed feature set")
}
_CurlAuth_IntegratedOnlyConfig() {
	Config := _HTTP_CurlIntegratedProxyAuthConfig(_CurlAuth_Receipt())
	AssertContains(Config, "proxy-negotiate`n")
	AssertContains(Config, 'proxy-user = ":"')
	for Forbidden in ["proxy-anyauth", "proxy-basic", "proxy-digest", "proxy-ntlm", "`nuser = ", "password"]
		AssertFalse(InStr(Config, Forbidden), "admission cannot broaden the native integrated-only mask")
}
Test("curl proxy auth: missing native features and unfinished owners refuse admission", _CurlAuth_RefusesMissingNativeFeature)
Test("curl proxy auth: sole Negotiate current-user config cannot permit ANYAUTH downgrade", _CurlAuth_IntegratedOnlyConfig)

_CurlAuth_CapabilityPhase(Raw) {
	if Type(Raw) != "String" || StrLen(Raw) > 256
		return ""
	try Fact := JsonParse(Raw)
	catch
		return ""
	if !(Fact is Map) || Fact.Count != 2 || Type(Fact.Get("diagnostic_version", "")) != "Integer" || Fact["diagnostic_version"] != 1
		return ""
	Phase := Fact.Get("phase", "")
	if Type(Phase) != "String" || !RegExMatch(Phase, "\A(?:setup_compile|setup_budget|native_start|native_wait|pipe_retirement|receipt_parse|child_retirement|settled)\z")
		return ""
	return Phase
}
_CurlAuth_EmitCapabilityPhase(Path) {
	try {
		if FileGetSize(Path) > 256
			return
		Phase := _CurlAuth_CapabilityPhase(FileRead(Path, "UTF-8"))
		if Phase != ""
			FileAppend("::notice title=Windows native capability diagnostic::phase=" . Phase . "`n", "*")
	}
}
_CurlAuth_CapabilityPhaseControls() {
	AssertEqual("setup_compile", _CurlAuth_CapabilityPhase('{"diagnostic_version":1,"phase":"setup_compile"}'), "cache projects only a fixed stage")
	for Raw in ['{"diagnostic_version":1,"phase":"setup_compile","message":"private"}',
		'{"diagnostic_version":1,"phase":"private provider name"}', '{"diagnostic_version":"1","phase":"native_wait"}',
		'{"schema_version":1,"budget_ms":8000}', '{"diagnostic_version":1,"phase":"native_wait\nprivate"}', "not JSON"]
		AssertEqual("", _CurlAuth_CapabilityPhase(Raw), "unknown cache bytes cannot become a native annotation")
}
Test("curl proxy auth: optional native phase cache has a closed annotation domain", _CurlAuth_CapabilityPhaseControls)

_CurlAuth_NativeCapabilityObservation() {
	global _VendorDir
	Directory := _SR_AcquireCaptureDirectory()
	Capture := Map("TmpFile", Directory . "output.tmp", "CaptureDir", Directory)
	Observed := []
	Handle := 0
	try {
		AssertTrue(FSWrite(Capture["TmpFile"], '{"schema_version":1,"budget_ms":8000}'), "owned native capability input must be staged")
		Handle := ShellRunner_SpawnTreeOwned(A_WinDir . "\System32\WindowsPowerShell\v1.0\powershell.exe",
			["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
				_VendorDir . "\ergopti_curl_capabilities_worker.ps1", "-InputPath", Capture["TmpFile"], "-DiagnosticPath", Capture["TmpFile"]],
			(Code, Out, Err) => Observed.Push(Map("exit", Code, "stdout", Out, "stderr", Err)), , , 8192)
		AssertTrue(Handle.start(), "native feature worker must actually start inside its owned Job")
		Started := A_TickCount
		while Observed.Length == 0 && !TickExpired64(Started, 10000) {
			_SR_TreePoll()
			Sleep(10)
		}
		if Observed.Length != 1 || Observed[1]["exit"] != 0
			_CurlAuth_EmitCapabilityPhase(Capture["TmpFile"])
		AssertEqual(1, Observed.Length, "the native capability worker must settle within the test deadline")
		AssertEqual(0, Observed[1]["exit"], "actual shipped curl must produce a closed native feature receipt")
		AssertEqual("", Observed[1]["stderr"], "native feature errors cannot be hidden")
		Receipt := JsonParse(Observed[1]["stdout"])
		AssertEqual("ready", Receipt["state"])
		AssertTrue(Receipt["child_quiesced"], "native curl --version child must physically settle")
		AssertEqual("schannel", Receipt["capability"]["tls_backend"], "actual shipped curl must expose Windows OS trust")
		AssertTrue(Receipt["capability"]["sspi"], "the actual shipped curl must support current-user SSPI")
		AssertTrue(Receipt["capability"]["spnego"], "sole Negotiate admission needs the actual native SPNEGO capability")
		AssertContains(_HTTP_CurlIntegratedProxyAuthConfig(Receipt), "proxy-negotiate`n")
	} finally {
		Retired := IsObject(Handle) ? Handle.terminate() : true
		AssertTrue(Retired, "the exact feature worker descendant tree must physically retire")
		if Retired
			AssertEqual(0, _SR_CaptureRemove(Capture), "owned private capability input must be removed after retirement")
	}
}
Test("curl proxy auth: actual System32 curl proves Schannel SSPI and SPNEGO in an owned native probe", _CurlAuth_NativeCapabilityObservation)
