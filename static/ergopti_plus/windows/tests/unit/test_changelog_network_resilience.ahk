; tests/unit/test_changelog_network_resilience.ahk

; ==============================================================================
; MODULE: Changelog Network Resilience Tests
; DESCRIPTION:
; On a corporate network the releases window spun forever while github.com
; worked in the browser: curl ignored the Windows proxy, api.github.com was
; the only source, and a proxy block page could reach the page as script.
; These tests drive the Windows proxy selection (static list, bypass, PAC via a
; fake child), the curl proxy configuration, and the changelog source order
; (API, then the Atom feed) with deterministic transport fakes.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===========================================
; ===========================================
; ======= 1/ Fixtures =======================
; ===========================================
; ===========================================

class _CNR_Request {
	__New(Status, Body) {
		this.Status := Status
		this.ResponseText := Body
		this.AbortCount := 0
	}

	WaitForResponse(*) {
		return true
	}

	Abort() {
		this.AbortCount += 1
	}
}

_CNR_Config(Proxy := "", Bypass := "", PacUrl := "") {
	return Map("auto_detect", false, "pac_url", PacUrl, "proxy", Proxy, "bypass", Bypass)
}

_CNR_FeedFixture() {
	return FileRead(A_ScriptDir . "\..\..\_shared\tests\corpus\updater\releases_feed.atom", "UTF-8")
}

_CNR_InstallChangelog() {
	global _CLW_WindowEpoch, _CLW_RequestEpoch, _CLW_ActiveRequest, _CLW_ActiveRequestEpoch
	global _CLW_Ready, _CLW_Queue, _CLW_FeedStarter
	Previous := Map("window", _CLW_WindowEpoch, "request", _CLW_RequestEpoch,
		"active", _CLW_ActiveRequest, "active_epoch", _CLW_ActiveRequestEpoch,
		"ready", _CLW_Ready, "queue", _CLW_Queue, "starter", _CLW_FeedStarter)
	_CLW_Ready := false
	_CLW_Queue := []
	return Previous
}

_CNR_RestoreChangelog(Previous) {
	global _CLW_WindowEpoch, _CLW_RequestEpoch, _CLW_ActiveRequest, _CLW_ActiveRequestEpoch
	global _CLW_Ready, _CLW_Queue, _CLW_FeedStarter
	_CLW_WindowEpoch := Previous["window"]
	_CLW_RequestEpoch := Previous["request"]
	_CLW_ActiveRequest := Previous["active"]
	_CLW_ActiveRequestEpoch := Previous["active_epoch"]
	_CLW_Ready := Previous["ready"]
	_CLW_Queue := Previous["queue"]
	_CLW_FeedStarter := Previous["starter"]
}




; ===========================================
; ===========================================
; ======= 2/ System Proxy Selection =========
; ===========================================
; ===========================================

_CNR_ProxyListSyntax() {
	AssertEqual("http://proxy.corp:8080", SystemProxy_ParseProxyList("proxy.corp:8080", "https"),
		"a bare WinINet entry applies to every scheme as an HTTP proxy")
	AssertEqual("http://secure.corp:3128",
		SystemProxy_ParseProxyList("http=plain.corp:80;https=secure.corp:3128", "https"),
		"a per-scheme list must select the https entry for GitHub")
	AssertEqual("http://plain.corp:80",
		SystemProxy_ParseProxyList("http=plain.corp:80;https=secure.corp:3128", "http"))
	AssertEqual("socks4a://sock.corp:1080", SystemProxy_ParseProxyList("socks=sock.corp:1080", "https"),
		"a SOCKS-only configuration must still route the request")
	AssertEqual("http://proxy.corp:8080", SystemProxy_ParseProxyList("http://proxy.corp:8080/", "https"))
	AssertEqual("", SystemProxy_ParseProxyList("", "https"))
	AssertEqual("", SystemProxy_ParseProxyList("proxy.corp:notaport", "https"),
		"an entry curl cannot use must not reach its config")
}
Test("system proxy: WinINet proxy lists select the scheme's proxy", _CNR_ProxyListSyntax)

_CNR_BypassList() {
	AssertTrue(SystemProxy_IsBypassed("<local>", "intranet"), "<local> covers dot-less hosts")
	AssertFalse(SystemProxy_IsBypassed("<local>", "github.com"))
	AssertTrue(SystemProxy_IsBypassed("*.github.com;10.*", "API.GitHub.com"), "wildcards are case-insensitive")
	AssertFalse(SystemProxy_IsBypassed("*.github.com", "github.com"))
	AssertTrue(SystemProxy_IsBypassed("https://github.com", "github.com"))
	AssertFalse(SystemProxy_IsBypassed("git(hub).com", "github.com"), "regex metacharacters stay literal")
}
Test("system proxy: bypass list follows WinINet matching", _CNR_BypassList)

_CNR_StaticSelection() {
	Selection := SystemProxy_SelectStatic(_CNR_Config("proxy.corp:8080"),
		"https://api.github.com/repos/x/y/releases")
	AssertEqual("http://proxy.corp:8080", Selection["proxy"])
	AssertFalse(Selection["pac"])
	Selection := SystemProxy_SelectStatic(_CNR_Config("proxy.corp:8080", "*.github.com"),
		"https://api.github.com/")
	AssertEqual("", Selection["proxy"], "a bypassed host connects directly")
	Selection := SystemProxy_SelectStatic(_CNR_Config("", "", "http://wpad.corp/proxy.pac"),
		"https://github.com/")
	AssertTrue(Selection["pac"], "a configured PAC script governs the URL")
	AssertThrows(() => SystemProxy_SelectStatic(_CNR_Config(), "ftp://github.com/"),
		"only absolute http(s) URLs can be routed")
	AssertEqual("", SystemProxy_ForUrl("test://fixture", () => _CNR_Config("proxy.corp:8080")),
		"a non-HTTP transport URL is never proxied")
	AssertEqual("http://proxy.corp:8080",
		SystemProxy_ForUrl("https://api.github.com/", () => _CNR_Config("proxy.corp:8080")))
}
Test("system proxy: static selection honours proxy, bypass and PAC", _CNR_StaticSelection)

_CNR_PacResolution() {
	global _SYSTEM_PROXY_PAC_CACHE, _SYSTEM_PROXY_PAC_PENDING
	PreviousCache := _SYSTEM_PROXY_PAC_CACHE
	_SYSTEM_PROXY_PAC_CACHE := Map()
	Spawned := []
	Handle := { start: (*) => true, terminate: (*) => true }
	FakeSpawn(Exe, Args, OnDone) {
		Spawned.Push({ Exe: Exe, Args: Args, OnDone: OnDone })
		return Handle
	}
	Reader := () => _CNR_Config("fallback.corp:80", "", "http://wpad.corp/proxy.pac")
	Api := "https://api.github.com/repos/adrienm7/ergopti/releases?per_page=20"
	Feed := "https://github.com/adrienm7/ergopti/releases.atom"
	Results := []
	try {
		SystemProxy_ResolveAsync([Api, Feed], (R) => Results.Push(R), Reader, FakeSpawn)
		AssertEqual(1, Spawned.Length, "one child must resolve every PAC host at once")
		AssertEqual(0, Results.Length, "the caller must wait for the PAC answer")
		Script := Spawned[1].Args[Spawned[1].Args.Length]
		AssertContains(Spawned[1].Exe, "powershell.exe")
		AssertContains(Script, "GetSystemWebProxy()")
		AssertContains(Script, "'https://api.github.com/'")
		AssertContains(Script, "'https://github.com/'")
		AssertFalse(InStr(Script, '"') > 0, "the script must not need argument quoting")

		Spawned[1].OnDone.Call(0, "http://pac.corp:3128/`r`nhttps://github.com/`r`n", "")
		AssertEqual(1, Results.Length)
		AssertEqual("http://pac.corp:3128", Results[1][Api], "a PAC proxy answer must be used")
		AssertEqual("", Results[1][Feed], "a PAC DIRECT answer must connect directly")
		Spawned[1].OnDone.Call(0, "http://late.corp:1/`nhttp://late.corp:1/`n", "")
		AssertEqual(1, Results.Length, "a late completion must not call back twice")

		SystemProxy_ResolveAsync([Api], (R) => Results.Push(R), Reader, FakeSpawn)
		AssertEqual(1, Spawned.Length, "a resolved host is served from the session cache")
		AssertEqual("http://pac.corp:3128", Results[2][Api])
		AssertEqual("http://pac.corp:3128", SystemProxy_ForUrl(Api, Reader, FakeSpawn))
	} finally {
		_SYSTEM_PROXY_PAC_CACHE := PreviousCache
		_SYSTEM_PROXY_PAC_PENDING := 0
	}
}
Test("system proxy: a PAC script is resolved once in a bounded child", _CNR_PacResolution)

_CNR_PacFailureKeepsStaticProxy() {
	global _SYSTEM_PROXY_PAC_CACHE, _SYSTEM_PROXY_PAC_PENDING
	PreviousCache := _SYSTEM_PROXY_PAC_CACHE
	_SYSTEM_PROXY_PAC_CACHE := Map()
	Spawned := []
	Terminated := []
	Handle := { start: (*) => true, terminate: (*) => Terminated.Push(1) }
	FakeSpawn(Exe, Args, OnDone) {
		Spawned.Push(OnDone)
		return Handle
	}
	Reader := () => _CNR_Config("fallback.corp:80", "", "http://wpad.corp/proxy.pac")
	Url := "https://github.com/adrienm7/ergopti/releases.atom"
	Results := []
	try {
		SystemProxy_ResolveAsync([Url], (R) => Results.Push(R), Reader, FakeSpawn)
		Spawned[1].Call(1, "", "execution of scripts is disabled")
		AssertEqual("http://fallback.corp:80", Results[1][Url],
			"a failed PAC run must keep the static setting, not guess")
		AssertFalse(_SYSTEM_PROXY_PAC_CACHE.Has("github.com"), "a failure must not be cached")

		SystemProxy_ResolveAsync([Url], (R) => Results.Push(R), Reader, FakeSpawn)
		AssertEqual(2, Spawned.Length, "the next request retries the PAC script")
		_SystemProxy_PacDeadline(_SYSTEM_PROXY_PAC_PENDING)
		AssertEqual(1, Terminated.Length, "the deadline must terminate the hung child")
		AssertEqual(2, Results.Length, "the deadline must release the waiter")
		AssertEqual("http://fallback.corp:80", Results[2][Url])
		Spawned[2].Call(0, "http://late.corp:1/", "")
		AssertEqual(2, Results.Length, "a child finishing after its deadline is ignored")
	} finally {
		_SYSTEM_PROXY_PAC_CACHE := PreviousCache
		_SYSTEM_PROXY_PAC_PENDING := 0
	}
}
Test("system proxy: PAC failure and timeout keep the static proxy", _CNR_PacFailureKeepsStaticProxy)

_CNR_NoPacAnswersSynchronously() {
	Results := []
	Url := "https://api.github.com/"
	SystemProxy_ResolveAsync([Url], (R) => Results.Push(R),
		() => _CNR_Config("proxy.corp:8080"), (*) => Assert(false, "no child without PAC"))
	AssertEqual(1, Results.Length)
	AssertEqual("http://proxy.corp:8080", Results[1][Url])
	Results := []
	SystemProxy_ResolveAsync([Url], (R) => Results.Push(R),
		() => Map("auto_detect", true, "pac_url", "", "proxy", "", "bypass", ""),
		(*) => Assert(false, "automatic detection alone must not spawn a child"))
	AssertEqual("", Results[1][Url], "automatic detection alone connects directly")
}
Test("system proxy: static settings answer without a child", _CNR_NoPacAnswersSynchronously)





; ===========================================
; ===========================================
; ======= 3/ Curl Proxy Configuration =======
; ===========================================
; ===========================================

_CNR_CurlConfig(Proxy) {
	Captured := Map("config", "")
	Capture(Request) {
		Captured["config"] := FileRead(Request.ConfigPath, "UTF-8")
		Request.Abort()
	}
	Req := CurlAsyncRequest(Map("before_launch", Capture,
		"spawn", (*) => Assert(false, "the captured request must not launch")))
	try {
		Req.Open("GET", "https://github.com/adrienm7/ergopti/releases.atom", true)
		if (Proxy != "")
			Req.SetProxy(Proxy)
		Req.Send()
	} finally {
		Req.Abort()
	}
	return Captured["config"]
}

_CNR_CurlUsesProxyAndBestEffortRevocation() {
	Config := _CNR_CurlConfig("http://proxy.corp:8080")
	AssertContains(Config, 'proxy = "http://proxy.corp:8080"', "curl must use the selected proxy")
	AssertContains(Config, "proxy-anyauth", "proxy authentication must be negotiated")
	AssertContains(Config, 'proxy-user = ":"', "the signed-in Windows account must authenticate (SSPI)")
	AssertContains(Config, "ssl-revoke-best-effort",
		"an unreachable revocation server of an inspection CA must not fail TLS")
	Direct := _CNR_CurlConfig("")
	AssertFalse(InStr(Direct, "proxy =") > 0, "a direct request must not name a proxy")
	AssertContains(Direct, "ssl-revoke-best-effort")
	Req := CurlAsyncRequest()
	AssertThrows(() => Req.SetProxy("javascript:alert(1)"), "a non-proxy URL must be refused")
	AssertThrows(() => Req.SetProxy("http://proxy corp:80"), "whitespace must be refused")
	AssertThrows(() => Req.SetProxy(0), "a non-string proxy must be refused")
}
Test("HTTP transport: curl routes through the Windows proxy with SSPI auth",
	_CNR_CurlUsesProxyAndBestEffortRevocation)

_CNR_UpdaterChecksUseProxy() {
	for Name in ["_Updater_PrepareLatestAsyncTransport", "_Updater_PrepareReleasesListAsyncTransport"] {
		Body := _DriverFuncBody(Name)
		AssertContains(Body, 'SystemProxy_ForUrl(Record["url"])', Name . " must select the Windows proxy")
		Assert(InStr(Body, "Req.SetProxy(Proxy)") > InStr(Body, "SystemProxy_ForUrl("),
			Name . " must apply the selected proxy to its curl request")
	}
}
Test("updater: background release checks honour the Windows proxy", _CNR_UpdaterChecksUseProxy)




; ===========================================
; ===========================================
; ======= 4/ Changelog Source Order =========
; ===========================================
; ===========================================

_CNR_ClassifySources() {
	AssertEqual("", _CLW_ClassifySource("api", 200, '[{"tag_name":"v1"}]'))
	AssertEqual("", _CLW_ClassifySource("api", 200, Chr(0xFEFF) . "[]`n"))
	AssertEqual("HTTP 200 without a JSON release array",
		_CLW_ClassifySource("api", 200, "<html>Blocked by corporate policy</html>"))
	AssertEqual("HTTP 200 without a JSON release array", _CLW_ClassifySource("api", 200, "1);alert(1);("))
	AssertEqual("HTTP 403", _CLW_ClassifySource("api", 403, ""))
	AssertEqual("no HTTP response (network, proxy or timeout)", _CLW_ClassifySource("api", 0, ""))
	AssertEqual("", _CLW_ClassifySource("feed", 200, _CNR_FeedFixture()))
	AssertEqual("HTTP 200 without an Atom feed", _CLW_ClassifySource("feed", 200, "<html></html>"))
}
Test("changelog: responses are classified before reaching the page", _CNR_ClassifySources)

_CNR_SourceUrlsExpandSharedTemplates() {
	AssertEqual("https://api.github.com/repos/adrienm7/ergopti/releases?per_page=20", _CLW_SourceUrl("api"))
	AssertEqual("https://github.com/adrienm7/ergopti/releases.atom", _CLW_SourceUrl("feed"))
}
Test("changelog: source URLs come from the shared templates", _CNR_SourceUrlsExpandSharedTemplates)

_CNR_BlockedApiFallsBackToFeed() {
	global _CLW_Queue, _CLW_FeedStarter
	Previous := _CNR_InstallChangelog()
	Started := []
	_CLW_FeedStarter := (Feed) => Started.Push(Feed)
	try {
		_CLW_BeginWindowSession()
		Context := _CLW_BeginFetchRequest("dev")
		Api := _CNR_Request(200, "<html>Access denied by proxy</html>")
		AssertTrue(_CLW_RegisterActiveRequest(Context, Api))
		_CLW_PollFetch(Api, Context, 0)
		AssertEqual(0, _CLW_Queue.Length, "a proxy block page must never reach the page as data")
		AssertEqual(1, Started.Length, "the blocked API must start the Atom feed")
		Feed := Started[1]
		AssertEqual("feed", Feed.Stage)
		AssertEqual(Context.RequestEpoch, Feed.RequestEpoch, "the feed keeps the load's epoch")
		AssertEqual("dev", Feed.Channel)
		AssertEqual("HTTP 200 without a JSON release array", Feed.ApiFailure)

		FeedReq := _CNR_Request(200, _CNR_FeedFixture())
		AssertTrue(_CLW_RegisterActiveRequest(Feed, FeedReq))
		_CLW_PollFetch(FeedReq, Feed, 0)
		AssertEqual(1, _CLW_Queue.Length, "the feed result must be published once")
		Js := _CLW_Queue[1].Js
		AssertEqual('injectReleasesFeed("', SubStr(Js, 1, 20),
			"the feed must reach the page reader as a JS string literal")
		AssertContains(Js, "releases/tag/v0.0.0-dev.130")
		AssertEqual(',"dev")', SubStr(Js, -7), "the channel must travel with the feed")
	} finally {
		_CNR_RestoreChangelog(Previous)
	}
}
Test("changelog: a blocked API falls back to the Atom feed", _CNR_BlockedApiFallsBackToFeed)

_CNR_ExhaustedSourcesReportRateLimit() {
	global _CLW_Queue, _CLW_FeedStarter
	Previous := _CNR_InstallChangelog()
	Started := []
	_CLW_FeedStarter := (Feed) => Started.Push(Feed)
	try {
		_CLW_BeginWindowSession()
		Context := _CLW_BeginFetchRequest("main")
		Api := _CNR_Request(403, "")
		_CLW_RegisterActiveRequest(Context, Api)
		_CLW_PollFetch(Api, Context, 0)
		AssertEqual(403, Started[1].ApiStatus, "the API status must travel with the fallback")
		FeedReq := _CNR_Request(0, "")
		_CLW_RegisterActiveRequest(Started[1], FeedReq)
		_CLW_PollFetch(FeedReq, Started[1], 0)
		AssertEqual(1, _CLW_Queue.Length, "an exhausted load must end in exactly one error")
		AssertContains(_CLW_Queue[1].Js, "injectError(")
		AssertContains(_CLW_Queue[1].Js, SubStr(JsonStringLiteral(t("changelog_window.error_rate_limited")), 2, 20),
			"a throttled API must be reported as a rate limit")
	} finally {
		_CNR_RestoreChangelog(Previous)
	}
}
Test("changelog: exhausted sources end in a translated error", _CNR_ExhaustedSourcesReportRateLimit)

_CNR_ApiSuccessIsParsedNotEvaluated() {
	global _CLW_Queue, _CLW_FeedStarter
	Previous := _CNR_InstallChangelog()
	Started := []
	_CLW_FeedStarter := (Feed) => Started.Push(Feed)
	try {
		_CLW_BeginWindowSession()
		Context := _CLW_BeginFetchRequest("main")
		Api := _CNR_Request(200, '[{"tag_name":"v2.4.0","body":"x\u2028\"),alert(1)//"}]')
		_CLW_RegisterActiveRequest(Context, Api)
		_CLW_PollFetch(Api, Context, 0)
		AssertEqual(0, Started.Length, "a usable API answer must not touch the feed")
		AssertEqual(1, _CLW_Queue.Length)
		AssertEqual('injectReleasesJson("', SubStr(_CLW_Queue[1].Js, 1, 20),
			"the API body must reach the page as a string for JSON.parse")
	} finally {
		_CNR_RestoreChangelog(Previous)
	}
}
Test("changelog: API bodies are parsed by the page, never evaluated", _CNR_ApiSuccessIsParsedNotEvaluated)

_CNR_SupersededFeedCannotPublish() {
	global _CLW_Queue, _CLW_FeedStarter
	Previous := _CNR_InstallChangelog()
	Started := []
	_CLW_FeedStarter := (Feed) => Started.Push(Feed)
	try {
		_CLW_BeginWindowSession()
		Old := _CLW_BeginFetchRequest("dev")
		OldApi := _CNR_Request(500, "")
		_CLW_RegisterActiveRequest(Old, OldApi)
		_CLW_PollFetch(OldApi, Old, 0)
		_CLW_BeginFetchRequest("main")
		FeedReq := _CNR_Request(200, _CNR_FeedFixture())
		_CLW_PollFetch(FeedReq, Started[1], 0)
		AssertEqual(0, _CLW_Queue.Length, "a superseded channel's feed must not repaint the page")
	} finally {
		_CNR_RestoreChangelog(Previous)
	}
}
Test("changelog: a superseded feed answer cannot publish", _CNR_SupersededFeedCannotPublish)

_CNR_FetchResolvesProxyBeforeCurl() {
	Body := _DriverFuncBody("_CLW_DoFetch")
	ResolvePos := InStr(Body, "SystemProxy_ResolveAsync(")
	CurlPos := InStr(Body, "CurlAsyncRequest()")
	Assert(ResolvePos > 0 && CurlPos > ResolvePos,
		"the changelog must resolve the Windows proxy before building its curl request")
	AssertContains(Body, "Req.SetProxy(Proxy)")
	AssertContains(Body, "CHANGELOG_SOURCE_TIMEOUT_MS", "each source must carry the shared budget")
}
Test("changelog: every source request is bounded and proxied", _CNR_FetchResolvesProxyBeforeCurl)
