; tests/unit/core/network/adapters/test_native_static_scheme_proxy.ahk
; A real, private WinHTTP oracle qualifies missing per-scheme mappings before
; either production selector is allowed to acknowledge DIRECT.
_NativeStaticSchemeProxy_Controls() {
	global _DriverDir, _VendorDir, _SharedDir
	Observed := [], Handle := 0
	try {
		Handle := ShellRunner_SpawnTreeOwned(_Updater_PowerShellPath(),
			["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
				_DriverDir . "\tests\fixtures\native_static_scheme_proxy.ps1",
				"-RoutesPath", _VendorDir . "\ergopti_network_routes.ps1",
				"-PolicyPath", _SharedDir . "\core\network\data\proxy_policy.json",
				"-UpdaterDefaultsPath", _SharedDir . "\updater\data\defaults.json"],
			(Code, Out, Err) => Observed.Push(Map("exit", Code, "stdout", Out, "stderr", Err)), , , 8192)
		AssertTrue(Handle.start(), "The private native static-scheme fixture must start")
		Started := A_TickCount
		while Observed.Length == 0 && !TickExpired64(Started, 45000) {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, Observed.Length, "The exact fixture Job must finish once within its total bound")
		if Observed.Length != 1
			return
		AssertEqual("", Observed[1]["stderr"], "Native startup and retirement failures must stay red")
		AssertContains(Observed[1]["stdout"], "NATIVE_STATIC_SCHEME_ORACLE:direct=1 absent_direct=1 matched_refused=1",
			"Actual WinHTTP must prove DIRECT and exclude implicit loopback bypass")
		Receipt := 0, ReceiptCount := 0
		for Line in StrSplit(StrReplace(Observed[1]["stdout"], "`r`n", "`n"), "`n") {
			if SubStr(Line, 1, 22) == "STATIC_SCHEME_RECEIPT:" {
				ReceiptCount += 1
				Receipt := JsonParse(SubStr(Line, 23))
			}
		}
		AssertEqual(1, ReceiptCount, "One settled fixture must publish one exact production receipt")
		AssertTrue(Receipt is Map, "The private fixture must publish a structured receipt")
		AssertEqual(1, Receipt.Get("schema_version", 0))
		AssertTrue(Receipt.Get("oracle", false) && Receipt.Get("servers_retired", false),
			"The owned receiver must join before publication")
		LegacyDirect := true
		for Scheme in ["http", "https"] {
			Other := Scheme == "http" ? "https" : "http"
			Config := Map("proxy", Other . "=proxy.invalid:8080", "bypass", "", "pac_url", "", "auto_detect", false)
			try Answer := SystemProxy_SelectStatic(Config, Scheme . "://example.invalid/", true)
			catch {
				LegacyDirect := false
				continue
			}
			LegacyDirect := LegacyDirect && Answer["proxy"] == ""
		}
		for Invalid in ["http=proxy.invalid:notaport", "https=proxy.invalid:notaport", "ftp=proxy.invalid:21"] {
			Config := Map("proxy", Invalid, "bypass", "", "pac_url", "", "auto_detect", false)
			AssertThrows(SystemProxy_SelectStatic.Bind(Config, "http://example.invalid/", true),
				"Malformed or unsupported static maps must stay refused")
		}
		AssertTrue(Receipt.Get("invalid_refused", false), "Native malformed-map controls must stay refused")
		AssertTrue(Receipt.Get("http_direct", false) && Receipt.Get("https_direct", false) && LegacyDirect,
			"Absent protocol mappings must remain DIRECT in PS and strict AHK selectors; native receipt="
			. Observed[1]["stdout"] . " legacy_direct=" . LegacyDirect)
		AssertEqual(0, Observed[1]["exit"], "The native production fixture must acknowledge every selector")
	} finally {
		if IsObject(Handle)
			AssertTrue(Handle.terminate(), "The exact static-scheme fixture Job must physically retire")
	}
}
Test("network: native static protocol maps preserve DIRECT for an absent scheme (native-static-scheme-proxy1)",
	_NativeStaticSchemeProxy_Controls)
