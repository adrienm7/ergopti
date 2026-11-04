; tests/unit/platform/network/test_proxy_override.ahk

; ==============================================================================
; MODULE: Proxy Override Setting Controls
; DESCRIPTION:
; The vectors of _shared/lua/test/network_proxy_override_contract.lua replayed on
; the Windows twin, and the route owners of the adapter under each choice. The real
; workers through the fake network are tools/test/test-windows-proxy-override-e2e.cjs.
; ==============================================================================

; Runs a body with one published value and always leaves the driver on automatic.
_TPO_WithPublished(Stored, Body) {
	Published := ProxyOverride_Publish(Stored)
	try
		Body.Call(Published)
	finally
		ProxyOverride_Publish("")
}

_TPO_Parse() {
	Assert(ProxyOverride_Declaration()["default"] == "", "automatic is the declared default")
	AssertEqual(ProxyOverride_Parse("")["mode"], "automatic")
	AssertEqual(ProxyOverride_Parse("  ")["mode"], "automatic")
	AssertEqual(ProxyOverride_Parse("direct")["mode"], "direct")
	AssertEqual(ProxyOverride_Canonical(ProxyOverride_Parse(" Direct ")), "direct")
	for Relay in ["http://proxy.corp.invalid:3128", "https://proxy.corp.invalid:443", "socks5h://127.0.0.1:1080",
			"http://user:p%40ss@proxy.corp.invalid:8080", "http://[::1]:3128"] {
		Choice := ProxyOverride_Parse("  " . Relay . "`t")
		Assert(Choice is Map && Choice["mode"] == "relay", Relay)
		AssertEqual(Choice["relay"], Relay)
		AssertEqual(ProxyOverride_Canonical(Choice), Relay)
	}
	for Value in ["proxy.corp.invalid:3128", "http://proxy.corp.invalid", "ftp://proxy.invalid:21",
			"http://proxy.invalid:70000", "http://proxy.invalid:3128/path", "DIRECT; PROXY a:1", 3128, true]
		AssertEqual(ProxyOverride_Parse(Value), 0, "refused: " . String(Value))
}

; Every relay of the shared grammar is published as it is, for the route owner's hop.
_TPO_WindowsReach() {
	for Relay in ["http://proxy.corp.invalid:3128", "http://[::1]:3128", "https://proxy.corp.invalid:443",
			"socks5h://127.0.0.1:1080", "http://user:p%40ss@proxy.corp.invalid:8080"]
		_TPO_WithPublished(Relay, _TPO_AssertPublishedRelay.Bind(Relay))
}

_TPO_AssertPublishedRelay(Relay, Published) {
	Assert(Published, Relay)
	AssertEqual(_ProxyOverridePublished, Relay)
	AssertEqual(EnvGet(PROXY_OVERRIDE_ENVIRONMENT), "", "the driver's own environment stays out of it")
	AssertEqual(ProxyOverride_Current()["relay"], Relay)
}

; What run_command and Run see while a relay with a password is in force: nothing.
_TPO_ChildrenSeeNothing(Relay, *) {
	AssertEqual(EnvGet(PROXY_OVERRIDE_ENVIRONMENT), "", "the driver's own environment")
	Name := PROXY_OVERRIDE_ENVIRONMENT
	Command := _UA_Run("if defined " . Name . " (echo inherited) else (echo absent)", "copy")
	AssertTrue(Command["started"] && Command["finished"], "the run_command child ran")
	AssertContains(Command["copied"][1], "absent", "a run_command child does not inherit it")
	Path := A_Temp . "\ergopti_test_proxy_child_" . ProcessExist() . ".txt"
	try {
		AssertEqual(0, RunWait('"' . A_ComSpec . '" /d /c set > "' . Path . '"', , "Hide"), "the Run child ran")
		Seen := FileRead(Path)
		AssertTrue(InStr(Seen, "COMSPEC=") > 0, "the child printed its environment")
		AssertFalse(InStr(Seen, Name), "a Run child does not inherit it")
		AssertFalse(InStr(Seen, "tpo-secret"), "nor the password")
	} finally {
		if FileExist(Path)
			FileDelete(Path)
	}
}

_TPO_NoChildInherits() {
	Relay := "http://user:tpo-secret@proxy.invalid:3128"
	_TPO_WithPublished(Relay, _TPO_ChildrenSeeNothing.Bind(Relay))
}

; Only the worker's own environment block carries the choice.
_TPO_WorkerEnvironment() {
	Relay := "http://user:tpo-secret@proxy.invalid:3128"
	_TPO_WithPublished(Relay, _TPO_AssertWorkerBlock.Bind(Relay))
	_TPO_WithPublished("", (*) => _TPO_AssertBlockHolds(PROXY_OVERRIDE_ENVIRONMENT . "=", "automatic hides an inherited value"))
}

; A relay with credentials is stored as an envelope; everything else stays readable.
_TPO_Sealed() {
	Relay := "http://user:tpo-secret@proxy.invalid:3128"
	Envelope := ProxyOverride_Seal(Relay)
	Assert(ProxyOverride_IsSealed(Envelope), "an envelope")
	AssertFalse(InStr(Envelope, "tpo-secret") || InStr(Envelope, "proxy.invalid"), "nothing of the relay is readable")
	for Value in ["", "direct", "http://proxy.invalid:3128"]
		AssertEqual(ProxyOverride_Seal(Value), Value, "nothing to protect")
	_TPO_WithPublished(Envelope, _TPO_AssertOpened.Bind(Relay))
	; A file copied to another account: the blob does not open and is never automatic.
	Foreign := SubStr(Envelope, 1, -8) . (SubStr(Envelope, -8, 1) == "A" ? "B" : "A") . SubStr(Envelope, -7)
	_TPO_WithPublished(Foreign, _TPO_AssertPublishedRefused)
	_TPO_WithPublished("dpapi:not-base64", _TPO_AssertPublishedRefused)
}

_TPO_AssertOpened(Relay, Published) {
	Assert(Published, "the envelope opens")
	AssertEqual(ProxyOverride_Current()["relay"], Relay)
	AssertEqual(_ProxyOverrideStored, Relay, "the menu row shows what the user typed")
}

; A worker stays in its Job: the private entry is the tree-owned one.
_TPO_WorkerIsTreeOwned() {
	AssertContains(_DriverFuncBody("ProxyOverride_SpawnWorker"), "ShellRunner_SpawnTreeOwnedPrivate(")
	AssertContains(_DriverFuncBody("ShellRunner_SpawnTreeOwnedPrivate"), "_SR_NewTreeOwnedTask(")
	for Name in ["OllamaInstallFiles_Spawn", "_Updater_StartStagingWorker"]
		AssertContains(_DriverFuncBody(Name), "ProxyOverride_SpawnWorker", Name)
	AssertFalse(InStr(_DriverSourceConcat(), 'EnvSet(PROXY_OVERRIDE_ENVIRONMENT,'), "the value never enters this process")
}

_TPO_AssertWorkerBlock(Relay, *) {
	_TPO_AssertBlockHolds(PROXY_OVERRIDE_ENVIRONMENT . "=" . Relay, "the worker receives the relay")
	_TPO_AssertBlockHolds("PSModulePath=" . ShellRunner_WinPsModulePath(), "and the native module path")
}

_TPO_AssertBlockHolds(Row, Reason) {
	Block := ProxyOverride_WorkerEnvironment()
	At := Block.Ptr
	while (Entry := StrGet(At, "UTF-16")) != "" {
		if (Entry == Row)
			return
		At += (StrLen(Entry) + 1) * 2
	}
	Assert(false, Reason)
}

; A relay with credentials reaches the worker through its environment, not its file.
_TPO_NoCredentialInTheInputFile() {
	Assert(ProxyOverride_CarriesCredentials("socks5://user:secret@proxy.invalid:1080"), "userinfo")
	Assert(!ProxyOverride_CarriesCredentials("socks5://proxy.invalid:1080"), "no userinfo")
	Http := CurlAsyncRequest()
	Http.SetProxy("https://user:secret@proxy.invalid:443")
	AssertEqual(Http.Proxy, "https://user:secret@proxy.invalid:443", "the request accepts every override relay")
	AssertContains(_DriverSourceConcat(), 'ProxyOverride_CarriesCredentials(this.Proxy) ? "override" : this.Proxy',
		"the input file holds a token")
}

_TPO_AssertPublishedRefused(Published) {
	Assert(!Published, "the stored value is refused")
	AssertEqual(_ProxyOverridePublished, PROXY_OVERRIDE_REFUSED_TOKEN)
	AssertEqual(ProxyOverride_Current(), 0)
}

_TPO_Published() {
	; A value the driver cannot use is published as the refused token, never as automatic.
	for Stored in ["proxy.corp.invalid:3128", "ftp://proxy.invalid:21", 3128]
		_TPO_WithPublished(Stored, _TPO_AssertPublishedRefused)
	_TPO_WithPublished(" DIRECT ", (Published) => (
		Assert(Published, "direct"),
		AssertEqual(_ProxyOverridePublished, "direct"),
		AssertEqual(ProxyOverride_Current()["mode"], "direct")))
	_TPO_WithPublished("", (Published) => (
		Assert(Published, "automatic"),
		AssertEqual(_ProxyOverridePublished, ""),
		AssertEqual(ProxyOverride_Current()["mode"], "automatic")))
}

; Fails the test when the system or the environment was asked at all.
_TPO_NoSystem(*) {
	throw Error("An override must not read the system settings.")
}

_TPO_CurlRoute(Url) {
	Route := 0
	SystemProxy_ResolveCurlAsync(Url, (Selection) => (Route := Selection), _TPO_NoSystem, 0, _TPO_NoSystem)
	Assert(Route is Map, "the override answers at once")
	return Route
}

_TPO_Precedence() {
	Url := "https://registry.invalid/v2/"
	_TPO_WithPublished("http://proxy.corp.invalid:3128", (*) => _TPO_AssertRelay(Url))
	_TPO_WithPublished("direct", (*) => _TPO_AssertDirect(Url))
	_TPO_WithPublished("not a proxy", (*) => _TPO_AssertRefused(Url))
}

; The same answers network_proxy_policy.py gives from proxy_policy.json.
_TPO_LoopbackRanges() {
	for Url in ["http://127.0.0.1/", "http://127.255.0.9:8080/", "http://127.1.2.3/x", "http://localhost/",
			"http://LOCALHOST:1/", "http://printer.localhost/", "http://[::1]:11435/", "http://[0:0:0:0:0:0:0:1]/",
			"http://[0::1]/"]
		Assert(SystemProxy_IsLoopbackUrl(Url), "loopback: " . Url)
	for Url in ["http://128.0.0.1/", "http://126.255.255.255/", "http://127.0.0.256/", "http://127.000.0.1/",
			"http://127.1/", "http://localhost.evil.invalid/", "http://notlocalhost/", "http://.localhost/",
			"http://[::2]/", "http://[1::1]/", "http://[::]/", "https://registry.invalid/"]
		Assert(!SystemProxy_IsLoopbackUrl(Url), "not loopback: " . Url)
}

_TPO_AssertLoopbackRoute() {
	; The whole range stays direct under a relay, and through the curl route too.
	for LocalUrl in ["http://127.9.9.9:8080/", "http://app.localhost/"] {
		AssertEqual(SystemProxy_ForUrl(LocalUrl, _TPO_NoSystem), "")
		AssertEqual(_TPO_CurlRoute(LocalUrl)["source"], "loopback")
	}
}

_TPO_AssertRelay(Url) {
	_TPO_AssertLoopbackRoute()
	Route := _TPO_CurlRoute(Url)
	AssertEqual(Route["proxy"], "http://proxy.corp.invalid:3128")
	AssertEqual(Route["source"], "override")
	Assert(Route["ok"] && !Route["inherit"], "a relay is one selected route")
	AssertEqual(SystemProxy_ForUrl(Url, _TPO_NoSystem), "http://proxy.corp.invalid:3128")
	Answer := 0
	SystemProxy_ResolveAsync([Url], (Resolved) => (Answer := Resolved), _TPO_NoSystem)
	Assert(Answer is Map && Answer["_proxy_resolved"], "resolved at once")
	AssertEqual(Answer[Url], "http://proxy.corp.invalid:3128")
	; Loopback stays direct whatever the override.
	for LocalUrl in ["http://127.0.0.1:11435/api/pull", "http://localhost:11435/"]
		AssertEqual(SystemProxy_ForUrl(LocalUrl, _TPO_NoSystem), "")
	AssertEqual(_TPO_CurlRoute("http://127.0.0.1:11435/api/pull")["source"], "loopback")
}

_TPO_AssertDirect(Url) {
	Route := _TPO_CurlRoute(Url)
	AssertEqual(Route["proxy"], "")
	AssertEqual(Route["source"], "override")
	AssertEqual(SystemProxy_ForUrl(Url, _TPO_NoSystem), "")
}

_TPO_AssertRefused(Url) {
	Route := _TPO_CurlRoute(Url)
	Assert(!Route["ok"], "a refused value refuses the download")
	AssertEqual(Route["source"], "override_refused")
	Answer := 0
	SystemProxy_ResolveAsync([Url], (Resolved) => (Answer := Resolved), _TPO_NoSystem)
	Assert(Answer is Map && !Answer["_proxy_resolved"], "unresolved")
	Threw := false
	try SystemProxy_ForUrl(Url, _TPO_NoSystem)
	catch
		Threw := true
	Assert(Threw, "SystemProxy_ForUrl refuses")
}

_TPO_Automatic() {
	; Automatic keeps the order: the exported relay, then the system settings.
	Route := 0
	EnvFn := (Name) => Name = "HTTPS_PROXY" ? "http://exported.invalid:8080" : ""
	SystemProxy_ResolveCurlAsync("https://registry.invalid/", (Selection) => (Route := Selection), _TPO_NoSystem, 0, EnvFn)
	AssertEqual(Route["source"], "environment")
	SystemConfig := () => Map("auto_detect", false, "pac_url", "", "proxy", "system.invalid:8080", "bypass", "")
	AssertEqual(SystemProxy_ForUrl("https://registry.invalid/", SystemConfig), "http://system.invalid:8080")
}

_TPO_Row(Stored, Typed, SetResult := true) {
	State := Map("shown", [], "writes", [], "initial", "")
	Ports := Map("get", () => Stored,
		"set", (Value) => (State["writes"].Push(Value), SetResult),
		"prompt", (Title, Text, Initial) => (State["initial"] := Initial, Typed),
		"error", (Title, Text) => State["shown"].Push("error:" . Text),
		"info", (Title, Text) => State["shown"].Push("info:" . Text))
	State["saved"] := ProxyOverride_Edit(Ports)
	return State
}

_TPO_MenuRow() {
	Row := _TPO_Row("", "  http://proxy.corp.invalid:3128 ")
	Assert(Row["saved"], "a relay is saved")
	AssertEqual(Row["writes"][1], "http://proxy.corp.invalid:3128")
	AssertEqual(Row["shown"][1], "info:" . t("proxy_override.saved_relay"))

	Row := _TPO_Row("direct", "")
	AssertEqual(Row["initial"], "direct")
	AssertEqual(Row["writes"][1], "")
	AssertEqual(Row["shown"][1], "info:" . t("proxy_override.saved_automatic"))

	Row := _TPO_Row("direct", "proxy.corp.invalid:3128")
	Assert(!Row["saved"] && Row["writes"].Length == 0, "an invalid value is never written")
	AssertEqual(Row["shown"][1], "error:" . t("proxy_override.invalid"))

	for Relay in ["socks5://127.0.0.1:1080", "https://proxy.corp.invalid:443", "http://user:secret@proxy.corp.invalid:8080"] {
		Row := _TPO_Row("", Relay)
		Assert(Row["saved"], Relay . " is saved")
		AssertEqual(Row["writes"][1], Relay)
		AssertEqual(Row["shown"][1], "info:" . t("proxy_override.saved_relay"))
	}

	Row := _TPO_Row("direct", false)
	Assert(!Row["saved"] && Row["writes"].Length == 0 && Row["shown"].Length == 0, "a cancel changes nothing")

	Row := _TPO_Row("", "direct", false)
	Assert(!Row["saved"], "a refused write is not a save")
	AssertEqual(Row["shown"][1], "error:" . t("proxy_override.not_saved"))
}

; The owner holds the timer, and the entry only asks for it once the boot is ready.
_TPO_SealScheduledAfterReady() {
	Scheduled := []
	ProxyOverride_ScheduleSealAtStart((Seal) => Scheduled.Push(Seal))
	AssertEqual(1, Scheduled.Length, "one sealing is scheduled")
	Assert(Scheduled[1] == ProxyOverride_SealStoredAtStart, "what is scheduled is the sealing itself")
	Assert(RegExMatch(_DriverSourceConcat(), 's)_DriverBootPhase := "ready".*\RProxyOverride_ScheduleSealAtStart\(\)'),
		"a commit must not replace the snapshot the boot readers hold")
}

Test("proxy override: the shared grammar replayed", _TPO_Parse)
Test("proxy override: the owner schedules the sealing once the boot is ready", _TPO_SealScheduledAfterReady)
Test("proxy override: every relay of the grammar is published for the route owner", _TPO_WindowsReach)
Test("proxy override: a relay with credentials stays out of the worker's input file", _TPO_NoCredentialInTheInputFile)
Test("proxy override: run_command and Run children never inherit it", _TPO_NoChildInherits)
Test("proxy override: only a worker's private environment carries it", _TPO_WorkerEnvironment)
Test("proxy override: a worker stays tree-owned and the value never enters this process", _TPO_WorkerIsTreeOwned)
Test("proxy override: credentials are sealed with DPAPI and a foreign envelope is refused", _TPO_Sealed)
Test("proxy override: a refused value is published as a refusal, never as automatic", _TPO_Published)
Test("proxy override: every adapter route owner honours the override before the system", _TPO_Precedence)
Test("proxy override: automatic keeps the exported relay, then the system settings", _TPO_Automatic)
Test("proxy override: loopback is the policy's ranges, not three names", _TPO_LoopbackRanges)
Test("proxy override: the menu row validates, stores and says what happened", _TPO_MenuRow)
