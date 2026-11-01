; tests/unit/platform/network/test_proxy_override.ahk

; ==============================================================================
; MODULE: Proxy Override Setting Controls
; DESCRIPTION:
; The vectors of _shared/lua/test/network_proxy_override_contract.lua replayed on
; the Windows twin, and the route owners of the adapter under each choice. The real
; workers through the fake network are tools/test/test-windows-proxy-override-e2e.cjs.
; ==============================================================================

; Runs a body with one published value and always leaves the process variable clean.
_TPO_WithPublished(Stored, Body) {
	Published := ProxyOverride_Publish(Stored)
	try
		Body.Call(Published)
	finally
		EnvSet(PROXY_OVERRIDE_ENVIRONMENT, "")
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

_TPO_WindowsReach() {
	for Relay in ["http://proxy.corp.invalid:3128", "http://[::1]:3128"]
		Assert(ProxyOverride_WindowsCanRoute(ProxyOverride_Parse(Relay)), Relay)
	for Relay in ["https://proxy.corp.invalid:443", "socks5h://127.0.0.1:1080", "http://user:p%40ss@proxy.corp.invalid:8080"]
		Assert(!ProxyOverride_WindowsCanRoute(ProxyOverride_Parse(Relay)), Relay)
	Assert(ProxyOverride_WindowsCanRoute(ProxyOverride_Parse("")), "automatic")
	Assert(ProxyOverride_WindowsCanRoute(ProxyOverride_Parse("direct")), "direct")
}

_TPO_AssertPublishedRefused(Published) {
	Assert(!Published, "the stored value is refused")
	AssertEqual(EnvGet(PROXY_OVERRIDE_ENVIRONMENT), PROXY_OVERRIDE_REFUSED_TOKEN)
	AssertEqual(ProxyOverride_Current(), 0)
}

_TPO_Published() {
	; A value the driver cannot use is published as the refused token, never as automatic.
	for Stored in ["proxy.corp.invalid:3128", "socks5://127.0.0.1:1080", 3128]
		_TPO_WithPublished(Stored, _TPO_AssertPublishedRefused)
	_TPO_WithPublished(" DIRECT ", (Published) => (
		Assert(Published, "direct"),
		AssertEqual(EnvGet(PROXY_OVERRIDE_ENVIRONMENT), "direct"),
		AssertEqual(ProxyOverride_Current()["mode"], "direct")))
	_TPO_WithPublished("", (Published) => (
		Assert(Published, "automatic"),
		AssertEqual(EnvGet(PROXY_OVERRIDE_ENVIRONMENT), ""),
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

_TPO_AssertRelay(Url) {
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

	Row := _TPO_Row("", "socks5://127.0.0.1:1080")
	Assert(!Row["saved"] && Row["writes"].Length == 0, "a relay WinHTTP cannot reach is never written")
	AssertEqual(Row["shown"][1], "error:" . t("proxy_override.windows_plain_http_only"))

	Row := _TPO_Row("direct", false)
	Assert(!Row["saved"] && Row["writes"].Length == 0 && Row["shown"].Length == 0, "a cancel changes nothing")

	Row := _TPO_Row("", "direct", false)
	Assert(!Row["saved"], "a refused write is not a save")
	AssertEqual(Row["shown"][1], "error:" . t("proxy_override.not_saved"))
}

Test("proxy override: the shared grammar replayed", _TPO_Parse)
Test("proxy override: WinHTTP reaches a plain http relay only", _TPO_WindowsReach)
Test("proxy override: a refused value is published as a refusal, never as automatic", _TPO_Published)
Test("proxy override: every adapter route owner honours the override before the system", _TPO_Precedence)
Test("proxy override: automatic keeps the exported relay, then the system settings", _TPO_Automatic)
Test("proxy override: the menu row validates, stores and says what happened", _TPO_MenuRow)
