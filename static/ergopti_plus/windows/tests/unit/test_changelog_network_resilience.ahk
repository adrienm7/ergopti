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
	global _SYSTEM_PROXY_PAC_CACHE, _SYSTEM_PROXY_PAC_PENDING, _SYSTEM_PROXY_PAC_CONFIG
	PreviousCache := _SYSTEM_PROXY_PAC_CACHE
	PreviousConfig := _SYSTEM_PROXY_PAC_CONFIG
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
		Input := FileRead(_SYSTEM_PROXY_PAC_PENDING.Capture["TmpFile"], "UTF-8")
		AssertContains(Input, Api . "`n", "the exact path and query must reach PAC")
		AssertContains(Input, Feed . "`n")
		AssertFalse(InStr(Script, Api) > 0, "a destination must not enter process argv")
		AssertFalse(InStr(Script, Feed) > 0, "a destination must not enter process argv")
		AssertFalse(InStr(Script, '"') > 0, "the script must not need argument quoting")

		Spawned[1].OnDone.Call(0, "http://pac.corp:3128/`r`nDIRECT`r`n", "")
		AssertEqual(1, Results.Length)
		AssertEqual("http://pac.corp:3128", Results[1][Api], "a PAC proxy answer must be used")
		AssertEqual("", Results[1][Feed], "a PAC DIRECT answer must connect directly")
		Spawned[1].OnDone.Call(0, "http://late.corp:1/`nhttp://late.corp:1/`n", "")
		AssertEqual(1, Results.Length, "a late completion must not call back twice")

		SystemProxy_ResolveAsync([Api], (R) => Results.Push(R), Reader, FakeSpawn)
		AssertEqual(1, Spawned.Length, "the exact resolved destination is served from the session cache")
		AssertEqual("http://pac.corp:3128", Results[2][Api])
		AssertEqual("http://pac.corp:3128", SystemProxy_ForUrl(Api, Reader, FakeSpawn))
	} finally {
		_SYSTEM_PROXY_PAC_CACHE := PreviousCache
		_SYSTEM_PROXY_PAC_CONFIG := PreviousConfig
		_SYSTEM_PROXY_PAC_PENDING := 0
	}
}
Test("system proxy: a PAC script is resolved once in a bounded child", _CNR_PacResolution)

_CNR_PacFailureKeepsStaticProxy() {
	global _SYSTEM_PROXY_PAC_CACHE, _SYSTEM_PROXY_PAC_PENDING, _SYSTEM_PROXY_PAC_CONFIG
	PreviousCache := _SYSTEM_PROXY_PAC_CACHE
	PreviousConfig := _SYSTEM_PROXY_PAC_CONFIG
	_SYSTEM_PROXY_PAC_CACHE := Map()
	Spawned := []
	Terminated := []
	Terminate(*) {
		Terminated.Push(1)
		return true
	}
	Handle := { start: (*) => true, terminate: Terminate }
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
		AssertFalse(_SYSTEM_PROXY_PAC_CACHE.Has(Url), "a failure must not be cached")

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
		_SYSTEM_PROXY_PAC_CONFIG := PreviousConfig
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


_CNR_PacKeepsExactDestinationsAndQueuesNewUrls() {
	global _SYSTEM_PROXY_PAC_CACHE, _SYSTEM_PROXY_PAC_PENDING, _SYSTEM_PROXY_PAC_CONFIG
	PreviousCache := _SYSTEM_PROXY_PAC_CACHE
	PreviousConfig := _SYSTEM_PROXY_PAC_CONFIG
	PreviousPending := _SYSTEM_PROXY_PAC_PENDING
	_SYSTEM_PROXY_PAC_CACHE := Map()
	_SYSTEM_PROXY_PAC_PENDING := 0
	Spawned := []
	FakeSpawn(Exe, Args, OnDone) {
		Spawned.Push(Map("args", Args, "done", OnDone,
			"input", _SYSTEM_PROXY_PAC_PENDING.Capture["TmpFile"]))
		return { start: (*) => true, terminate: (*) => true }
	}
	First := "http://proxy-fixture.invalid:8081/one?key=private-test-secret"
	Second := "https://proxy-fixture.invalid:8443/two?key=other-test-secret"
	Reader := () => _CNR_Config("", "", "http://wpad.corp/proxy.pac")
	Results := []
	try {
		SystemProxy_ResolveAsync([First], (R) => Results.Push(R), Reader, FakeSpawn)
		AssertEqual(First . "`n", FileRead(Spawned[1]["input"], "UTF-8"),
			"PAC must receive the original scheme, port, path and query")
		for Arg in Spawned[1]["args"] {
			AssertFalse(InStr(Arg, "private-test-secret") > 0, "a key must stay outside argv")
			AssertFalse(InStr(Arg, First) > 0, "a URL must stay outside argv")
		}
		SystemProxy_ResolveAsync([Second], (R) => Results.Push(R), Reader, FakeSpawn)
		AssertEqual(1, Spawned.Length, "PAC child launches must be serialized")
		AssertEqual(0, Results.Length, "neither request may publish an unresolved answer")
		Spawned[1]["done"].Call(0, "http://first-relay.corp:80", "")
		AssertEqual(1, Results.Length, "the second URL must wait for its own answer")
		AssertEqual(2, Spawned.Length, "a queued unseen URL must get another resolution")
		AssertEqual(Second . "`n", FileRead(Spawned[2]["input"], "UTF-8"))
		AssertFalse(FileExist(Spawned[1]["input"]), "completed input must be removed")
		Spawned[2]["done"].Call(0, "DIRECT", "")
		AssertEqual(2, Results.Length)
		AssertEqual("http://first-relay.corp:80", Results[1][First])
		AssertEqual("", Results[2][Second], "DIRECT must not reuse another path's relay")
		AssertEqual(2, _SYSTEM_PROXY_PAC_CACHE.Count, "exact destinations require separate cache keys")
		AssertFalse(FileExist(Spawned[2]["input"]), "key-bearing input must be removed")
	} finally {
		if IsObject(_SYSTEM_PROXY_PAC_PENDING)
			_SystemProxy_FinishPac(_SYSTEM_PROXY_PAC_PENDING, -1, "", "fixture cleanup")
		_SYSTEM_PROXY_PAC_CACHE := PreviousCache
		_SYSTEM_PROXY_PAC_CONFIG := PreviousConfig
		_SYSTEM_PROXY_PAC_PENDING := PreviousPending
	}
}
Test("system proxy: exact PAC URLs stay private and new destinations queue", _CNR_PacKeepsExactDestinationsAndQueuesNewUrls)

_CNR_PacRejectsPartialAnswers() {
	global _SYSTEM_PROXY_PAC_CACHE, _SYSTEM_PROXY_PAC_PENDING, _SYSTEM_PROXY_PAC_CONFIG
	PreviousCache := _SYSTEM_PROXY_PAC_CACHE
	PreviousConfig := _SYSTEM_PROXY_PAC_CONFIG
	PreviousPending := _SYSTEM_PROXY_PAC_PENDING
	_SYSTEM_PROXY_PAC_CACHE := Map()
	_SYSTEM_PROXY_PAC_PENDING := 0
	Results := []
	Done := []
	Spawn(Exe, Args, OnDone) {
		Done.Push(OnDone)
		return { start: (*) => true, terminate: (*) => true }
	}
	First := "https://one.invalid/one"
	Second := "https://two.invalid/two"
	try {
		SystemProxy_ResolveAsync([First, Second], (R) => Results.Push(R),
			() => _CNR_Config("fallback.corp:80", "", "http://wpad.corp/proxy.pac"), Spawn)
		Done[1].Call(0, "http://valid.corp:80`nnot-a-valid-answer", "")
		AssertEqual(0, _SYSTEM_PROXY_PAC_CACHE.Count, "one malformed answer must reject the whole receipt")
		AssertEqual("http://fallback.corp:80", Results[1][First])
		AssertEqual("http://fallback.corp:80", Results[1][Second])
	} finally {
		_SYSTEM_PROXY_PAC_CACHE := PreviousCache
		_SYSTEM_PROXY_PAC_CONFIG := PreviousConfig
		_SYSTEM_PROXY_PAC_PENDING := PreviousPending
	}
}
Test("system proxy: malformed PAC receipt cannot publish partial cache", _CNR_PacRejectsPartialAnswers)

_CNR_EnvironmentRelay(SelectedName, Name) {
	return StrLower(Name) == StrLower(SelectedName) ? "http://selected.corp:80" : ""
}

_CNR_CurlAdmissionKeepsEnvironmentAndLoopback() {
	for RelayName in ["HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY"] {
		Results := []
		Url := RelayName == "HTTP_PROXY" ? "http://remote.invalid/api" : "https://remote.invalid/api"
		SystemProxy_ResolveCurlAsync(Url, (R) => Results.Push(R),
			(*) => Assert(false, "explicit environment relay must avoid GUI discovery"), 0,
			_CNR_EnvironmentRelay.Bind(RelayName))
		AssertEqual(1, Results.Length)
		AssertTrue(Results[1]["inherit"], "curl must preserve explicit environment precedence")
	}
	Results := []
	SystemProxy_ResolveCurlAsync("https://remote.invalid/api", (R) => Results.Push(R),
		() => _CNR_Config("gui.invalid:3128"), 0, _CNR_EnvironmentRelay.Bind("HTTP_PROXY"))
	AssertFalse(Results[1]["inherit"], "HTTP-only environment cannot suppress HTTPS GUI settings")
	AssertEqual("http://gui.invalid:3128", Results[1]["proxy"])
	for Url in ["http://localhost:11434/api/tags", "http://127.0.0.1:11434/api/tags",
			"http://[::1]:11434/api/tags"] {
		Results := []
		SystemProxy_ResolveCurlAsync(Url, (R) => Results.Push(R),
			(*) => Assert(false, "loopback must not query GUI settings"), 0,
			(*) => "http://relay.corp:80")
		AssertFalse(Results[1]["inherit"], "loopback must override a relay environment")
		AssertEqual("", Results[1]["proxy"], "local inference must connect directly")
	}
	Req := CurlAsyncRequest()
	Req.SetProxy("")
	AssertTrue(Req.ProxySelected, "DIRECT must be distinguishable from unset selection")
}
Test("system proxy: explicit relay wins and loopback stays direct", _CNR_CurlAdmissionKeepsEnvironmentAndLoopback)


_CNR_StrictAdmissionResolvesWpadAndRefusesFailure() {
	global _SYSTEM_PROXY_PAC_CACHE, _SYSTEM_PROXY_PAC_PENDING, _SYSTEM_PROXY_PAC_CONFIG
	PreviousCache := _SYSTEM_PROXY_PAC_CACHE
	PreviousConfig := _SYSTEM_PROXY_PAC_CONFIG
	PreviousPending := _SYSTEM_PROXY_PAC_PENDING
	_SYSTEM_PROXY_PAC_CACHE := Map()
	_SYSTEM_PROXY_PAC_PENDING := 0
	Done := []
	Inputs := []
	Spawn(Exe, Args, OnDone) {
		Done.Push(OnDone)
		Inputs.Push(_SYSTEM_PROXY_PAC_PENDING.Capture["TmpFile"])
		return { start: (*) => true, terminate: (*) => true }
	}
	Results := []
	Reader := () => Map("auto_detect", true, "pac_url", "", "proxy", "", "bypass", "")
	try {
		SystemProxy_ResolveCurlAsync("https://wpad-fixture.invalid/one", (R) => Results.Push(R), Reader, Spawn, (*) => "")
		AssertEqual(1, Done.Length, "remote admission must resolve WPAD-only system settings")
		AssertEqual(0, Results.Length, "WPAD cannot use the generic client's direct shortcut")
		Done[1].Call(0, _CNR_NativeReceipt("no_proxy", "", 0), "")
		AssertTrue(Results[1]["ok"], "native DIRECT is an acknowledged result")
		AssertEqual("", Results[1]["proxy"])
		SystemProxy_ResolveCurlAsync("https://wpad-fixture.invalid/two", (R) => Results.Push(R), Reader, Spawn, (*) => "")
		Done[2].Call(1, "", "private-api-key in a native error")
		AssertFalse(Results[2]["ok"], "resolver failure must remain unavailable, not successful DIRECT")
		AssertFalse(FileExist(Inputs[2]), "failed resolver must retire private destination input")
	} finally {
		_SYSTEM_PROXY_PAC_CACHE := PreviousCache
		_SYSTEM_PROXY_PAC_CONFIG := PreviousConfig
		_SYSTEM_PROXY_PAC_PENDING := PreviousPending
	}
}
Test("system proxy: remote admission resolves WPAD and refuses unresolved receipt", _CNR_StrictAdmissionResolvesWpadAndRefusesFailure)

_CNR_PacDeadlineRequiresExactRetirement() {
	global _SYSTEM_PROXY_PAC_CACHE, _SYSTEM_PROXY_PAC_PENDING, _SYSTEM_PROXY_PAC_CONFIG
	PreviousCache := _SYSTEM_PROXY_PAC_CACHE
	PreviousConfig := _SYSTEM_PROXY_PAC_CONFIG
	PreviousPending := _SYSTEM_PROXY_PAC_PENDING
	_SYSTEM_PROXY_PAC_CACHE := Map()
	_SYSTEM_PROXY_PAC_PENDING := 0
	Results := []
	State := Map("terminated", false)
	Spawn(Exe, Args, OnDone) {
		return { start: (*) => true, terminate: (*) => State["terminated"] }
	}
	try {
		SystemProxy_ResolveAsync(["https://retirement.invalid/"], (R) => Results.Push(R),
			() => _CNR_Config("fallback.corp:80", "", "http://wpad.corp/proxy.pac"), Spawn)
		Run := _SYSTEM_PROXY_PAC_PENDING
		Input := Run.Capture["TmpFile"]
		_SystemProxy_PacDeadline(Run)
		AssertEqual(0, Results.Length, "unacknowledged termination must not release waiting children")
		AssertTrue(FileExist(Input), "the live resolver retains its exact private input owner")
		AssertEqual(Run, _SYSTEM_PROXY_PAC_PENDING, "refusal must retain the exact resolver owner")
		State["terminated"] := true
		_SystemProxy_PacDeadline(Run)
		AssertEqual(1, Results.Length, "exact retirement permits one terminal refusal")
		AssertFalse(Results[1]["_proxy_resolved"], "retirement cannot become proxy success")
		AssertFalse(FileExist(Input), "acknowledged retirement reaps the private input")
	} finally {
		if IsSet(Run)
			Run.Done := true
		_SYSTEM_PROXY_PAC_CACHE := PreviousCache
		_SYSTEM_PROXY_PAC_CONFIG := PreviousConfig
		_SYSTEM_PROXY_PAC_PENDING := PreviousPending
	}
}
Test("system proxy: PAC timeout retains ownership until exact retirement", _CNR_PacDeadlineRequiresExactRetirement)

_CNR_NativeReceipt(Kind, Proxy := "", ErrorCode := 0) {
	Access := Kind == "no_proxy" ? 1 : Kind == "named_proxy" ? 3 : 0
	return '{"version":1,"status":"completed","results":[{"ok":'
		. (ErrorCode == 0 ? "true" : "false") . ',"kind":' . JsonStringLiteral(Kind)
		. ',"access_type":' . Access . ',"proxy":' . JsonStringLiteral(Proxy)
		. ',"bypass":"","native_error":' . ErrorCode . ',"stage":"lookup"}]}'
}

_CNR_NativeFixtureReader(State) {
	return State["config"]
}

_CNR_NativeFixtureSpawn(State, Exe, Args, OnDone) {
	global _SYSTEM_PROXY_PAC_PENDING
	Input := FileRead(_SYSTEM_PROXY_PAC_PENDING.Capture["TmpFile"], "UTF-8")
	State["runs"].Push(Map("done", OnDone, "args", Args, "input", JsonParse(Input)))
	return { start: (*) => true, terminate: (*) => true }
}

_CNR_StrictNativeAdmission(ProbeCase := "fresh") {
	global _SYSTEM_PROXY_PAC_CACHE, _SYSTEM_PROXY_PAC_PENDING, _SYSTEM_PROXY_PAC_CONFIG
	PreviousCache := _SYSTEM_PROXY_PAC_CACHE
	PreviousConfig := _SYSTEM_PROXY_PAC_CONFIG
	PreviousPending := _SYSTEM_PROXY_PAC_PENDING
	Url := "https://native-fixture.invalid:8443/private?key=secret-fixture"
	Config := Map("auto_detect", false, "pac_url", "http://pac.invalid/private?key=pac-secret",
		"proxy", "fallback.corp:80", "bypass", "")
	State := Map("config", Config, "runs", [])
	_SYSTEM_PROXY_PAC_CACHE := Map(Url, "http://cached-stale.corp:80")
	_SYSTEM_PROXY_PAC_CONFIG := ""
	_SYSTEM_PROXY_PAC_PENDING := 0
	Results := []
	Reader := _CNR_NativeFixtureReader.Bind(State)
	Spawn := _CNR_NativeFixtureSpawn.Bind(State)
	try {
		SystemProxy_ResolveCurlAsync(Url, (R) => Results.Push(R), Reader, Spawn, (*) => "")
		AssertEqual(1, State["runs"].Length, "strict PAC admission must obtain a fresh native acknowledgment")
		First := State["runs"][1]
		Budget := _SYSTEM_PROXY_PAC_PENDING.Waiters[1].Budget
		AssertEqual(Url, First["input"]["urls"][1], "native lookup must receive the full destination")
		AssertEqual(Config["pac_url"], First["input"]["pac_url"], "configured PAC settings belong in private input")
		AssertEqual("-File", First["args"][6], "strict resolver must invoke the native worker owner")
		AssertContains(First["args"][7], "ergopti_system_proxy_worker.ps1")
		for Arg in First["args"] {
			AssertFalse(InStr(Arg, "secret-fixture") > 0, "destination tokens cannot enter argv")
			AssertFalse(InStr(Arg, "pac-secret") > 0, "PAC URL credentials cannot enter argv")
		}
		if ProbeCase == "changed" {
			State["config"] := Map("auto_detect", false, "pac_url", "http://pac.invalid/new.pac",
				"proxy", "", "bypass", "")
			First["done"].Call(0, _CNR_NativeReceipt("named_proxy", "old.invalid:80"), "")
			AssertEqual(0, Results.Length, "a changed system configuration fences the old receipt")
			AssertEqual(2, State["runs"].Length, "the first waiter must resolve the current settings")
			AssertEqual(Budget, _SYSTEM_PROXY_PAC_PENDING.Waiters[1].Budget, "config changes must retain the original bounded admission budget")
			AssertEqual("http://pac.invalid/new.pac", State["runs"][2]["input"]["pac_url"])
			State["runs"][2]["done"].Call(0, _CNR_NativeReceipt("no_proxy"), "")
			AssertEqual(1, Results.Length)
			AssertTrue(Results[1]["ok"])
			AssertEqual("", Results[1]["proxy"], "only the current settings may admit DIRECT")
			return
		}
		if ProbeCase == "absence_on_configured_pac"
			Receipt := _CNR_NativeReceipt("no_auto_proxy", "", 12180)
		else if ProbeCase == "malformed"
			Receipt := _CNR_NativeReceipt("named_proxy", "not a supported proxy")
		else if ProbeCase == "native_failure"
			Receipt := _CNR_NativeReceipt("refused", "", 12167)
		else if ProbeCase == "guessed_direct"
			Receipt := "DIRECT"
		else
			Receipt := _CNR_NativeReceipt("named_proxy", "fresh.invalid:3128")
		First["done"].Call(0, Receipt, "private URL in native stderr must never be logged")
		AssertEqual(1, Results.Length)
		if ProbeCase != "fresh" {
			AssertFalse(Results[1]["ok"], "unusable native receipts must remain unavailable")
			if ProbeCase == "native_failure"
				AssertEqual(12167, Results[1]["native_error"], "native download error must remain a closed diagnosis")
			return
		}
		AssertTrue(Results[1]["ok"])
		AssertEqual("http://fresh.invalid:3128", Results[1]["proxy"])
		AssertEqual("native_proxy", Results[1]["source"])
		_SYSTEM_PROXY_PAC_CACHE[Url] := "http://cached-stale.corp:80"
		SystemProxy_ResolveCurlAsync(Url, (R) => Results.Push(R), Reader, Spawn, (*) => "")
		AssertEqual(2, State["runs"].Length, "same URL/settings must not lifetime-cache dynamic PAC answers")
		State["runs"][2]["done"].Call(0, _CNR_NativeReceipt("no_proxy"), "")
		AssertEqual("", Results[2]["proxy"], "changed PAC bytes may change the same URL's answer")
		AssertEqual("native_direct", Results[2]["source"], "PAC DIRECT remains distinct from absent WPAD")
	} finally {
		if IsObject(_SYSTEM_PROXY_PAC_PENDING)
			_SystemProxy_FinishPac(_SYSTEM_PROXY_PAC_PENDING, -1, "", "fixture retirement")
		_SYSTEM_PROXY_PAC_CACHE := PreviousCache
		_SYSTEM_PROXY_PAC_CONFIG := PreviousConfig
		_SYSTEM_PROXY_PAC_PENDING := PreviousPending
	}
}
Test("system proxy native: fresh acknowledgments keep exact destination and PAC URLs private", _CNR_StrictNativeAdmission)
Test("system proxy native: changed Windows settings fence and redo the first waiter", _CNR_StrictNativeAdmission.Bind("changed"))
Test("system proxy native: configured PAC cannot claim WPAD absence fallback", _CNR_StrictNativeAdmission.Bind("absence_on_configured_pac"))
Test("system proxy native: malformed endpoint cannot become admission", _CNR_StrictNativeAdmission.Bind("malformed"))
Test("system proxy native: native download failure cannot become admission", _CNR_StrictNativeAdmission.Bind("native_failure"))
Test("system proxy native: guessed DIRECT is not a WinHTTP acknowledgment", _CNR_StrictNativeAdmission.Bind("guessed_direct"))

_CNR_WpadAbsenceUsesConfiguredFallback() {
	global _SYSTEM_PROXY_PAC_CACHE, _SYSTEM_PROXY_PAC_PENDING, _SYSTEM_PROXY_PAC_CONFIG
	PreviousCache := _SYSTEM_PROXY_PAC_CACHE
	PreviousConfig := _SYSTEM_PROXY_PAC_CONFIG
	PreviousPending := _SYSTEM_PROXY_PAC_PENDING
	_SYSTEM_PROXY_PAC_CACHE := Map()
	_SYSTEM_PROXY_PAC_PENDING := 0
	State := Map("config", Map("auto_detect", true, "pac_url", "", "proxy", "static.invalid:80", "bypass", ""), "runs", [])
	Results := []
	try {
		SystemProxy_ResolveCurlAsync("https://wpad-absence.invalid/", (R) => Results.Push(R),
			_CNR_NativeFixtureReader.Bind(State), _CNR_NativeFixtureSpawn.Bind(State), (*) => "")
		State["runs"][1]["done"].Call(0, _CNR_NativeReceipt("no_auto_proxy", "", 12180), "")
		AssertTrue(Results[1]["ok"], "documented WPAD absence can use a usable configured static relay")
		AssertEqual("http://static.invalid:80", Results[1]["proxy"])
		AssertEqual("wpad_absent_static", Results[1]["source"])
		AssertEqual(12180, Results[1]["native_error"])
		State["config"] := Map("auto_detect", true, "pac_url", "", "proxy", "", "bypass", "")
		SystemProxy_ResolveCurlAsync("https://home-network.invalid/", (R) => Results.Push(R),
			_CNR_NativeFixtureReader.Bind(State), _CNR_NativeFixtureSpawn.Bind(State), (*) => "")
		State["runs"][2]["done"].Call(0, _CNR_NativeReceipt("no_auto_proxy", "", 12180), "")
		AssertTrue(Results[2]["ok"], "default auto-detect without discovered PAC retains ordinary home-network access")
		AssertEqual("", Results[2]["proxy"])
		AssertEqual("wpad_absent_direct", Results[2]["source"])
		AssertEqual(12180, Results[2]["native_error"])
	} finally {
		_SYSTEM_PROXY_PAC_CACHE := PreviousCache
		_SYSTEM_PROXY_PAC_CONFIG := PreviousConfig
		_SYSTEM_PROXY_PAC_PENDING := PreviousPending
	}
}
Test("system proxy native: only actual WPAD absence admits validated static or home DIRECT fallback", _CNR_WpadAbsenceUsesConfiguredFallback)

_CNR_ControlledNativePacFixture() {
	global _VendorDir, _DriverDir
	Directory := _SR_AcquireCaptureDirectory()
	Capture := Map("TmpFile", Directory . "output.tmp", "CaptureDir", Directory)
	Observed := []
	Handle := 0
	try {
		Handle := ShellRunner_SpawnTreeOwned("powershell.exe",
			["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
				_DriverDir . "\tests\fixtures\system_proxy_native.ps1", "-WorkerPath",
				_VendorDir . "\ergopti_system_proxy_worker.ps1", "-EntryInputPath", Capture["TmpFile"]],
			(Code, Out, Err) => Observed.Push(Map("exit", Code, "stdout", Out, "stderr", Err)), , , 8192)
		AssertTrue(Handle.start(), "controlled native WinHTTP fixture must actually start")
		Started := A_TickCount
		while Observed.Length == 0 && !TickExpired64(Started, 30000) {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, Observed.Length, "owned native fixture must settle within its bounded test budget")
		AssertEqual(0, Observed[1]["exit"], "real WinHTTP PAC ABI and destination policy must agree")
		AssertEqual("", Observed[1]["stderr"], "native fixture must expose no hidden failure")
		AssertContains(Observed[1]["stdout"], "[OK] 10 controlled native WinHTTP PAC fixtures")
		AssertTrue(InStr(Observed[1]["stdout"], "native_failover=first_only") > 0
			|| InStr(Observed[1]["stdout"], "native_failover=list_two") > 0, "the actual native failover representation must be explicitly qualified")
	} finally {
		Retired := IsObject(Handle) ? Handle.terminate() : true
		AssertTrue(Retired, "the exact native fixture tree must physically settle")
		if Retired
			AssertEqual(0, _SR_CaptureRemove(Capture), "fixture private input must be removed after exact tree retirement")
	}
}
Test("system proxy native: actual WinHTTP PAC evaluates exact scheme port path query and DIRECT", _CNR_ControlledNativePacFixture)

_CNR_NativeEndpointPolicy() {
	AssertEqual("http://selected.invalid:3128", _SystemProxy_UsableNativeProxy("selected.invalid:3128", "https"))
	AssertEqual("http://secure.invalid:3128", _SystemProxy_UsableNativeProxy("http=plain.invalid:80;https=secure.invalid:3128", "https"))
	AssertThrows(() => _SystemProxy_UsableNativeProxy("first.invalid:80;second.invalid:80", "https"), "native relay failover cannot be silently truncated")
	AssertThrows(() => _SystemProxy_UsableNativeProxy("first.invalid:99999", "https"), "out-of-range ports must be refused")
	AssertThrows(() => _SystemProxy_UsableNativeProxy("first.invalid:0", "https"), "zero ports must be refused")
	AssertThrows(() => _SystemProxy_UsableNativeProxy("ftp://first.invalid:80", "https"), "unsupported native proxy schemes must be refused")
	AssertTrue(_SystemProxy_NativeBypassIsUsable("<local>;*.internal.invalid"))
	AssertFalse(_SystemProxy_NativeBypassIsUsable("internal.invalid:8443"), "unsupported bypass ports must be refused")
}
Test("system proxy native: one usable relay or supported scheme map is selected without truncating failover", _CNR_NativeEndpointPolicy)
