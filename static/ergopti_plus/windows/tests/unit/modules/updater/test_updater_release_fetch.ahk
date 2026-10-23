; tests/unit/modules/updater/test_updater_release_fetch.ahk

; ==============================================================================
; MODULE: Updater Release Fetch Tests
; DESCRIPTION:
; Version comparison and parsing, release asset resolution, the changelog
; bridge provenance, and the bounded synchronous and asynchronous release
; fetches of modules/updater.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0





_UpdaterTest_CompareVersions() {
	; Exact match
	AssertEqual(0, _Updater_CompareVersions("2.5.0", "2.5.0"))
	AssertEqual(0, _Updater_CompareVersions("v2.5.0", "2.5.0"))

	; Major/Minor/Patch ordering
	AssertEqual(1, _Updater_CompareVersions("3.0.0", "2.5.0"))
	AssertEqual(-1, _Updater_CompareVersions("2.4.9", "2.5.0"))
	AssertEqual(1, _Updater_CompareVersions("2.5.1", "2.5.0"))

	; Prerelease ordering
	AssertEqual(1, _Updater_CompareVersions("2.5.0-dev.4", "2.5.0-dev.3"))
	AssertEqual(-1, _Updater_CompareVersions("2.5.0-dev.3", "2.5.0-dev.4"))
	AssertEqual(1, _Updater_CompareVersions("2.5.0", "2.5.0-dev.4"))

	; Prerelease lengths
	AssertEqual(-1, _Updater_CompareVersions("2.5.0-dev", "2.5.0-dev.4"))
	AssertEqual(1, _Updater_CompareVersions("2.5.0-dev.4.1", "2.5.0-dev.4"))
}
Test("Updater: semver comparisons", _UpdaterTest_CompareVersions)


_UpdaterTest_VersionVectorParity() {
	; D-1 parity gate: _Updater_CompareVersions MUST agree with the shared
	; cross-driver vector table (also driven by the JS and macOS suites) so the
	; three hand-ported semver impls cannot drift. The fail-closed non-semver
	; fallback (expect 0) is the case that had drifted before D-1.
	VectorsPath := A_ScriptDir . "\..\..\_shared\modules\updater\version_vectors.json"
	AssertTrue(FileExist(VectorsPath) != "", "version vectors must exist at: " . VectorsPath)
	Data := JsonParse(FileRead(VectorsPath, "UTF-8"))
	Vectors := Data["vectors"]
	AssertTrue(Vectors.Length >= 10, "version vectors: >=10 expected, got " . Vectors.Length)
	for _, V in Vectors
		AssertEqual(V["expect"], _Updater_CompareVersions(V["a"], V["b"]), "compare(" . V["a"] . ", " . V["b"] . ") [" . V["id"] . "]")
}
Test("Updater: cross-driver version vectors (version-compare-parity)", _UpdaterTest_VersionVectorParity)

_UpdaterTest_ParseVersion() {
	v := _Updater_ParseVersion("v2.5.0-dev.3")
	AssertEqual(2, v.Maj)
	AssertEqual(5, v.Min)
	AssertEqual(0, v.Pat)
	AssertEqual(2, v.PreParts.Length)
	AssertEqual("dev", v.PreParts[1])
	AssertEqual("3", v.PreParts[2])

	v2 := _Updater_ParseVersion("3.1.4")
	AssertEqual(3, v2.Maj)
	AssertEqual(1, v2.Min)
	AssertEqual(4, v2.Pat)
	AssertEqual(0, v2.PreParts)
}
Test("Updater: version parsing", _UpdaterTest_ParseVersion)


_UpdaterTest_NestedAssetMetadata() {
	global UPDATER_GH_OWNER, UPDATER_GH_REPO
	Tag := "v9.9.9"
	Url := "https://github.com/" . UPDATER_GH_OWNER . "/" . UPDATER_GH_REPO
		. "/releases/download/" . Tag . "/ErgoptiPlus.exe"
	Digest := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	ReleaseJson := '{"assets":[{"id":17,"uploader":{"login":"release-bot","profile":{"label":"nested"}},"name":"ErgoptiPlus.exe","browser_download_url":"' . Url . '","size":524288,"digest":"sha256:' . Digest . '"}]}'
	Asset := _Updater_FindAsset(ReleaseJson, "ErgoptiPlus.exe", Tag)
	Assert(IsObject(Asset),
		"(ahk7-01-updater-nested-asset) an exact authenticated asset must resolve")
	AssertEqual(Url, Asset.Url,
		"(ahk7-01-updater-nested-asset) nested GitHub asset metadata must not hide the direct asset fields")
}
Test("Updater: nested GitHub asset metadata resolves the exact asset (ahk7-01-updater-nested-asset)",
	_UpdaterTest_NestedAssetMetadata)


_UpdaterTest_AssetResolutionIsStructuralAndExact() {
	global UPDATER_GH_OWNER, UPDATER_GH_REPO
	Tag := "v9.9.9"
	ExactUrl := "https://github.com/" . UPDATER_GH_OWNER . "/" . UPDATER_GH_REPO
		. "/releases/download/" . Tag . "/ErgoptiPlus.exe"
	ReleaseJson := '{"assets":['
		. '{"uploader":{"name":"ErgoptiPlus.exe","browser_download_url":"https://evil.test/nested.exe"},'
		. '"name":"ErgoptiPlus.exe.bak","browser_download_url":"https://example.test/backup.exe"},'
		. '{"name":"ErgoptiPlus.exe","browser_download_url":"' . ExactUrl . '",'
		. '"size":524288,"digest":"sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}'
		. ']}'
	Asset := _Updater_FindAsset(ReleaseJson, "ErgoptiPlus.exe", Tag)
	Assert(IsObject(Asset), "an exact authenticated asset must resolve")
	AssertEqual(ExactUrl, Asset.Url,
		"(ahk7-01-updater-nested-asset) nested names and prefix collisions must not impersonate a direct exact asset")
	Assert(!IsObject(_Updater_FindAsset(ReleaseJson, "ergoptiplus.exe", Tag)),
		"(ahk7-01-updater-nested-asset) release asset names are exact and case-sensitive")
	Assert(!IsObject(_Updater_FindAsset('{"assets":{"name":"ErgoptiPlus.exe"}}', "ErgoptiPlus.exe", Tag)),
		"(ahk7-01-updater-nested-asset) assets must be an array")
	Assert(!IsObject(_Updater_FindAsset('{"assets":[{"name":7,"browser_download_url":false}]}', "ErgoptiPlus.exe", Tag)),
		"(ahk7-01-updater-nested-asset) asset fields must be strings")
	Assert(!IsObject(_Updater_FindAsset('{"assets":[{"name":"ErgoptiPlus.exe","browser_download_url":""}]}', "ErgoptiPlus.exe", Tag)),
		"(ahk7-01-updater-nested-asset) an empty download URL is not a usable asset")
	Assert(!IsObject(_Updater_FindAsset('{"assets":[}', "ErgoptiPlus.exe", Tag)),
		"(ahk7-01-updater-nested-asset) malformed release JSON fails closed")
}
Test("Updater: asset resolution is structural and exact (ahk7-01-updater-nested-asset)",
	_UpdaterTest_AssetResolutionIsStructuralAndExact)


_UpdaterTest_AssetRequiresGitHubSha256Digest() {
	global UPDATER_GH_OWNER, UPDATER_GH_REPO
	Tag := "v9.9.9"
	Url := "https://github.com/" . UPDATER_GH_OWNER . "/" . UPDATER_GH_REPO
		. "/releases/download/" . Tag . "/ErgoptiPlus.exe"
	Digest := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	ReleaseJson := '{"assets":[{"name":"ErgoptiPlus.exe",'
		. '"browser_download_url":"' . Url . '","size":524288,"digest":"sha256:' . Digest . '"}]}'
	Asset := _Updater_FindAsset(ReleaseJson, "ErgoptiPlus.exe", Tag)
	Assert(IsObject(Asset),
		"an exact release asset with a GitHub SHA-256 digest must be accepted")
	AssertEqual(Url, Asset.Url,
		"the authenticated asset must preserve its exact download URL")
	AssertEqual(Digest, Asset.Digest,
		"the authenticated asset must expose the normalized lowercase SHA-256 digest")
	AssertEqual(524288, Asset.Size, "authenticated asset retains its independently supplied byte bound")
	for BadSize in ["0", "-1", "524288.5", "524288e0", "2147483648", '"524288"', "true", "null"]
		Assert(!IsObject(_Updater_FindAsset(StrReplace(ReleaseJson, '"size":524288', '"size":' . BadSize), "ErgoptiPlus.exe", Tag)),
			"malformed or unbounded authenticated asset sizes refuse before transport")
	Assert(!IsObject(_Updater_FindAsset(StrReplace(ReleaseJson, '"size":524288,', ""), "ErgoptiPlus.exe", Tag)),
		"missing authenticated size cannot borrow the content-length of an untrusted transfer")

	for InvalidJson in [
		'{"assets":[{"name":"ErgoptiPlus.exe","browser_download_url":"' . Url . '"}]}',
		'{"assets":[{"name":"ErgoptiPlus.exe","browser_download_url":"' . Url . '","digest":""}]}',
		'{"assets":[{"name":"ErgoptiPlus.exe","browser_download_url":"' . Url . '","digest":"md5:' . Digest . '"}]}',
		'{"assets":[{"name":"ErgoptiPlus.exe","browser_download_url":"' . Url . '","size":524288,"digest":"sha256:1234"}]}'
	] {
		Assert(!IsObject(_Updater_FindAsset(InvalidJson, "ErgoptiPlus.exe", Tag)),
			"a release asset without one exact trusted SHA-256 digest must fail closed")
	}
	EscapedInteger := StrReplace(ReleaseJson, '"size":524288', '"\u0073ize":524288')
	Assert(IsObject(_Updater_FindAsset(EscapedInteger, "ErgoptiPlus.exe", Tag)),
		"decoded asset size keys retain a genuine integer token")
	LastInteger := StrReplace(ReleaseJson, '"size":524288', '"size":true,"\u0073ize":524288')
	Assert(IsObject(_Updater_FindAsset(LastInteger, "ErgoptiPlus.exe", Tag)),
		"last decoded duplicate member wins with its genuine integer token")
	for BooleanJson in [
		StrReplace(ReleaseJson, '"size":524288', '"size":524288,"\u0073ize":true'),
		StrReplace(ReleaseJson, '"size":524288', '"\u0073ize":true'),
		StrReplace(ReleaseJson, '"size":524288', '"nested":{"size":524288},"size":true')
	]
		Assert(!IsObject(_Updater_FindAsset(BooleanJson, "ErgoptiPlus.exe", Tag)),
			"Boolean size cannot borrow integer provenance from a nested or earlier member")
	SkippedAssets := StrReplace(ReleaseJson, '{"assets":[',
		'{"assets":[true,1,null,{"name":"other.exe","size":true,"nested":{"size":524288}},')
	Assert(IsObject(_Updater_FindAsset(SkippedAssets, "ErgoptiPlus.exe", Tag)),
		"raw array span index follows the exact selected asset after every skipped element")
	ArraySource := JsonObjectMemberSpans(ReleaseJson)["assets"]["text"]
	LastAssets := '{"assets":[true],"\u0061ssets":' . ArraySource . '}'
	Assert(IsObject(_Updater_FindAsset(LastAssets, "ErgoptiPlus.exe", Tag)),
		"source lookup follows the last decoded duplicate assets member")
	IntegerOne := StrReplace(ReleaseJson, '"size":524288', '"size":1')
	Assert(IsObject(_Updater_FindAsset(IntegerOne, "ErgoptiPlus.exe", Tag)),
		"JSON integer one is distinct from Boolean true before installation minimum validation")
	for ForeignJson in [
		StrReplace(ReleaseJson,
			"github.com/" . UPDATER_GH_OWNER . "/" . UPDATER_GH_REPO,
			"example.invalid/" . UPDATER_GH_OWNER . "/" . UPDATER_GH_REPO),
		StrReplace(ReleaseJson, "/" . Tag . "/", "/v9.9.8/")
	] {
		Assert(!IsObject(_Updater_FindAsset(ForeignJson, "ErgoptiPlus.exe", Tag)),
			"a foreign repository or tag URL must fail closed")
	}
}
Test("Updater: release asset requires GitHub SHA-256 authentication (updater-authenticated-asset-2026-08-28)",
	_UpdaterTest_AssetRequiresGitHubSha256Digest)


_UpdaterTest_ManualUrlAllowlistPrecedesRunner() {
	global UPDATER_GH_OWNER, UPDATER_GH_REPO
	RepoRoot := "https://github.com/" . UPDATER_GH_OWNER . "/" . UPDATER_GH_REPO
	for Url in [RepoRoot, RepoRoot . "/releases", RepoRoot . "/releases/tag/v9.9.9?x=1#notes"]
		AssertTrue(_Updater_IsAllowedManualUrl(Url),
			"the exact repository HTTPS surface must remain reachable")
	for Url in [
		"http://github.com/" . UPDATER_GH_OWNER . "/" . UPDATER_GH_REPO,
		"javascript:alert(1)",
		"audit-canary://noop",
		"https://example.invalid/" . UPDATER_GH_OWNER . "/" . UPDATER_GH_REPO,
		RepoRoot . ".invalid/releases",
		"https://github.com/" . UPDATER_GH_OWNER . "/other/releases"
	] {
		AssertFalse(_Updater_IsAllowedManualUrl(Url),
			"hostile schemes, hosts and repository-prefix collisions must fail closed")
	}

	Runs := []
	RunFn := (Url) => Runs.Push(Url)
	Result := _Updater_OpenManualUrl(() => "audit-canary://noop", , false, 0, RunFn)
	AssertFalse(Result,
		"a rejected bridge URL must report failure")
	AssertEqual(0, Runs.Length,
		"the native runner must remain unreachable for a rejected URL")
	Result := _Updater_OpenManualUrl(() => RepoRoot . "/releases", , false, 0, RunFn)
	AssertTrue(Result,
		"an allowlisted repository URL must still open")
	AssertEqual(1, Runs.Length,
		"the allowlisted URL must reach the injected runner exactly once")
}
Test("Updater: manual URL boundary rejects hostile schemes and hosts before Run (audit-ahk-002-url-allowlist)",
	_UpdaterTest_ManualUrlAllowlistPrecedesRunner)


class _UpdaterTest_ChangelogArgs {
	__New(Source, Message) {
		this.Source := Source
		this.Message := Message
		this.ReadCount := 0
	}

	TryGetWebMessageAsString() {
		this.ReadCount += 1
		return this.Message
	}
}

_UpdaterTest_ChangelogBridgeRequiresExactDocumentSession() {
	global _CLW_WindowEpoch, _CLW_BridgeSessionToken, _CLW_Ready
	global _CLW_BridgeRejectionReported
	SavedEpoch := _CLW_WindowEpoch
	SavedSession := _CLW_BridgeSessionToken
	SavedReady := _CLW_Ready
	SavedRejectionReported := _CLW_BridgeRejectionReported
	ExpectedSource := "https://ergopti.changelog/ui/changelog/index.html?cb=42"
	try {
		_CLW_WindowEpoch := 42
		_CLW_BridgeSessionToken := "0123456789abcdef0123456789abcdef"
		_CLW_BridgeRejectionReported := false
		_CLW_Ready := false

		Foreign := _UpdaterTest_ChangelogArgs(
			"https://example.invalid/foreign.html",
			'{"action":"ready","session":"0123456789abcdef0123456789abcdef"}')
		_CLW_OnWebMessage(42, _CLW_BridgeSessionToken, ExpectedSource, 0, Foreign)
		AssertEqual(0, Foreign.ReadCount,
			"a foreign document must be rejected before its message body is read")
		AssertFalse(_CLW_Ready,
			"a foreign ready message must not mutate the current page lifecycle")

		Stale := _UpdaterTest_ChangelogArgs(ExpectedSource,
			'{"action":"ready","session":"stale"}')
		_CLW_OnWebMessage(41, "stale", ExpectedSource, 0, Stale)
		AssertEqual(0, Stale.ReadCount,
			"a stale bound window/session must be rejected before its message body is read")

		WrongPayload := _UpdaterTest_ChangelogArgs(ExpectedSource,
			'{"action":"ready","session":"0123456789ABCDEF0123456789ABCDEF"}')
		_CLW_OnWebMessage(42, _CLW_BridgeSessionToken, ExpectedSource, 0, WrongPayload)
		AssertEqual(1, WrongPayload.ReadCount,
			"the exact document may expose its payload only after source admission")
		AssertFalse(_CLW_Ready,
			"a session mismatch inside the payload must remain inert")
	} finally {
		_CLW_WindowEpoch := SavedEpoch
		_CLW_BridgeSessionToken := SavedSession
		_CLW_BridgeRejectionReported := SavedRejectionReported
		_CLW_Ready := SavedReady
	}
}
Test("Changelog: exact source and session precede bridge dispatch (audit-ahk-002-bridge-provenance)",
	_UpdaterTest_ChangelogBridgeRequiresExactDocumentSession)


; Regression: Updater_FetchLatestJson must call SetTimeouts before Req.Send()
; so synchronous WinHttp calls cannot block the AHK main thread indefinitely.
; Without SetTimeouts the default WinHttp timeout is ~60 s per phase — long
; enough to freeze all keyboard input during a background update check on a
; slow or unresponsive network.
_UpdaterTest_SyncFetchTimeoutsPrecedeSend() {
	; The synchronous COM path has no injected factory; keep its structural
	; contract explicit rather than claiming the async double exercises it.
	for Name in ["Updater_FetchLatestJson", "Updater_FetchReleasesListJson"] {
		FnBody := _StripFullLineComments(_DriverFuncBody(Name))
		AssertTrue(FnBody != "", Name . ": the synchronous fetch body must be found")
		TimeoutPos := RegExMatch(FnBody,
			"m)^\h*Req\.SetTimeouts\(\s*UPDATER_HTTP_RESOLVE_TIMEOUT_MS\s*,\s*"
			. "UPDATER_HTTP_CONNECT_TIMEOUT_MS\s*,\s*UPDATER_HTTP_SEND_TIMEOUT_MS\s*,\s*"
			. "UPDATER_HTTP_RECEIVE_TIMEOUT_MS\s*\)")
		SendPos := RegExMatch(FnBody,
			"m)^\h*(?:Req\.Send\(\h*\)|if !Req\.Send\(\h*\) \|\| !_HTTP_ManagedWait\(Req\))\h*$")
		AssertTrue(TimeoutPos > 0, Name . ": the request must use all four canonical budgets")
		AssertTrue(SendPos > 0, Name . ": Send must not disappear from the scanned subject")
		AssertTrue(TimeoutPos < SendPos, Name . ": finite timeouts must precede Send")
	}
}
Test("Updater: both synchronous fetches bound timeouts before Send (updater-sync-timeout-order)",
	_UpdaterTest_SyncFetchTimeoutsPrecedeSend)


; Regression: the WinHttp resolve-timeout phase must be FINITE. WinHttp treats a
; 0 in any SetTimeouts slot as "infinite", so a 0 resolve timeout lets a stalled
; DNS lookup (a connecting VPN, a captive portal, a dead resolver) block the
; synchronous call -- and therefore the AHK main thread, and therefore all
; keyboard remapping -- forever. That is what froze the driver a few seconds
; after startup when the background update poller fired its first check. Guard
; every per-phase budget constant so a 0 can never silently return.
_UpdaterTest_HttpTimeoutsAreFinite() {
	global UPDATER_HTTP_RESOLVE_TIMEOUT_MS, UPDATER_HTTP_CONNECT_TIMEOUT_MS
	global UPDATER_HTTP_SEND_TIMEOUT_MS, UPDATER_HTTP_RECEIVE_TIMEOUT_MS
	AssertEqual(true, UPDATER_HTTP_RESOLVE_TIMEOUT_MS > 0,
		"resolve timeout must be > 0 -- a 0 resolve phase is infinite in WinHttp and freezes the main thread")
	AssertEqual(true, UPDATER_HTTP_CONNECT_TIMEOUT_MS > 0, "connect timeout must be finite (> 0)")
	AssertEqual(true, UPDATER_HTTP_SEND_TIMEOUT_MS > 0,    "send timeout must be finite (> 0)")
	AssertEqual(true, UPDATER_HTTP_RECEIVE_TIMEOUT_MS > 0, "receive timeout must be finite (> 0)")
}
Test("Updater: WinHttp timeouts are all finite (regression: infinite DNS resolve froze startup)", _UpdaterTest_HttpTimeoutsAreFinite)


_UpdaterTest_AsyncTransportTimeouts() {
	global UPDATER_REQUEST_ORIGIN_MANUAL
	global UPDATER_HTTP_RESOLVE_TIMEOUT_MS, UPDATER_HTTP_CONNECT_TIMEOUT_MS
	global UPDATER_HTTP_SEND_TIMEOUT_MS, UPDATER_HTTP_RECEIVE_TIMEOUT_MS
	Expected := [UPDATER_HTTP_RESOLVE_TIMEOUT_MS, UPDATER_HTTP_CONNECT_TIMEOUT_MS,
		UPDATER_HTTP_SEND_TIMEOUT_MS, UPDATER_HTTP_RECEIVE_TIMEOUT_MS]
	Saved := _UpdaterTest_SaveRequestState()
	try {
		for Prepare in [_Updater_PrepareLatestAsyncTransport,
				_Updater_PrepareReleasesListAsyncTransport] {
			_UpdaterTest_ResetRequestState()
			State := { PhaseVisits: [], Sends: 0, Aborts: 0, Polls: 0,
				Terminals: 0, Json: "not-called", CompletedRequest: 0, Terminal: 0 }
			Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, false)
			Owner := _Updater_RegisterAsyncRequestOwner(0, "main",
				_UpdaterTest_CaptureOwnedPreparationTerminal.Bind(State),
				"test://finite-transport-timeouts", Request)
			Factory := _UpdaterTest_CreatePhasePreparationHttp.Bind(State, "")
			AssertTrue(_Updater_SendOwnedAsyncRequest(Owner,
				(Id) => (State.Polls += 1, true), "test finite transport budgets",
				_UpdaterTest_PrepareLatestWithFactory.Bind(Prepare, Factory)))
			AssertEqual(1, State.Sends, "the configured transport must actually be sent")
			AssertEqual(1, State.TimeoutsAtSend, "exactly one timeout setup must precede Send")
			AssertEqual(1, State.TimeoutCalls.Length)
			Values := State.TimeoutCalls[1]
			AssertEqual(4, Values.Length, "all four transport phases must be bounded")
			for Index, Value in Values {
				AssertTrue(Value is Integer && Value > 0,
					"each actual timeout argument must be finite and positive")
				AssertEqual(Expected[Index], Value, "the transport must receive the canonical budget")
			}
			AssertEqual("send", State.PhaseVisits[-1], "timeout setup cannot follow Send")
			_Updater_CancelAsyncChecks("test cleanup")
		}
	} finally {
		_Updater_CancelAsyncChecks("test cleanup")
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater: both async transports receive finite budgets before Send (updater-transport-timeout-arguments)",
	_UpdaterTest_AsyncTransportTimeouts)


_UpdaterTest_TypedBoundarySeam(State, Mode, *) {
	State.Calls += 1
	switch Mode {
		case "false": return false
		case "string": return "0"
		case "throw": throw Error("deterministic typed-boundary failure")
		default: return true
	}
}

_UpdaterTest_ResolveFunction(Name) {
	; Dynamic variable dereference defers symbol resolution until the test runs.
	; This lets the regression test parse against the pre-fix source and report a
	; TAP failure instead of blocking the headless runner in a parser dialog.
	return %Name%
}

_UpdaterTest_EffectAcknowledgementsAreTyped() {
	ResultSucceeded := _UpdaterTest_ResolveFunction("_Updater_ResultSucceeded")
	SurfaceFailure := _UpdaterTest_ResolveFunction("_Updater_SurfaceFailure")
	SendNotice := _UpdaterTest_ResolveFunction("NotifierSend")
	AssertEqual(false, ResultSucceeded.Call(false),
		"boolean false must not acknowledge an updater effect")
	AssertEqual(false, ResultSucceeded.Call(0),
		"Integer zero must not acknowledge an updater effect")
	AssertEqual(false, ResultSucceeded.Call("0"),
		"String zero must never impersonate boolean success in AHK v2")
	AssertEqual(false, ResultSucceeded.Call({}),
		"an arbitrary object must not acknowledge an updater effect")
	AssertEqual(true, ResultSucceeded.Call(true),
		"boolean true is AHK's explicit non-zero Integer acknowledgement")
	AssertEqual(true, ResultSucceeded.Call(-1),
		"native non-zero Integer acknowledgements remain accepted")

	for Mode in ["false", "string", "throw"] {
		State := { Calls: 0 }
		Seam := _UpdaterTest_TypedBoundarySeam.Bind(State, Mode)
		AssertEqual(false, SendNotice.Call("typed notifier probe",
			Map("title", "Ergopti+", "level", "warning"), Seam),
			"notifier must reject false, String zero, and throw: " . Mode)
		AssertEqual(false, SurfaceFailure.Call("updater.install_error",
			"deterministic typed failure", Seam),
			"updater failure sink must propagate notifier refusal: " . Mode)
		AssertEqual(2, State.Calls,
			"each typed boundary must invoke its injected seam exactly once: " . Mode)
	}
	State := { Calls: 0 }
	Seam := _UpdaterTest_TypedBoundarySeam.Bind(State, "success")
	AssertEqual(true, SendNotice.Call("typed notifier probe",
		Map("title", "Ergopti+", "level", "warning"), Seam),
		"notifier must acknowledge an explicit non-zero Integer result")
	AssertEqual(true, SurfaceFailure.Call("updater.install_error",
		"deterministic typed failure", Seam),
		"updater failure sink must propagate an explicit acknowledgement")
	AssertEqual(2, State.Calls,
		"successful typed boundaries must still invoke each exact seam once")
}
Test("Updater: native and notifier acknowledgements are strictly typed (typed-updater-results)",
	_UpdaterTest_EffectAcknowledgementsAreTyped)


_UpdaterTest_JsonStringZeroHasTypedTransportSemantics() {
	global _UpdaterFetchCache
	PayloadIsFailure := _UpdaterTest_ResolveFunction(
		"_Updater_JsonPayloadIsFailure")
	PayloadIsUsable := _UpdaterTest_ResolveFunction(
		"_Updater_JsonPayloadIsUsable")
	AssertEqual(false, PayloadIsFailure.Call("0"),
		'the valid JSON String "0" must not compare equal to a false sentinel')
	AssertEqual(true, PayloadIsUsable.Call("0"),
		'the valid JSON String "0" must cross every non-empty payload gate')
	AssertEqual(true, PayloadIsFailure.Call(""),
		"the canonical empty String remains a failed payload")
	AssertEqual(true, PayloadIsFailure.Call(false),
		"a non-String false transport result must fail closed")
	AssertEqual(false, PayloadIsUsable.Call(false),
		"a non-String failure must never enter the response cache")

	SavedCache := _UpdaterFetchCache
	try {
		_UpdaterFetchCache := Map()
		AssertEqual("0", _Updater_InterpretResponse(
			200, "0", "typed-etag", "typed-zero", "test://typed-zero"),
			'the fresh JSON String "0" must survive response interpretation')
		AssertEqual("0", _UpdaterFetchCache["typed-zero"].Json,
			'the fresh JSON String "0" must remain cacheable')
		AssertEqual("0", _Updater_InterpretResponse(
			304, "", "", "typed-zero", "test://typed-zero"),
			'the cached JSON String "0" must survive a 304 response')
	} finally {
		_UpdaterFetchCache := SavedCache
	}

	for FunctionName in [
		"Updater_ParseTagName",
		"Updater_ParseBody",
		"_Updater_HandleBackgroundResult",
		"_Updater_ShowAvailableUpdateCallback",
		"_Updater_OneClickUpdateCallback",
		"_Updater_BuildChangelogGui"
	] {
		Body := _DriverFuncBody(FunctionName)
		Assert(InStr(Body, "_Updater_JsonPayloadIsFailure(Json)") > 0,
			FunctionName . " must share the typed String|failure predicate")
	}
}
Test("Updater: JSON String zero never aliases the failure sentinel (typed-updater-results)",
	_UpdaterTest_JsonStringZeroHasTypedTransportSemantics)


; Regression: the binary download path used to call Req.Send() with NO
; SetTimeouts at all -- fully unbounded, so a CDN stalling mid-transfer hung the
; main thread forever. Assert that Updater_DownloadAndInstall sets timeouts
; before it launches the isolated worker. The worker, rather than the keyboard
; thread, owns the actual HTTP timeout and binary stream.
_UpdaterTest_DownloadHasTimeout() {
	Dispatch := _DriverFuncBody("Updater_DownloadAndInstall")
	Worker := _DriverFuncBody("_Updater_StartStagingWorker")
	AssertEqual(true, InStr(Dispatch, "_Updater_StartStagingWorker(") > 0,
		"Updater_DownloadAndInstall must dispatch the binary transaction to the isolated worker")
	AssertEqual(true, InStr(Worker, "UPDATER_HTTP_DOWNLOAD_RECEIVE_TIMEOUT_MS") > 0,
		"Updater staging worker must receive the finite download timeout")
	AssertEqual(true, InStr(Worker, "ShellRunner_SpawnTreeOwned") > 0,
		"Updater staging worker must use the asynchronous tree-owned runner so pause or exit cannot orphan PowerShell")
}
Test("Updater: DownloadAndInstall has timeout guard (regression: unbounded binary download)", _UpdaterTest_DownloadHasTimeout)


; The worker is the bundled script the driver launches, read through the same
; path function, so a regression that drops its input contract or integrity
; checks fails here before PowerShell is even launched.
_UpdaterTest_StagingWorkerScriptContract() {
	Script := FileRead(_Updater_StagingWorkerPath(), "UTF-8")
	AssertEqual(true, InStr(Script, "param([string]$TransportPrefix") > 0
		&& InStr(Script, '$Url = Read-ErgoptiStagingInput "URL" $true') > 0,
		"Updater staging worker script must keep its URL input contract")
	AssertEqual(true, InStr(Script, "$Request.ReadWriteTimeout = $TimeoutMs") > 0,
		"Updater staging worker script must apply a streaming timeout")
	AssertEqual(true, InStr(Script, "$ActualSize -ne $ExpectedSize") > 0,
		"Updater staging worker script must keep the truncated-download integrity check")
	AssertEqual(true, InStr(Script, "$Hasher.ComputeHash($HashStream)") > 0
		&& InStr(Script, "$HashStream.Dispose()") > 0
		&& InStr(Script, "$Hasher.Dispose()") > 0,
		"Updater staging worker must hash the persisted executable before publishing READY")
	AssertEqual(true, InStr(Script, "$ActualDigest -cne $ExpectedSha256") > 0,
		"Updater staging worker must reject a byte-mutated executable before swap publication")
	AssertEqual(true, InStr(Script, 'Write-Output "READY"') > 0,
		"Updater staging worker script must emit the readiness token only after staging succeeds")
}
Test("Updater: staging worker runtime script retains its argv, timeout, integrity and readiness contract", _UpdaterTest_StagingWorkerScriptContract)


; Regression: the background poller MUST dispatch its GitHub query
; asynchronously. A synchronous WinHttp call on the main thread -- even with
; bounded timeouts -- freezes ALL keyboard remapping for the round-trip, and
; the background tick fires unprompted a few seconds after startup. Assert that
; Updater_BackgroundTick goes through the async dispatch and never calls the
; blocking Updater_FetchLatestJson directly.
_UpdaterTest_BackgroundTickIsAsync() {
	Source := _DriverDirConcat("modules/updater")
	FnStart := InStr(Source, "`nUpdater_BackgroundTick(")
	if (FnStart == 0) {
		AssertEqual("found", "missing", "Updater_BackgroundTick not found in updater.ahk")
		return
	}
	; Walk to the matching closing brace (same brace-counter as the sibling
	; tests). The tick body has no mixed-quote strings, so this is safe here.
	Depth := 0
	FnEnd := FnStart
	Len := StrLen(Source)
	InQuote := false
	Esc := false
	pos := FnStart
	while (pos <= Len) {
		c := SubStr(Source, pos, 1)
		if InQuote {
			if Esc {
				Esc := false
			} else if (c == "\") {
				Esc := true
			} else if (c == '"') {
				InQuote := false
			}
		} else {
			if (c == '"') {
				InQuote := true
			} else if (c == "{") {
				Depth += 1
			} else if (c == "}") {
				Depth -= 1
				if (Depth == 0) {
					FnEnd := pos
					break
				}
			}
		}
		pos += 1
	}
	FnBody := SubStr(Source, FnStart, FnEnd - FnStart + 1)

	UsesAsync := InStr(FnBody, "_Updater_FetchLatestJsonAsync(") > 0
	AssertEqual(true, UsesAsync,
		"Updater_BackgroundTick must dispatch via _Updater_FetchLatestJsonAsync (non-blocking) -- a sync fetch on the main thread freezes remapping")

	; The blocking sync fetch must not appear in the tick body. The literal "("
	; after "Json" disambiguates from the async name (...JsonAsync(...).
	HasBlockingCall := InStr(FnBody, "Updater_FetchLatestJson(") > 0
	AssertEqual(false, HasBlockingCall,
		"Updater_BackgroundTick must not call the blocking Updater_FetchLatestJson directly")
}
Test("Updater: background poller dispatches asynchronously (regression: sync fetch froze remapping)", _UpdaterTest_BackgroundTickIsAsync)

_UpdaterTest_RateLimitDetail() {
	global _UpdaterFetchCache
	AssertEqual("HTTP 403: the GitHub API rate limit is exhausted, it resets at 1970-01-02 00:00:00 UTC",
		_Updater_RateLimitDetail(403, "0", "86400"), "an exhausted limit names its UTC reset")
	AssertEqual("HTTP 429: the GitHub API rate limit is exhausted",
		_Updater_RateLimitDetail(429, "0", ""), "a missing reset still names the limit")
	AssertEqual("HTTP 403: the GitHub API rate limit is exhausted",
		_Updater_RateLimitDetail(403, "0", "soon"), "a malformed reset is not a time")
	AssertEqual("", _Updater_RateLimitDetail(403, "12", "86400"), "calls left is another refusal")
	AssertEqual("", _Updater_RateLimitDetail(403, "", ""), "no rate-limit header is another refusal")
	AssertEqual("", _Updater_RateLimitDetail(500, "0", "86400"), "only 403 and 429 are rate limits")
	SavedCache := _UpdaterFetchCache
	try {
		_UpdaterFetchCache := Map()
		AssertEqual("", _Updater_InterpretResponse(403, "{}", "", "dev", "test://limited", ,
			Map("remaining", "0", "reset", "86400")), "a rate-limited answer has no release")
		AssertFalse(_UpdaterFetchCache.Has("dev"), "a refusal never enters the response cache")
	} finally {
		_UpdaterFetchCache := SavedCache
	}
}
Test("Updater: an exhausted GitHub rate limit names its reset time (#95)", _UpdaterTest_RateLimitDetail)


; Simulates a driver restart: the in-memory cache and the load memo are fresh.
_UpdaterTest_ListCacheRestart() {
	global _UpdaterFetchCache, _UpdaterListDiskLoaded, _UpdaterListDiskEntry
	_UpdaterFetchCache := Map()
	_UpdaterListDiskLoaded := false
	_UpdaterListDiskEntry := 0
}

; Regression (#95 point 3): the list ETag lived in memory only, so the first
; request after every restart was a full one and spent GitHub's 60 anonymous
; calls an hour. The complete list and its ETag now survive on disk; a 304 after
; a restart reuses them and the file is rewritten only when the ETag changes.
_UpdaterTest_ListCacheSurvivesRestart() {
	global _UpdaterFetchCache, _UpdaterListCacheDir, _UpdaterListDiskLoaded, _UpdaterListDiskEntry
	SavedCache := _UpdaterFetchCache
	SavedDir := _UpdaterListCacheDir
	SavedLoaded := _UpdaterListDiskLoaded
	SavedEntry := _UpdaterListDiskEntry
	Dir := A_Temp . "\ergopti-list-cache-" . A_TickCount
	Url := Updater_ReleaseApiUrl()
	ListA := '[{"tag_name":"v1.2.0","prerelease":false,"body":"first"},{"tag_name":"v1.1.0","prerelease":false}]'
	ListB := '[{"tag_name":"v1.3.0","prerelease":false,"body":"second"},{"tag_name":"v1.2.0","prerelease":false}]'
	try {
		_UpdaterListCacheDir := Dir
		_UpdaterTest_ListCacheRestart()
		Path := _Updater_ListCachePath()
		_Updater_InterpretResponse(200, ListA, '"etag-a"', "main", Url)
		AssertTrue(FileExist(Path) != "", "a fresh 200 must save the list on disk")

		_UpdaterTest_ListCacheRestart()
		Entry := _Updater_FetchCacheEntry("main", Url)
		AssertTrue(IsObject(Entry), "a restart must find the stored list")
		AssertEqual('"etag-a"', Entry.Etag, "a restart must send the stored ETag")
		Selected := _Updater_InterpretResponse(304, "", "", "main", Url)
		AssertEqual("v1.2.0", Updater_ParseTagName(Selected),
			"a 304 after a restart must select the release from the stored complete list")

		; The same ETag never rewrites the file, even with a different body.
		_Updater_InterpretResponse(200, ListB, '"etag-a"', "main", Url)
		AssertTrue(InStr(FileRead(Path, "UTF-8"), '"first"') > 0,
			"an unchanged ETag must not rewrite the stored list")
		_Updater_InterpretResponse(200, ListB, '"etag-b"', "main", Url)
		AssertTrue(InStr(FileRead(Path, "UTF-8"), '"second"') > 0,
			"a changed ETag must rewrite the stored list")

		; A list URL other than the real one never reaches the disk.
		FileDelete(Path)
		_UpdaterTest_ListCacheRestart()
		_Updater_InterpretResponse(200, ListA, '"etag-c"', "main", "test://elsewhere")
		AssertFalse(FileExist(Path) != "", "a foreign URL must not be persisted")

		; A truncated or foreign copy is discarded, never trusted.
		for Corrupt in ["garbage", "ergopti-release-list-v1`n" . Url . "`n" . '"e"' . "`n" . SubStr(ListA, 1, 20),
			"ergopti-release-list-v1`ntest://other`n" . '"e"' . "`n" . ListA,
			"ergopti-release-list-v1`n" . Url . "`n`n" . ListA] {
			DirCreate(Dir)
			FileAppend(Corrupt, Path, "UTF-8-RAW")
			_UpdaterTest_ListCacheRestart()
			AssertEqual(0, _Updater_FetchCacheEntry("main", Url), "a corrupt copy must not be used")
			AssertFalse(FileExist(Path) != "", "a corrupt copy must be discarded")
		}
	} finally {
		_UpdaterFetchCache := SavedCache
		_UpdaterListCacheDir := SavedDir
		_UpdaterListDiskLoaded := SavedLoaded
		_UpdaterListDiskEntry := SavedEntry
		try DirDelete(Dir, true)
	}
}
Test("Updater: the release list and its ETag survive a restart (#95)", _UpdaterTest_ListCacheSurvivesRestart)

#Include test_updater_managed_json_utf8.ahk
#Include test_updater_latest_json_utf8.ahk
