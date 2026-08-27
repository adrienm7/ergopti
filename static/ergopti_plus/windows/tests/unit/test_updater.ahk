; static/ergopti_plus/windows/tests/unit/test_updater.ahk

; ==============================================================================
; MODULE: Updater Logic Tests
; DESCRIPTION:
; Unit-tests for the semver and JSON parsing functions in modules/updater.ahk.
; Ensures prerelease ordering, version parsing, and blocking-call hygiene work
; correctly.
; ==============================================================================

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
	ReleaseJson := '{"assets":[{"id":17,"uploader":{"login":"release-bot","profile":{"label":"nested"}},"name":"ErgoptiPlus.exe","browser_download_url":"' . Url . '","digest":"sha256:' . Digest . '"}]}'
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
		. '"digest":"sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}'
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
		. '"browser_download_url":"' . Url . '","digest":"sha256:' . Digest . '"}]}'
	Asset := _Updater_FindAsset(ReleaseJson, "ErgoptiPlus.exe", Tag)
	Assert(IsObject(Asset),
		"an exact release asset with a GitHub SHA-256 digest must be accepted")
	AssertEqual(Url, Asset.Url,
		"the authenticated asset must preserve its exact download URL")
	AssertEqual(Digest, Asset.Digest,
		"the authenticated asset must expose the normalized lowercase SHA-256 digest")

	for InvalidJson in [
		'{"assets":[{"name":"ErgoptiPlus.exe","browser_download_url":"' . Url . '"}]}',
		'{"assets":[{"name":"ErgoptiPlus.exe","browser_download_url":"' . Url . '","digest":""}]}',
		'{"assets":[{"name":"ErgoptiPlus.exe","browser_download_url":"' . Url . '","digest":"md5:' . Digest . '"}]}',
		'{"assets":[{"name":"ErgoptiPlus.exe","browser_download_url":"' . Url . '","digest":"sha256:1234"}]}'
	] {
		Assert(!IsObject(_Updater_FindAsset(InvalidJson, "ErgoptiPlus.exe", Tag)),
			"a release asset without one exact trusted SHA-256 digest must fail closed")
	}
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
_UpdaterTest_FetchLatestJsonHasTimeout() {
	; Scan the whole updater module (now split across modules/updater/*.ahk) so body
	; extraction survives the decomposition. Anchor on the column-0 definition
	; ("`n" + name) so a call site can never be mistaken for the body.
	Source := _DriverDirConcat("modules/updater")

	; Extract only the body of Updater_FetchLatestJson so we don't match
	; SetTimeouts that belong to other functions (e.g. Updater_FetchReleasesListJson).
	FnStart := InStr(Source, "`nUpdater_FetchLatestJson(")
	if (FnStart == 0) {
		AssertEqual("found", "missing", "Updater_FetchLatestJson not found in updater.ahk")
		return
	}
	; Walk forward to the matching closing brace of the function body.
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

	; SetTimeouts must appear inside this function body.
	HasTimeout := InStr(FnBody, "SetTimeouts") > 0
	AssertEqual(true, HasTimeout,
		"Updater_FetchLatestJson is missing SetTimeouts — synchronous WinHttp call can block the main thread")

	; SetTimeouts must appear BEFORE Req.Send() — a SetTimeouts after Send is too late.
	TimeoutPos := InStr(FnBody, "SetTimeouts")
	SendPos    := InStr(FnBody, "Req.Send(")
	if (HasTimeout and SendPos > 0) {
		AssertEqual(true, TimeoutPos < SendPos,
			"SetTimeouts must be called before Req.Send() in Updater_FetchLatestJson")
	}
}
Test("Updater: FetchLatestJson has timeout guard (regression: blocking main thread)", _UpdaterTest_FetchLatestJsonHasTimeout)


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


; Regression: no SetTimeouts() call anywhere in updater.ahk may pass a literal 0
; in the first (resolve) slot -- that magic-number form is the exact defect that
; froze the driver. A source scan catches a reintroduction even if it bypasses
; the named constants.
_UpdaterTest_NoZeroResolveTimeout() {
	Source := _DriverDirConcat("modules/updater")
	Found := RegExMatch(Source, "SetTimeouts\(\s*0\s*,") > 0
	AssertEqual(false, Found,
		"updater.ahk passes a literal 0 resolve timeout to SetTimeouts -- that is infinite in WinHttp and freezes the main thread")
}
Test("Updater: SetTimeouts never uses a 0 (infinite) resolve phase", _UpdaterTest_NoZeroResolveTimeout)


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


; The worker script is constructed at runtime, so a source-only scan cannot
; catch an accidental AHK string-concatenation regression that drops its argv
; contract or integrity checks before PowerShell is even launched.
_UpdaterTest_StagingWorkerScriptContract() {
	Script := _Updater_BuildStagingWorkerScript()
	AssertEqual(true, InStr(Script, "param([string]$Url") > 0,
		"Updater staging worker script must keep its URL argv contract")
	AssertEqual(true, InStr(Script, "$Request.ReadWriteTimeout = $TimeoutMs") > 0,
		"Updater staging worker script must apply a streaming timeout")
	AssertEqual(true, InStr(Script, "$ActualSize -ne $ExpectedSize") > 0,
		"Updater staging worker script must keep the truncated-download integrity check")
	AssertEqual(true, InStr(Script, "Get-FileHash -LiteralPath $NewExe -Algorithm SHA256") > 0,
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



; =========================================
; ===== AHK-14 request pause contract =====
; =========================================

class _UpdaterTestReadyHttp {
	__New() {
		this.Status := 200
		this.ResponseText := '{"tag_name":"v9.9.9"}'
	}

	WaitForResponse(*) {
		return true
	}

	GetResponseHeader(*) {
		return ""
	}
}

_UpdaterTest_SaveRequestState() {
	global _UpdaterAsyncRequests, _UpdaterAsyncCounter, _UpdaterRequestCounter
	global _UpdaterActiveSendLeaseCount, _UpdaterActiveAsyncTerminalDeliveryCount
	global _UpdaterAsyncAdmissionBoundary
	global _UpdaterAsyncActionLeases, _UpdaterAsyncActionLeaseCounter
	global _UpdaterChannelReloadTransition, _UpdaterChannelReloadCounter
	global _UpdaterChannelEpoch, UPDATER_CHANNEL
	global _UpdaterPauseGeneration, _UpdaterPendingManualPauseNoticeCount
	global _UpdaterPendingManualPauseNoticeIds
	global _UpdaterBackgroundGeneration
	global _UpdaterMenuRebuildPending, _UpdaterPendingReleaseNotification
	return {
		Requests: _UpdaterAsyncRequests,
		Counter: _UpdaterAsyncCounter,
		SendLeaseCount: IsSet(_UpdaterActiveSendLeaseCount)
			? _UpdaterActiveSendLeaseCount
			: 0,
		HadTerminalDeliveryCount: IsSet(_UpdaterActiveAsyncTerminalDeliveryCount),
		TerminalDeliveryCount: IsSet(_UpdaterActiveAsyncTerminalDeliveryCount)
			? _UpdaterActiveAsyncTerminalDeliveryCount
			: 0,
		HadAdmissionBoundary: IsSet(_UpdaterAsyncAdmissionBoundary),
		AdmissionBoundary: IsSet(_UpdaterAsyncAdmissionBoundary)
			? _UpdaterAsyncAdmissionBoundary
			: 0,
		HadActionLeases: IsSet(_UpdaterAsyncActionLeases),
		ActionLeases: IsSet(_UpdaterAsyncActionLeases)
			? _UpdaterAsyncActionLeases
			: Map(),
		HadActionLeaseCounter: IsSet(_UpdaterAsyncActionLeaseCounter),
		ActionLeaseCounter: IsSet(_UpdaterAsyncActionLeaseCounter)
			? _UpdaterAsyncActionLeaseCounter
			: 0,
		HadChannelReloadTransition: IsSet(_UpdaterChannelReloadTransition),
		ChannelReloadTransition: IsSet(_UpdaterChannelReloadTransition)
			? _UpdaterChannelReloadTransition
			: 0,
		HadChannelReloadCounter: IsSet(_UpdaterChannelReloadCounter),
		ChannelReloadCounter: IsSet(_UpdaterChannelReloadCounter)
			? _UpdaterChannelReloadCounter
			: 0,
		HadChannelEpoch: IsSet(_UpdaterChannelEpoch),
		ChannelEpoch: IsSet(_UpdaterChannelEpoch) ? _UpdaterChannelEpoch : 1,
		Channel: UPDATER_CHANNEL,
		RequestCounter: _UpdaterRequestCounter,
		Generation: _UpdaterPauseGeneration,
		BackgroundGeneration: _UpdaterBackgroundGeneration,
		PendingNoticeCount: _UpdaterPendingManualPauseNoticeCount,
		PendingNoticeIds: _UpdaterPendingManualPauseNoticeIds,
		MenuRebuildPending: _UpdaterMenuRebuildPending,
		PendingReleaseNotification: _UpdaterPendingReleaseNotification
	}
}

_UpdaterTest_ResetRequestState() {
	global _UpdaterAsyncRequests, _UpdaterAsyncCounter, _UpdaterRequestCounter
	global _UpdaterActiveSendLeaseCount, _UpdaterActiveAsyncTerminalDeliveryCount
	global _UpdaterAsyncAdmissionBoundary
	global _UpdaterAsyncActionLeases, _UpdaterAsyncActionLeaseCounter
	global _UpdaterChannelReloadTransition, _UpdaterChannelReloadCounter
	global _UpdaterChannelEpoch, UPDATER_CHANNEL
	global _UpdaterPauseGeneration, _UpdaterPendingManualPauseNoticeCount
	global _UpdaterPendingManualPauseNoticeIds
	global _UpdaterBackgroundGeneration
	global _UpdaterMenuRebuildPending, _UpdaterPendingReleaseNotification
	_UpdaterAsyncRequests := Map()
	_UpdaterAsyncCounter := 0
	_UpdaterActiveSendLeaseCount := 0
	_UpdaterActiveAsyncTerminalDeliveryCount := 0
	_UpdaterAsyncAdmissionBoundary := 0
	_UpdaterAsyncActionLeases := Map()
	_UpdaterAsyncActionLeaseCounter := 0
	_UpdaterChannelReloadTransition := 0
	_UpdaterChannelReloadCounter := 0
	_UpdaterChannelEpoch := 1
	UPDATER_CHANNEL := "main"
	_UpdaterRequestCounter := 0
	_UpdaterPauseGeneration := 1
	_UpdaterBackgroundGeneration := 1
	_UpdaterPendingManualPauseNoticeCount := 0
	_UpdaterPendingManualPauseNoticeIds := Map()
	_UpdaterMenuRebuildPending := false
	_UpdaterPendingReleaseNotification := 0
}

_UpdaterTest_CleanupTransientConfigBundles(Saved) {
	global _UpdaterChannelReloadTransition, _UpdaterAsyncActionLeases
	SavedBundles := Map()
	if (Saved.HadChannelReloadTransition
		and IsObject(Saved.ChannelReloadTransition)
		and Saved.ChannelReloadTransition.HasOwnProp("ConfigBundle")
		and IsObject(Saved.ChannelReloadTransition.ConfigBundle))
		SavedBundles[ObjPtr(Saved.ChannelReloadTransition.ConfigBundle)] := true
	if Saved.HadActionLeases {
		for _, Owner in Saved.ActionLeases {
			if IsObject(Owner) and Owner.HasOwnProp("ConfigBundle")
				and IsObject(Owner.ConfigBundle)
				SavedBundles[ObjPtr(Owner.ConfigBundle)] := true
		}
	}
	Candidates := []
	if (IsSet(_UpdaterChannelReloadTransition)
		and IsObject(_UpdaterChannelReloadTransition)
		and _UpdaterChannelReloadTransition.HasOwnProp("ConfigBundle"))
		Candidates.Push(_UpdaterChannelReloadTransition.ConfigBundle)
	if IsSet(_UpdaterAsyncActionLeases) {
		for _, Owner in _UpdaterAsyncActionLeases {
			if IsObject(Owner) and Owner.HasOwnProp("ConfigBundle")
				Candidates.Push(Owner.ConfigBundle)
		}
	}
	for Bundle in Candidates {
		if IsObject(Bundle) and !SavedBundles.Has(ObjPtr(Bundle))
			_Updater_ReleaseChannelConfigBundle(Bundle)
	}
}

_UpdaterTest_RestoreRequestState(Saved) {
	global _UpdaterAsyncRequests, _UpdaterAsyncCounter, _UpdaterRequestCounter
	global _UpdaterActiveSendLeaseCount, _UpdaterActiveAsyncTerminalDeliveryCount
	global _UpdaterAsyncAdmissionBoundary
	global _UpdaterAsyncActionLeases, _UpdaterAsyncActionLeaseCounter
	global _UpdaterChannelReloadTransition, _UpdaterChannelReloadCounter
	global _UpdaterChannelEpoch, UPDATER_CHANNEL
	global _UpdaterPauseGeneration, _UpdaterPendingManualPauseNoticeCount
	global _UpdaterPendingManualPauseNoticeIds
	global _UpdaterBackgroundGeneration
	global _UpdaterMenuRebuildPending, _UpdaterPendingReleaseNotification
	_UpdaterTest_CleanupTransientConfigBundles(Saved)
	_UpdaterAsyncRequests := Saved.Requests
	_UpdaterAsyncCounter := Saved.Counter
	_UpdaterActiveSendLeaseCount := Saved.SendLeaseCount
	if Saved.HadTerminalDeliveryCount
		_UpdaterActiveAsyncTerminalDeliveryCount := Saved.TerminalDeliveryCount
	else
		_UpdaterActiveAsyncTerminalDeliveryCount := unset
	if Saved.HadAdmissionBoundary
		_UpdaterAsyncAdmissionBoundary := Saved.AdmissionBoundary
	else
		_UpdaterAsyncAdmissionBoundary := unset
	if Saved.HadActionLeases
		_UpdaterAsyncActionLeases := Saved.ActionLeases
	else
		_UpdaterAsyncActionLeases := unset
	if Saved.HadActionLeaseCounter
		_UpdaterAsyncActionLeaseCounter := Saved.ActionLeaseCounter
	else
		_UpdaterAsyncActionLeaseCounter := unset
	if Saved.HadChannelReloadTransition
		_UpdaterChannelReloadTransition := Saved.ChannelReloadTransition
	else
		_UpdaterChannelReloadTransition := unset
	if Saved.HadChannelReloadCounter
		_UpdaterChannelReloadCounter := Saved.ChannelReloadCounter
	else
		_UpdaterChannelReloadCounter := unset
	if Saved.HadChannelEpoch
		_UpdaterChannelEpoch := Saved.ChannelEpoch
	else
		_UpdaterChannelEpoch := unset
	UPDATER_CHANNEL := Saved.Channel
	_UpdaterRequestCounter := Saved.RequestCounter
	_UpdaterPauseGeneration := Saved.Generation
	_UpdaterBackgroundGeneration := Saved.BackgroundGeneration
	_UpdaterPendingManualPauseNoticeCount := Saved.PendingNoticeCount
	_UpdaterPendingManualPauseNoticeIds := Saved.PendingNoticeIds
	_UpdaterMenuRebuildPending := Saved.MenuRebuildPending
	_UpdaterPendingReleaseNotification := Saved.PendingReleaseNotification
}

_UpdaterTest_RecordRequestTerminal(State, IsSuspended, Json, Request) {
	State.TerminalCount += 1
	if _Updater_RequestMayPublish(Request, IsSuspended)
		State.PublishCount += 1
}

_UpdaterTest_RecordResumeNotice(State, Message, Options) {
	State.Count += 1
	State.Message := Message
	State.Options := Options
}

_UpdaterTest_RecordCriticalResumeNotice(State, Message, Options) {
	State.Count += 1
	State.CriticalStates.Push(A_IsCritical)
}

_UpdaterTest_PausedTrayClickRefusesBeforeUpdaterWork() {
	State := { NotifyCount: 0, ContinueCount: 0, ShowCount: 0 }
	NotifyFn := (Message, Options) => (State.NotifyCount += 1)
	ContinueFn := () => (State.ContinueCount += 1)
	ShowFn := () => (
		State.ShowCount += 1,
		_Updater_ShowAvailableUpdateEntry(true, NotifyFn, ContinueFn))

	_Updater_OnTrayMsg(0, 0x405, 0x404, 0, ShowFn)
	AssertEqual(1, State.ShowCount,
		"a genuine balloon click must reach the updater policy boundary while paused")
	AssertEqual(1, State.NotifyCount,
		"a born-paused manual action must receive exactly one visible refusal")
	AssertEqual(0, State.ContinueCount,
		"born-paused work must stop before prompt, cache, or HTTP continuation")

	_Updater_OnTrayMsg(0, 0x406, 0x404, 0, ShowFn)
	AssertEqual(1, State.ShowCount,
		"non-balloon tray messages must not enter updater policy or produce output")
}
Test("Updater AHK-14: paused notification click refuses visibly before work",
	_UpdaterTest_PausedTrayClickRefusesBeforeUpdaterWork)

_UpdaterTest_MalformedProvenanceFailsClosed() {
	global UPDATER_REQUEST_ORIGIN_MANUAL, UPDATER_REQUEST_POLICY_DROP
	Malformed := [
		0,
		{},
		{ RequestId: 0, PauseTerminalState: { Claimed: false }, Origin: UPDATER_REQUEST_ORIGIN_MANUAL, BornSuspended: false, Generation: 1, BackgroundGeneration: 1, Channel: "main", ChannelEpoch: 1 },
		{ RequestId: 1, PauseTerminalState: 0, Origin: UPDATER_REQUEST_ORIGIN_MANUAL, BornSuspended: false, Generation: 1, BackgroundGeneration: 1, Channel: "main", ChannelEpoch: 1 },
		{ RequestId: 1, PauseTerminalState: { Claimed: false }, Origin: UPDATER_REQUEST_ORIGIN_MANUAL, BornSuspended: "0", Generation: 1, BackgroundGeneration: 1, Channel: "main", ChannelEpoch: 1 },
		{ RequestId: 1, PauseTerminalState: { Claimed: false }, Origin: {}, BornSuspended: false, Generation: 1, BackgroundGeneration: 1, Channel: "main", ChannelEpoch: 1 },
		{ RequestId: 1, PauseTerminalState: { Claimed: false }, Origin: UPDATER_REQUEST_ORIGIN_MANUAL, BornSuspended: false, Generation: -1, BackgroundGeneration: 1, Channel: "main", ChannelEpoch: 1 },
		{ RequestId: 1, PauseTerminalState: { Claimed: false }, Origin: UPDATER_REQUEST_ORIGIN_MANUAL, BornSuspended: false, Generation: 1, BackgroundGeneration: -1, Channel: "main", ChannelEpoch: 1 },
		{ RequestId: 1, PauseTerminalState: { Claimed: false }, Origin: UPDATER_REQUEST_ORIGIN_MANUAL, BornSuspended: false, Generation: 1, BackgroundGeneration: 1, ChannelEpoch: 1 },
		{ RequestId: 1, PauseTerminalState: { Claimed: false }, Origin: UPDATER_REQUEST_ORIGIN_MANUAL, BornSuspended: false, Generation: 1, BackgroundGeneration: 1, Channel: "beta", ChannelEpoch: 1 },
		{ RequestId: 1, PauseTerminalState: { Claimed: false }, Origin: UPDATER_REQUEST_ORIGIN_MANUAL, BornSuspended: false, Generation: 1, BackgroundGeneration: 1, Channel: "main" },
		{ RequestId: 1, PauseTerminalState: { Claimed: false }, Origin: UPDATER_REQUEST_ORIGIN_MANUAL, BornSuspended: false, Generation: 1, BackgroundGeneration: 1, Channel: "main", ChannelEpoch: 0 }
	]
	for _, Request in Malformed {
		AssertEqual(false, _Updater_RequestContextValid(Request),
			"malformed updater provenance must fail validation without a property-read exception")
		AssertEqual(UPDATER_REQUEST_POLICY_DROP, _Updater_RequestPolicy(Request, false),
			"malformed updater provenance must fail closed at the shared publication policy")
	}
}
Test("Updater AHK-14: malformed request provenance fails closed",
	_UpdaterTest_MalformedProvenanceFailsClosed)

_UpdaterTest_ManualBornPausedRefusesBeforeOwnership() {
	global UPDATER_REQUEST_ORIGIN_MANUAL, UPDATER_REQUEST_POLICY_DROP
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, true)
		State := { TerminalCount: 0, PublishCount: 0 }
		OnJson := (Json, CompletedRequest, Terminal := 0) => _UpdaterTest_RecordRequestTerminal(
			State, true, Json, CompletedRequest)
		Id := _Updater_RegisterAsyncRequest(
			_UpdaterTestReadyHttp(), "main", OnJson, "test://latest", Request)
		AssertEqual(UPDATER_REQUEST_POLICY_DROP, _Updater_RequestPolicy(Request, false),
			"manual-born-paused provenance must fail closed even after resume")
		AssertEqual(0, Id,
			"manual-born-paused work must never acquire async transport ownership")
		AssertEqual(0, State.TerminalCount,
			"a refused manual action must not manufacture an async completion")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-14: manual-born-paused action refuses before async ownership",
	_UpdaterTest_ManualBornPausedRefusesBeforeOwnership)

_UpdaterTest_BackgroundBornRunningDropsAtPause() {
	global UPDATER_REQUEST_ORIGIN_BACKGROUND, UPDATER_CANCEL_REASON_SUSPEND
	global _UpdaterPendingManualPauseNoticeCount
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_BACKGROUND, false)
		State := { TerminalCount: 0, PublishCount: 0 }
		OnJson := (Json, CompletedRequest, Terminal := 0) => _UpdaterTest_RecordRequestTerminal(
			State, true, Json, CompletedRequest)
		Id := _Updater_RegisterAsyncRequest(
			_UpdaterTestReadyHttp(), "main", OnJson, "test://latest", Request)
		Assert(Id > 0, "background-born-running request must be registered before pause")

		_Updater_CancelAsyncChecks(UPDATER_CANCEL_REASON_SUSPEND)
		_Updater_PollAsync(Id)

		AssertEqual(1, State.TerminalCount,
			"suspend cancellation must terminally release background ownership exactly once")
		AssertEqual(0, State.PublishCount,
			"background request born running must not publish after pause")
		AssertEqual(0, _UpdaterPendingManualPauseNoticeCount,
			"background cancellation must remain silent rather than queue manual feedback")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-14: background-born-running request drops after pause",
	_UpdaterTest_BackgroundBornRunningDropsAtPause)

_UpdaterTest_ManualBornRunningGetsOneResumeTerminal() {
	global UPDATER_REQUEST_ORIGIN_MANUAL, UPDATER_CANCEL_REASON_SUSPEND
	global _UpdaterPendingManualPauseNoticeCount
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, false)
		State := { TerminalCount: 0, PublishCount: 0 }
		OnJson := (Json, CompletedRequest, Terminal := 0) => _UpdaterTest_RecordRequestTerminal(
			State, true, Json, CompletedRequest)
		Id := _Updater_RegisterAsyncRequest(
			_UpdaterTestReadyHttp(), "main", OnJson, "test://latest", Request)
		Assert(Id > 0, "manual-born-running request must be registered before pause")

		_Updater_CancelAsyncChecks(UPDATER_CANCEL_REASON_SUSPEND)
		_Updater_PollAsync(Id)
		AssertEqual(1, State.TerminalCount,
			"manual request interrupted by pause must release callback ownership exactly once")
		AssertEqual(0, State.PublishCount,
			"manual request born running must not mutate UI while a later pause is active")
		AssertEqual(1, _UpdaterPendingManualPauseNoticeCount,
			"manual cancellation must queue a visible resume terminal instead of disappearing")

		Notice := { Count: 0, Message: "", Options: 0 }
		NotifyFn := (Message, Options) => _UpdaterTest_RecordResumeNotice(Notice, Message, Options)
		AssertEqual(true, Updater_OnSuspendResume(NotifyFn),
			"first resume must surface the deferred manual cancellation")
		AssertEqual(false, Updater_OnSuspendResume(NotifyFn),
			"second resume must not replay an already-consumed terminal")
		AssertEqual(1, Notice.Count,
			"manual request cancellation must produce exactly one visible resume notice")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-14: manual-born-running request cancels with one resume terminal",
	_UpdaterTest_ManualBornRunningGetsOneResumeTerminal)

_UpdaterTest_ManualPauseTerminalDeduplicatesByRequest() {
	global UPDATER_REQUEST_ORIGIN_MANUAL, _UpdaterPauseGeneration
	global _UpdaterPendingManualPauseNoticeCount, _UpdaterPendingManualPauseNoticeIds
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, false)
		_UpdaterPauseGeneration += 1

		AssertEqual(false, _Updater_RequestMayPublish(Request, true),
			"the first paused delivery must reject publication")
		AssertEqual(false, _Updater_RequestMayPublish(Request, true),
			"a duplicate delivery of the same immutable request must also reject publication")
		AssertEqual(1, _UpdaterPendingManualPauseNoticeCount,
			"duplicate callbacks carrying one request identity must retain one terminal, not two")
		AssertEqual(1, _UpdaterPendingManualPauseNoticeIds.Count,
			"the atomic pending-id registry must own exactly one request identity")

		Notice := { Count: 0, Message: "", Options: 0 }
		NotifyFn := (Message, Options) => _UpdaterTest_RecordResumeNotice(Notice, Message, Options)
		AssertEqual(true, Updater_OnSuspendResume(NotifyFn, false),
			"resume must surface the sole retained terminal")
		AssertEqual(false, _Updater_RequestMayPublish(Request, false),
			"a duplicate callback delivered after resume must remain terminally rejected")
		AssertEqual(0, _UpdaterPendingManualPauseNoticeCount,
			"a drained request-scoped claim must prevent a late duplicate from requeueing")
		AssertEqual(false, Updater_OnSuspendResume(NotifyFn, false),
			"a second resume must not replay the drained request identity")
		AssertEqual(1, Notice.Count,
			"one immutable request may produce at most one visible pause terminal")
		AssertEqual(0, _UpdaterPendingManualPauseNoticeCount,
			"draining must clean the bounded pending-id registry and its public count")
		AssertEqual(0, _UpdaterPendingManualPauseNoticeIds.Count,
			"draining must release every deduplication identity")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-14: duplicate callbacks retain one resume terminal per request",
	_UpdaterTest_ManualPauseTerminalDeduplicatesByRequest)

_UpdaterTest_ChangelogPauseTerminalRunsOutsideCritical() {
	global UPDATER_REQUEST_ORIGIN_MANUAL, _UpdaterPauseGeneration
	global _CLW_WindowEpoch, _CLW_RequestEpoch
	SavedRequest := _UpdaterTest_SaveRequestState()
	SavedWindowEpoch := _CLW_WindowEpoch
	SavedRequestEpoch := _CLW_RequestEpoch
	try {
		_UpdaterTest_ResetRequestState()
		_CLW_WindowEpoch := 101
		_CLW_RequestEpoch := 202
		Notice := { Count: 0, CriticalStates: [] }
		NotifyFn := (Message, Options) => _UpdaterTest_RecordCriticalResumeNotice(
			Notice, Message, Options)

		EvalRequest := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, false)
		_UpdaterPauseGeneration += 1
		EvalContext := {
			WindowEpoch: _CLW_WindowEpoch,
			RequestEpoch: _CLW_RequestEpoch,
			Request: EvalRequest
		}
		AssertEqual(false, _CLW_Eval("void 0", EvalContext, NotifyFn),
			"a stale changelog page mutation must be rejected")

		ScriptRequest := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, false)
		_UpdaterPauseGeneration += 1
		Work := {
			Js: "void 0",
			WindowEpoch: _CLW_WindowEpoch,
			RequestEpoch: _CLW_RequestEpoch,
			Request: ScriptRequest
		}
		_CLW_RunScript(Work, NotifyFn)

		AssertEqual(2, Notice.Count,
			"both changelog deferred boundaries must preserve one visible pause terminal")
		AssertEqual(0, Notice.CriticalStates[1],
			"_CLW_Eval must restore Critical before the notifier seam runs")
		AssertEqual(0, Notice.CriticalStates[2],
			"_CLW_RunScript must restore Critical before the notifier seam runs")
	} finally {
		_CLW_WindowEpoch := SavedWindowEpoch
		_CLW_RequestEpoch := SavedRequestEpoch
		_UpdaterTest_RestoreRequestState(SavedRequest)
	}
}
Test("Updater AHK-14: changelog pause terminals run outside Critical",
	_UpdaterTest_ChangelogPauseTerminalRunsOutsideCritical)

_UpdaterTest_ActivationPropagatesInstallStartResult() {
	global UPDATER_REQUEST_ORIGIN_MANUAL
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, false)
		Release := { Tag: "v9.9.9" }
		State := { InstallCount: 0, SuccessCount: 0 }
		RefuseInstall := (Candidate) => (
			State.InstallCount += 1,
			false)
		AcceptInstall := (Candidate) => (
			State.InstallCount += 1,
			true)
		SuccessFn := (Tag) => (State.SuccessCount += 1)

		AssertEqual(false, _Updater_ActivateCachedRelease(
			Release, Request, false, 0, RefuseInstall, SuccessFn),
			"a refused staging start must propagate false to the one-click lifecycle")
		AssertEqual(1, State.InstallCount,
			"the refused install seam must be invoked exactly once")
		AssertEqual(0, State.SuccessCount,
			"a refused staging start must not emit a misleading installing success")

		AssertEqual(true, _Updater_ActivateCachedRelease(
			Release, Request, false, 0, AcceptInstall, SuccessFn),
			"an accepted staging start must propagate true")
		AssertEqual(2, State.InstallCount,
			"the accepted install seam must be invoked exactly once")
		AssertEqual(1, State.SuccessCount,
			"only the accepted staging start may emit installing success")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-14: cached activation reports the real staging-start result",
	_UpdaterTest_ActivationPropagatesInstallStartResult)



; =====================================================
; ===== AHK-31 transport ownership before effects =====
; =====================================================

class _UpdaterTestOwnedPreparationHttp {
	__New(State, ThrowOnSend := false) {
		this.State := State
		this.ThrowOnSend := ThrowOnSend
	}

	Send() {
		this.State.Sends += 1
		if this.ThrowOnSend
			throw Error("deterministic Send failure")
		return true
	}

	Abort() {
		this.State.Aborts += 1
		return true
	}
}

class _UpdaterTestPhasePreparationHttp {
	__New(State, ThrowPhase) {
		this.State := State
		this.ThrowPhase := ThrowPhase
	}

	_Visit(Phase) {
		this.State.PhaseVisits.Push(Phase)
		if (this.ThrowPhase == Phase)
			throw Error("deterministic " . Phase . " preparation failure")
	}

	Open(*) {
		this._Visit("open")
	}

	SetRequestHeader(Name, *) {
		if (Name == "Accept")
			Phase := "accept"
		else if (Name == "User-Agent")
			Phase := "user-agent"
		else if (Name == "If-None-Match")
			Phase := "etag"
		else
			Phase := "other-header"
		this._Visit(Phase)
	}

	SetTimeouts(*) {
		this._Visit("timeouts")
	}

	Send() {
		this.State.Sends += 1
		return true
	}

	Abort() {
		this.State.Aborts += 1
		return true
	}
}

_UpdaterTest_CaptureOwnedPreparationTerminal(State, Json, Request,
	Terminal := 0) {
	State.Terminals += 1
	State.Json := Json
	State.CompletedRequest := Request
	State.Terminal := Terminal
}

_UpdaterTest_ThrowDuringPreparation(*) {
	throw Error("deterministic preparation failure")
}

_UpdaterTest_CancelUpdaterForSuspend(*) {
	global UPDATER_CANCEL_REASON_SUSPEND
	_Updater_CancelAsyncChecks(UPDATER_CANCEL_REASON_SUSPEND)
}

_UpdaterTest_CreatePhasePreparationHttp(State, ThrowPhase) {
	Http := _UpdaterTestPhasePreparationHttp(State, ThrowPhase)
	State.PhaseVisits.Push("factory")
	if (ThrowPhase == "factory")
		throw Error("deterministic factory preparation failure")
	return Http
}

_UpdaterTest_PrepareLatestWithFactory(PrepareLatest, FactoryFn, Owner) {
	return PrepareLatest.Call(Owner, FactoryFn)
}

_UpdaterTest_CancelDuringOwnedPreparation(State, RequestOwned, Owner) {
	State.OwnedDuringCancel := RequestOwned.Call(Owner)
	_UpdaterTest_CancelUpdaterForSuspend()
	return _UpdaterTestOwnedPreparationHttp(State)
}

_UpdaterTest_OwnerPrecedesTransportPreparation() {
	global UPDATER_REQUEST_ORIGIN_MANUAL
	RegisterOwner := _UpdaterTest_ResolveFunction(
		"_Updater_RegisterAsyncRequestOwner")
	SendOwned := _UpdaterTest_ResolveFunction("_Updater_SendOwnedAsyncRequest")
	RequestOwned := _UpdaterTest_ResolveFunction("_Updater_AsyncRequestOwned")
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		State := { OwnedDuringPrepare: false, Sends: 0, Aborts: 0,
			Polls: 0, Terminals: 0, Json: "not-called",
			CompletedRequest: 0, Terminal: 0 }
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)
		Owner := RegisterOwner.Call(
			0, "main",
			_UpdaterTest_CaptureOwnedPreparationTerminal.Bind(State),
			"test://owner-before-preparation", Request)
		PrepareFn := (ExactOwner) => (
			State.OwnedDuringPrepare := RequestOwned.Call(ExactOwner),
			_UpdaterTestOwnedPreparationHttp(State))
		PollFn := (Id) => (State.Polls += 1, true)

		Assert(IsObject(Owner),
			"the async request must publish an opaque owner before preparation")
		AssertEqual(true, SendOwned.Call(
			Owner, PollFn, "test owned preparation", PrepareFn),
			"owned preparation must reach Send and its poll handoff")
		AssertEqual(true, State.OwnedDuringPrepare,
			"registry ownership must already exist when the first transport effect runs")
		AssertEqual(1, State.Sends,
			"the prepared exact transport must be sent once")
		AssertEqual(1, State.Polls,
			"a successful owned Send must hand off to one poll owner")
		AssertEqual(0, State.Terminals,
			"a successful dispatch must not manufacture a failure terminal")
		_Updater_CancelAsyncChecks("test cleanup")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: owner precedes async transport preparation (updater-owner-before-preparation)",
	_UpdaterTest_OwnerPrecedesTransportPreparation)

_UpdaterTest_PreparationThrowRetiresExactOwner() {
	global UPDATER_REQUEST_ORIGIN_MANUAL, _UpdaterAsyncRequests
	RegisterOwner := _UpdaterTest_ResolveFunction(
		"_Updater_RegisterAsyncRequestOwner")
	SendOwned := _UpdaterTest_ResolveFunction("_Updater_SendOwnedAsyncRequest")
	RequestOwned := _UpdaterTest_ResolveFunction("_Updater_AsyncRequestOwned")
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		State := { Sends: 0, Aborts: 0, Polls: 0, Terminals: 0,
			Json: "not-called", CompletedRequest: 0, Terminal: 0 }
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)
		Owner := RegisterOwner.Call(
			0, "main",
			_UpdaterTest_CaptureOwnedPreparationTerminal.Bind(State),
			"test://preparation-throws", Request)
		PrepareFn := _UpdaterTest_ThrowDuringPreparation
		PollFn := (Id) => (State.Polls += 1, true)

		AssertEqual(false, SendOwned.Call(
			Owner, PollFn, "test preparation throw", PrepareFn),
			"a preparation exception must close the owned dispatch")
		AssertEqual(1, State.Terminals,
			"preparation failure must deliver exactly one callback terminal")
		Assert(State.Json is String and State.Json == "",
			"preparation failure must deliver the canonical empty JSON failure")
		Assert(IsObject(State.CompletedRequest)
			and ObjPtr(State.CompletedRequest) == ObjPtr(Request),
			"failure must terminal the immutable request that owned preparation")
		AssertEqual(false, RequestOwned.Call(Owner),
			"preparation failure must retire the exact registry owner")
		AssertEqual(0, _UpdaterAsyncRequests.Count,
			"preparation failure must leave no orphaned registry entry")
		AssertEqual(0, State.Polls,
			"a failed preparation must never arm response polling")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: preparation failure retires exact owner (updater-owner-before-preparation)",
	_UpdaterTest_PreparationThrowRetiresExactOwner)

_UpdaterTest_PreparationThrowAtEveryPhaseRetiresOwner() {
	global UPDATER_REQUEST_ORIGIN_MANUAL
	global _UpdaterAsyncRequests, _UpdaterFetchCache
	RegisterOwner := _UpdaterTest_ResolveFunction(
		"_Updater_RegisterAsyncRequestOwner")
	SendOwned := _UpdaterTest_ResolveFunction("_Updater_SendOwnedAsyncRequest")
	RequestOwned := _UpdaterTest_ResolveFunction("_Updater_AsyncRequestOwned")
	PrepareLatest := _UpdaterTest_ResolveFunction(
		"_Updater_PrepareLatestAsyncTransport")
	Saved := _UpdaterTest_SaveRequestState()
	HadCache := _UpdaterFetchCache.Has("main")
	SavedCache := HadCache ? _UpdaterFetchCache["main"] : 0
	try {
		_UpdaterFetchCache["main"] := { Etag: '"owner-test-etag"' }
		PreparationPhases := [
			"factory", "open", "accept", "user-agent", "timeouts", "etag"]
		for PhaseIndex, ThrowPhase in PreparationPhases {
			_UpdaterTest_ResetRequestState()
			State := { PhaseVisits: [], Sends: 0, Aborts: 0, Polls: 0,
				Terminals: 0, Json: "not-called", CompletedRequest: 0,
				Terminal: 0 }
			Request := _Updater_NewRequestContext(
				UPDATER_REQUEST_ORIGIN_MANUAL, false)
			Owner := RegisterOwner.Call(
				0, "main",
				_UpdaterTest_CaptureOwnedPreparationTerminal.Bind(State),
				"test://throw-during-" . ThrowPhase, Request)
			FactoryFn := _UpdaterTest_CreatePhasePreparationHttp.Bind(
				State, ThrowPhase)
			PrepareFn := _UpdaterTest_PrepareLatestWithFactory.Bind(
				PrepareLatest, FactoryFn)
			PollFn := (Id) => (State.Polls += 1, true)

			AssertEqual(false, SendOwned.Call(
				Owner, PollFn, "test phase preparation throw", PrepareFn),
				"a throw during " . ThrowPhase
				. " must stop the owned dispatch")
			AssertEqual(PhaseIndex, State.PhaseVisits.Length,
				"a throw during " . ThrowPhase
				. " must prevent every later preparation effect")
			AssertEqual(ThrowPhase, State.PhaseVisits[PhaseIndex],
				"the exact throwing preparation phase must be the last effect")
			AssertEqual(0, State.Sends,
				"a preparation owner that throws during " . ThrowPhase
				. " must never reach Send")
			AssertEqual(PhaseIndex == 1 ? 0 : 1, State.Aborts,
				"failure cleanup must abort exactly when a transport was published")
			AssertEqual(0, State.Polls,
				"a failed preparation must never hand off to polling")
			AssertEqual(1, State.Terminals,
				"each preparation failure must deliver exactly one terminal")
			AssertEqual(0, State.Terminal,
				"a preparation exception must not impersonate typed cancellation")
			Assert(IsObject(State.CompletedRequest)
				and ObjPtr(State.CompletedRequest) == ObjPtr(Request),
				"preparation failure must terminal the exact request")
			AssertEqual(false, RequestOwned.Call(Owner),
				"the failed exact owner must be retired")
			AssertEqual(0, _UpdaterAsyncRequests.Count,
				"preparation failure must leave no registry orphan")
		}
	} finally {
		if HadCache
			_UpdaterFetchCache["main"] := SavedCache
		else
			_UpdaterFetchCache.Delete("main")
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: every preparation phase failure retires exact owner (updater-owner-before-preparation)",
	_UpdaterTest_PreparationThrowAtEveryPhaseRetiresOwner)

_UpdaterTest_CancellationDuringOwnedPreparationWins() {
	global UPDATER_REQUEST_ORIGIN_MANUAL, UPDATER_CANCEL_REASON_SUSPEND
	global _UpdaterAsyncRequests
	RegisterOwner := _UpdaterTest_ResolveFunction(
		"_Updater_RegisterAsyncRequestOwner")
	SendOwned := _UpdaterTest_ResolveFunction("_Updater_SendOwnedAsyncRequest")
	RequestOwned := _UpdaterTest_ResolveFunction("_Updater_AsyncRequestOwned")
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		State := { OwnedDuringCancel: false, Sends: 0, Aborts: 0,
			Polls: 0, Terminals: 0, Json: "not-called",
			CompletedRequest: 0, Terminal: 0 }
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)
		Owner := RegisterOwner.Call(
			0, "main",
			_UpdaterTest_CaptureOwnedPreparationTerminal.Bind(State),
			"test://cancel-during-preparation", Request)
		PrepareFn := _UpdaterTest_CancelDuringOwnedPreparation.Bind(
			State, RequestOwned)
		PollFn := (Id) => (State.Polls += 1, true)

		AssertEqual(false, SendOwned.Call(
			Owner, PollFn, "test cancellation during preparation", PrepareFn),
			"cancellation during preparation must win before Send")
		AssertEqual(true, State.OwnedDuringCancel,
			"cancellation reached from preparation must find the exact owner")
		AssertEqual(0, State.Sends,
			"a request cancelled during preparation must never reach Send")
		AssertEqual(0, State.Polls,
			"a request cancelled during preparation must never start polling")
		AssertEqual(1, State.Terminals,
			"preparation cancellation must deliver exactly one terminal")
		Assert(_Updater_AsyncTerminalIsCancelled(State.Terminal),
			"preparation cancellation must retain its typed terminal")
		AssertEqual(UPDATER_CANCEL_REASON_SUSPEND, State.Terminal.Reason,
			"preparation cancellation must preserve its suspend reason")
		Assert(IsObject(State.CompletedRequest)
			and ObjPtr(State.CompletedRequest) == ObjPtr(Request),
			"preparation cancellation must terminal the exact request")
		AssertEqual(false, RequestOwned.Call(Owner),
			"preparation cancellation must retire the exact owner")
		AssertEqual(0, _UpdaterAsyncRequests.Count,
			"preparation cancellation must leave no registry orphan")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: cancellation during owned preparation wins (updater-owner-before-preparation)",
	_UpdaterTest_CancellationDuringOwnedPreparationWins)

_UpdaterTest_SendThrowRetiresExactOwner() {
	global UPDATER_REQUEST_ORIGIN_MANUAL, _UpdaterAsyncRequests
	RegisterOwner := _UpdaterTest_ResolveFunction(
		"_Updater_RegisterAsyncRequestOwner")
	SendOwned := _UpdaterTest_ResolveFunction("_Updater_SendOwnedAsyncRequest")
	RequestOwned := _UpdaterTest_ResolveFunction("_Updater_AsyncRequestOwned")
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		State := { Sends: 0, Aborts: 0, Polls: 0, Terminals: 0,
			Json: "not-called", CompletedRequest: 0, Terminal: 0 }
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)
		Owner := RegisterOwner.Call(
			0, "main",
			_UpdaterTest_CaptureOwnedPreparationTerminal.Bind(State),
			"test://send-throws", Request)
		PrepareFn := (*) => _UpdaterTestOwnedPreparationHttp(State, true)
		PollFn := (Id) => (State.Polls += 1, true)

		AssertEqual(false, SendOwned.Call(
			Owner, PollFn, "test Send throw", PrepareFn),
			"a Send exception must close the exact owned dispatch")
		AssertEqual(1, State.Sends,
			"the throwing transport must receive exactly one Send attempt")
		AssertEqual(1, State.Aborts,
			"Send failure cleanup must abort the exact prepared transport")
		AssertEqual(0, State.Polls,
			"a throwing Send must never hand off to polling")
		AssertEqual(1, State.Terminals,
			"Send failure must deliver exactly one failure terminal")
		Assert(State.Json is String and State.Json == "",
			"Send failure must deliver the canonical empty JSON failure")
		AssertEqual(0, State.Terminal,
			"a transport failure must not impersonate typed cancellation")
		AssertEqual(false, RequestOwned.Call(Owner),
			"Send failure must retire the exact registry owner")
		AssertEqual(0, _UpdaterAsyncRequests.Count,
			"Send failure must leave no orphaned registry entry")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: Send failure retires exact owner (updater-owner-before-preparation)",
	_UpdaterTest_SendThrowRetiresExactOwner)

_UpdaterTest_StaleOwnerCannotRetireReplacement() {
	global UPDATER_REQUEST_ORIGIN_MANUAL, _UpdaterAsyncRequests
	RegisterOwner := _UpdaterTest_ResolveFunction(
		"_Updater_RegisterAsyncRequestOwner")
	TakeRequest := _UpdaterTest_ResolveFunction("_Updater_TakeAsyncRequest")
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		State := { Terminals: 0, Json: "not-called",
			CompletedRequest: 0, Terminal: 0 }
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)
		Owner := RegisterOwner.Call(
			0, "main",
			_UpdaterTest_CaptureOwnedPreparationTerminal.Bind(State),
			"test://stale-owner", Request)
		Replacement := Owner.Record.Clone()
		PreviousCritical := A_IsCritical
		Critical("On")
		try _UpdaterAsyncRequests[Owner.Id] := Replacement
		finally Critical(PreviousCritical ? PreviousCritical : "Off")

		AssertEqual(false, TakeRequest.Call(Owner.Id, Owner.Record),
			"a stale owner must not retire a replacement at the same numeric id")
		Assert(_UpdaterAsyncRequests.Has(Owner.Id),
			"the exact replacement must remain registered after a stale take")
		AssertEqual(ObjPtr(Replacement), ObjPtr(_UpdaterAsyncRequests[Owner.Id]),
			"stale cleanup must preserve the replacement object's identity")
		AssertEqual(0, State.Terminals,
			"a stale owner must not terminal the replacement request")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: stale owner cannot retire replacement (updater-owner-before-preparation)",
	_UpdaterTest_StaleOwnerCannotRetireReplacement)


_UpdaterTest_InterruptDownloadStartBeforeReservation(State, Line) {
	global _UpdaterDownloadInProgress
	global UPDATER_CANCEL_REASON_SUSPEND
	State.Lines.Push(Line)
	if (State.Triggered or InStr(Line, "[START]") == 0
		or InStr(Line, "Downloading update") == 0)
		return
	State.Triggered := true
	State.OwnedAtStart := _UpdaterDownloadInProgress
	Pending := _Updater_SwapAsyncRequestsForBoundary(
		UPDATER_CANCEL_REASON_SUSPEND, Map())
	State.RetiredAsyncCount := Pending.Count
	State.CancelledTransaction := _Updater_CancelSelfUpdateForSuspend()
}

_UpdaterTest_DownloadStartPrecedesCancellableOwner() {
	global _UpdaterDownloadInProgress, _UpdaterDownloadWorker
	global _UpdaterDownloadRequest, _UpdaterSelfUpdateEpoch
	global _UpdaterRecoveryPublishTarget
	global _UpdaterSwapOwner, _UpdaterExitIntent, _UpdaterExitInvocation
	global _LOGGER_TEST_SINK
	global UPDATER_REQUEST_ORIGIN_MANUAL
	SavedRequestState := _UpdaterTest_SaveRequestState()
	SavedSelfUpdate := {
		InProgress: _UpdaterDownloadInProgress,
		Worker: _UpdaterDownloadWorker,
		Request: _UpdaterDownloadRequest,
		Epoch: _UpdaterSelfUpdateEpoch,
		RecoveryTargetSet: IsSet(_UpdaterRecoveryPublishTarget),
		RecoveryTarget: IsSet(_UpdaterRecoveryPublishTarget)
			? _UpdaterRecoveryPublishTarget : "",
		SwapOwner: _UpdaterSwapOwner,
		ExitIntent: _UpdaterExitIntent,
		ExitInvocation: _UpdaterExitInvocation
	}
	SavedSink := _LOGGER_TEST_SINK
	State := {
		Lines: [],
		Triggered: false,
		OwnedAtStart: -1,
		RetiredAsyncCount: -1,
		CancelledTransaction: -1
	}
	try {
		_UpdaterTest_ResetRequestState()
		_UpdaterDownloadInProgress := false
		_UpdaterDownloadWorker := 0
		_UpdaterDownloadRequest := 0
		_UpdaterRecoveryPublishTarget := ""
		_UpdaterSwapOwner := 0
		_UpdaterExitIntent := 0
		_UpdaterExitInvocation := 0
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)
		LoggerSetTestSink(
			_UpdaterTest_InterruptDownloadStartBeforeReservation.Bind(State))
		Outcome := _Updater_BeginDownloadTransaction(Request, false,
			"v-test-" . A_TickCount, "https://example.invalid/update.exe")

		AssertTrue(State.Triggered,
			"the deterministic logger sink must interrupt the exact download START")
		AssertFalse(State.OwnedAtStart,
			"START must become observable before any cancellable download owner is published")
		AssertEqual(0, State.RetiredAsyncCount,
			"the isolated interleave must retire no unrelated async request")
		AssertFalse(State.CancelledTransaction,
			"Pause inside START must find no half-published transaction to terminate")
		Assert(Outcome.ShouldDrop and !Outcome.Reserved,
			"the resumed reservation must reject the request invalidated inside START")
		AssertFalse(_UpdaterDownloadInProgress,
			"the rejected reservation must leave the central transaction unowned")
		AssertFalse(IsObject(_UpdaterDownloadRequest),
			"the rejected reservation must not publish stale manual provenance")

		StartCount := 0
		TerminalCount := 0
		StartPos := 0
		TerminalPos := 0
		for Index, LoggedLine in State.Lines {
			if (InStr(LoggedLine, "[START]") > 0
				and InStr(LoggedLine, "Downloading update") > 0) {
				StartCount += 1
				StartPos := Index
			}
			if ((InStr(LoggedLine, "[WARNING]") > 0
				or InStr(LoggedLine, "[ERROR]") > 0)
				and InStr(LoggedLine, "Download") > 0) {
				TerminalCount += 1
				TerminalPos := Index
			}
		}
		AssertEqual(1, StartCount,
			"the interrupted attempt must emit exactly one lifecycle START")
		AssertEqual(1, TerminalCount,
			"the rejected attempt must close START with exactly one terminal")
		Assert(TerminalPos > StartPos,
			"the terminal must follow START in observable logger order")
	} finally {
		_LOGGER_TEST_SINK := SavedSink
		_UpdaterDownloadInProgress := SavedSelfUpdate.InProgress
		_UpdaterDownloadWorker := SavedSelfUpdate.Worker
		_UpdaterDownloadRequest := SavedSelfUpdate.Request
		_UpdaterSelfUpdateEpoch := SavedSelfUpdate.Epoch
		if SavedSelfUpdate.RecoveryTargetSet
			_UpdaterRecoveryPublishTarget := SavedSelfUpdate.RecoveryTarget
		else
			_UpdaterRecoveryPublishTarget := unset
		_UpdaterSwapOwner := SavedSelfUpdate.SwapOwner
		_UpdaterExitIntent := SavedSelfUpdate.ExitIntent
		_UpdaterExitInvocation := SavedSelfUpdate.ExitInvocation
		_UpdaterTest_RestoreRequestState(SavedRequestState)
	}
}

Test("Updater AHK-33: download START precedes cancellable owner (updater-download-logger-order)",
	_UpdaterTest_DownloadStartPrecedesCancellableOwner)



; ==================================================
; ===== AHK-31 channel replacement transaction =====
; ==================================================

_UpdaterTest_RequireChannelTransactionFunctions(Names) {
	for _, Name in Names {
		if (_DriverFuncBodyOrEmpty(Name) == "") {
			Assert(false, "AHK-31 channel replacement requires " . Name . "()")
			return false
		}
	}
	return true
}

_UpdaterTest_AcquireChannelConfigBundle() {
	global ConfigurationFile
	Bundle := _ConfigWriteTerminalTryAcquire([ConfigurationFile])
	Assert(IsObject(Bundle),
		"the deferred channel repro must own one global configuration bundle")
	return Bundle
}

class _UpdaterTestChannelHttp {
	__New(State) {
		this.State := State
	}

	Abort() {
		this.State.Aborts += 1
		return true
	}
}

_UpdaterTest_RecordChannelNotice(State, Message, Options) {
	State.Notices += 1
	if State.HasOwnProp("CriticalStates")
		State.CriticalStates.Push({ Phase: "notify", Value: A_IsCritical })
	if State.HasOwnProp("Messages")
		State.Messages.Push(Message)
	return true
}

_UpdaterTest_RecordBlockedCadenceSchedule(State, TimerFn, DelayMs) {
	State.CadenceSchedules += 1
	return true
}

_UpdaterTest_CaptureChannelAdmissionTerminal(State, Json, Request,
	Terminal := 0) {
	State.Terminals += 1
	State.Terminal := Terminal
	State.TerminalDeliveryOwned := _Updater_AsyncTerminalDeliveryActive()
}

_UpdaterTest_ProbeChannelWrite(State, Mode, Args*) {
	global UPDATER_REQUEST_ORIGIN_BACKGROUND
	State.BoundaryDuringWrite := _Updater_AsyncAdmissionBoundaryActive()
	Request := _Updater_NewRequestContext(
		UPDATER_REQUEST_ORIGIN_BACKGROUND, false)
	State.RefusedOwner := _Updater_RegisterAsyncRequestOwner(
		0, "main", _UpdaterTest_CaptureChannelAdmissionTerminal.Bind(State),
		"test://during-channel-write", Request)
	State.CadenceStartResult := Updater_StartBackgroundChecks(
		_UpdaterTest_RecordBlockedCadenceSchedule.Bind(State), false)
	if (Mode == "throw")
		throw Error("deterministic channel persistence failure")
	return false
}

_UpdaterTest_ChannelAdmissionPrecedesPersistenceAndFailureReleases() {
	global UPDATER_CHANNEL, UPDATER_CHECK_INTERVAL
	global UPDATER_REQUEST_ORIGIN_MANUAL
	global UPDATER_CANCEL_REASON_CHANNEL_SWITCH
	global _UpdaterDownloadInProgress
	global _UpdaterBackgroundFn, _UpdaterBackgroundOwner
	global _UpdaterBackgroundOwnerCounter, _UpdaterAsyncRequests
	global _UpdaterActiveAsyncTerminalDeliveryCount
	global _UpdaterChannelEpoch, _UpdaterFetchCache
	global UPDATER_LATEST_RELEASE, _UpdaterPendingReleaseNotification
	if !_UpdaterTest_RequireChannelTransactionFunctions([
		"_Updater_BeginAsyncAdmissionBoundary",
		"_Updater_EndAsyncAdmissionBoundary",
		"_Updater_AsyncAdmissionBoundaryActive",
		"_Updater_ChannelReloadTransitionActive",
		"_Updater_AsyncTerminalDeliveryActive"
	])
		return
	Saved := _UpdaterTest_SaveRequestState()
	SavedDownload := _UpdaterDownloadInProgress
	SavedInterval := UPDATER_CHECK_INTERVAL
	HadBackgroundFn := IsSet(_UpdaterBackgroundFn)
	if HadBackgroundFn
		SavedBackgroundFn := _UpdaterBackgroundFn
	HadBackgroundOwner := IsSet(_UpdaterBackgroundOwner)
	if HadBackgroundOwner
		SavedBackgroundOwner := _UpdaterBackgroundOwner
	SavedBackgroundCounter := _UpdaterBackgroundOwnerCounter
	SavedFetchCache := _UpdaterFetchCache
	HadLatestRelease := IsSet(UPDATER_LATEST_RELEASE)
	if HadLatestRelease
		SavedLatestRelease := UPDATER_LATEST_RELEASE
	SetChannelFn := _UpdaterTest_ResolveFunction("Updater_SetChannel")
	try {
		for _, Mode in ["false", "throw"] {
			_UpdaterTest_ResetRequestState()
			_UpdaterDownloadInProgress := false
			UPDATER_CHECK_INTERVAL := 60
			_UpdaterBackgroundFn := unset
			_UpdaterBackgroundOwner := 0
			_UpdaterChannelEpoch := 41
			_UpdaterFetchCache := Map("sentinel", "preserve")
			CacheBefore := _UpdaterFetchCache
			_UpdaterPendingReleaseNotification := { Sentinel: true }
			PendingBefore := _UpdaterPendingReleaseNotification
			UPDATER_LATEST_RELEASE := { Tag: "v-preserve" }
			LatestBefore := UPDATER_LATEST_RELEASE
			State := {
				BoundaryDuringWrite: false,
				RefusedOwner: 0,
				Terminals: 0,
				Terminal: 0,
				TerminalDeliveryOwned: false,
				CadenceSchedules: 0,
				CadenceStartResult: true,
				Notices: 0
			}
			Request := _Updater_NewRequestContext(
				UPDATER_REQUEST_ORIGIN_MANUAL, false)
			Result := SetChannelFn.Call(
				"dev", Request, false,
				_UpdaterTest_RecordChannelNotice.Bind(State),
				_UpdaterTest_ProbeChannelWrite.Bind(State, Mode))

			AssertEqual(false, Result,
				"channel persistence " . Mode . " must refuse publication")
			AssertEqual(true, State.BoundaryDuringWrite,
				"HTTP admission must close before the first yielding TOML effect")
			Assert(IsObject(State.RefusedOwner)
				and State.RefusedOwner.Id == 0
				and State.RefusedOwner.HasOwnProp("TerminalDelivered"),
				"reentrant HTTP registration must receive only an already-terminal Id=0 token")
			AssertEqual(1, State.Terminals,
				"closed admission must deliver one exact callback terminal")
			Assert(_Updater_AsyncTerminalIsCancelled(State.Terminal)
				and State.Terminal.Reason == UPDATER_CANCEL_REASON_CHANNEL_SWITCH,
				"admission refusal must retain the typed channel-switch reason")
			AssertEqual(true, State.TerminalDeliveryOwned,
				"admission refusal must publish terminal quiescence before callback entry")
			AssertEqual(0, _UpdaterActiveAsyncTerminalDeliveryCount,
				"admission refusal must balance terminal ownership after callback return")
			AssertEqual(false, State.CadenceStartResult,
				"background cadence cannot acquire a producer during channel persistence")
			AssertEqual(0, State.CadenceSchedules,
				"closed admission must prevent even the first timer-scheduler effect")
			AssertEqual(false, IsSet(_UpdaterBackgroundFn),
				"cadence refusal must not publish a dead timer callback")
			AssertEqual(false, IsObject(_UpdaterBackgroundOwner),
				"cadence refusal must not publish a dead owner")
			AssertEqual(0, _UpdaterAsyncRequests.Count,
				"reentrant HTTP work must never enter the replacement registry")
			AssertEqual("main", UPDATER_CHANNEL,
				"failed persistence must retain the active channel")
			AssertEqual(41, _UpdaterChannelEpoch,
				"failed persistence must not invalidate the live channel epoch")
			Assert(ObjPtr(_UpdaterFetchCache) == ObjPtr(CacheBefore),
				"failed persistence must retain the exact derived fetch cache")
			Assert(ObjPtr(_UpdaterPendingReleaseNotification)
				== ObjPtr(PendingBefore),
				"failed persistence must retain pending release state")
			Assert(ObjPtr(UPDATER_LATEST_RELEASE) == ObjPtr(LatestBefore),
				"failed persistence must retain the latest-release snapshot")
			AssertEqual(false, _Updater_AsyncAdmissionBoundaryActive(),
				"false/throw persistence must retire the exact admission boundary")
			AssertEqual(false, _Updater_ChannelReloadTransitionActive(),
				"failed persistence must never publish a deferred Reload owner")
			AssertEqual(1, State.Notices,
				"persistence failure must have one visible terminal")
		}
	} finally {
		try Updater_StopBackgroundChecks(false)
		_UpdaterDownloadInProgress := SavedDownload
		UPDATER_CHECK_INTERVAL := SavedInterval
		_UpdaterBackgroundOwnerCounter := SavedBackgroundCounter
		if HadBackgroundFn
			_UpdaterBackgroundFn := SavedBackgroundFn
		else
			_UpdaterBackgroundFn := unset
		if HadBackgroundOwner
			_UpdaterBackgroundOwner := SavedBackgroundOwner
		else
			_UpdaterBackgroundOwner := unset
		_UpdaterTest_RestoreRequestState(Saved)
		_UpdaterFetchCache := SavedFetchCache
		if HadLatestRelease
			UPDATER_LATEST_RELEASE := SavedLatestRelease
		else
			UPDATER_LATEST_RELEASE := unset
	}
}
Test("Updater AHK-31: channel admission precedes persistence and releases on failure (updater-channel-replacement-transaction)",
	_UpdaterTest_ChannelAdmissionPrecedesPersistenceAndFailureReleases)

_UpdaterTest_CountUnexpectedSettingsWrite(State, Args*) {
	State.Writes += 1
	return true
}

_UpdaterTest_AcceptMenuSchedule(State, Args*) {
	State.MenuSchedules += 1
	return true
}

_UpdaterTest_ProbeIntervalLeaseAgainstChannel(State, Args*) {
	global UPDATER_REQUEST_ORIGIN_MANUAL
	State.IntervalWrites += 1
	Request := _Updater_NewRequestContext(
		UPDATER_REQUEST_ORIGIN_MANUAL, false)
	State.ChannelResult := _UpdaterTest_ResolveFunction(
		"Updater_SetChannel").Call(
		"dev", Request, false,
		_UpdaterTest_RecordChannelNotice.Bind(State),
		_UpdaterTest_CountUnexpectedSettingsWrite.Bind(State))
	return false
}

_UpdaterTest_CountNestedIntervalWrite(State, Args*) {
	State.NestedWrites += 1
	return true
}

_UpdaterTest_ProbeIntervalLeaseAgainstInterval(State, Args*) {
	global UPDATER_REQUEST_ORIGIN_MANUAL
	State.OuterWrites += 1
	Request := _Updater_NewRequestContext(
		UPDATER_REQUEST_ORIGIN_MANUAL, false)
	State.NestedIntervalResult := Updater_SetCheckInterval(
		120, Request, false,
		_UpdaterTest_RecordChannelNotice.Bind(State),
		_UpdaterTest_CountNestedIntervalWrite.Bind(State))
	return true
}

_UpdaterTest_ActionLeasesSerializeChannelAndSiblingActions() {
	global UPDATER_CHANNEL, UPDATER_CHECK_INTERVAL
	global UPDATER_REQUEST_ORIGIN_MANUAL
	global _UpdaterAsyncActionLeases, _UpdaterDownloadInProgress
	Saved := _UpdaterTest_SaveRequestState()
	SavedDownload := _UpdaterDownloadInProgress
	SavedInterval := UPDATER_CHECK_INTERVAL
	try {
		_UpdaterTest_ResetRequestState()
		_UpdaterDownloadInProgress := false
		UPDATER_CHECK_INTERVAL := 60
		State := { Writes: 0, IntervalWrites: 0, Notices: 0,
			ChannelResult: true, OuterWrites: 0, NestedWrites: 0,
			NestedIntervalResult: true, MenuSchedules: 0 }
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)

		BoundaryOwner := _Updater_BeginAsyncAdmissionBoundary("channel switch")
		Assert(IsObject(BoundaryOwner),
			"the test must own a closed channel boundary")
		AssertEqual(false, Updater_SetCheckInterval(
			91, Request, false,
			_UpdaterTest_RecordChannelNotice.Bind(State),
			_UpdaterTest_CountUnexpectedSettingsWrite.Bind(State)),
			"a nested cadence write must refuse before persistence")
		AssertEqual(false, Updater_DownloadAndInstall(
			{ RawJson: "{}", Tag: "v-test" }, Request, false, 0,
			_UpdaterTest_RecordChannelNotice.Bind(State)),
			"a nested install action must refuse before staging admission")
		AssertEqual(0, State.Writes,
			"closed channel admission must prevent every sibling TOML effect")
		AssertEqual(60, UPDATER_CHECK_INTERVAL,
			"refused cadence work must not publish runtime state")
		AssertEqual(false, _UpdaterDownloadInProgress,
			"refused install work must not publish the download singleton")
		AssertEqual(0, _UpdaterAsyncActionLeases.Count,
			"refused actions must not leak a phantom lease")
		AssertEqual(true, _Updater_EndAsyncAdmissionBoundary(BoundaryOwner),
			"the exact test boundary must remain owned until explicit release")
		_UpdaterDownloadInProgress := true
		AssertEqual(false, _UpdaterTest_ResolveFunction(
			"Updater_SetChannel").Call(
			"dev", Request, false,
			_UpdaterTest_RecordChannelNotice.Bind(State),
			_UpdaterTest_CountUnexpectedSettingsWrite.Bind(State)),
			"an active staging transaction must refuse channel replacement")
		AssertEqual(0, State.Writes,
			"download-active refusal must happen before persistence")
		AssertEqual(false, _Updater_AsyncAdmissionBoundaryActive(),
			"download-active refusal must not publish a channel boundary")
		_UpdaterDownloadInProgress := false

		AssertEqual(false, Updater_SetCheckInterval(
			92, Request, false,
			_UpdaterTest_RecordChannelNotice.Bind(State),
			_UpdaterTest_ProbeIntervalLeaseAgainstChannel.Bind(State)),
			"the deterministic interval write fails after its nested channel probe")
		AssertEqual(1, State.IntervalWrites,
			"the interval action must enter its yielding persistence seam once")
		AssertEqual(false, State.ChannelResult,
			"a channel switch must refuse while the interval lease is live")
		AssertEqual(0, State.Writes,
			"the refused nested channel switch must never reach persistence")
		AssertEqual("main", UPDATER_CHANNEL,
			"the nested channel refusal must leave runtime channel unchanged")
		AssertEqual(60, UPDATER_CHECK_INTERVAL,
			"the deliberately failed interval write must leave cadence unchanged")
		AssertEqual(0, _UpdaterAsyncActionLeases.Count,
			"the failed interval action must release its exact lease from finally")

		AssertEqual(true, Updater_SetCheckInterval(
			0, Request, false,
			_UpdaterTest_RecordChannelNotice.Bind(State),
			_UpdaterTest_ProbeIntervalLeaseAgainstInterval.Bind(State),
			_UpdaterTest_AcceptMenuSchedule.Bind(State)),
			"the outer interval transaction must complete after refusing reentrance")
		AssertEqual(1, State.OuterWrites,
			"the outer interval writer must run once")
		AssertEqual(false, State.NestedIntervalResult,
			"a second interval action cannot overlap the first exact lease")
		AssertEqual(0, State.NestedWrites,
			"nested interval persistence must be refused before its first effect")
		AssertEqual(0, UPDATER_CHECK_INTERVAL,
			"runtime cadence must match the sole admitted durable transaction")
		AssertEqual(0, _UpdaterAsyncActionLeases.Count,
			"successful interval publication must release its exact lease")
		AssertEqual(1, State.MenuSchedules,
			"successful interval publication must request one deferred menu handoff")
		AssertEqual(6, State.Notices,
			"boundary, download, nested-channel, persistence and nested-action refusals must each stay visible")
	} finally {
		_UpdaterDownloadInProgress := SavedDownload
		UPDATER_CHECK_INTERVAL := SavedInterval
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: action leases serialize channel, cadence and install ingress (updater-channel-replacement-transaction)",
	_UpdaterTest_ActionLeasesSerializeChannelAndSiblingActions)

_UpdaterTest_AdmissionWrapperTerminal(State, Json, Request, Terminal := 0) {
	State.Terminals += 1
	State.Terminal := Terminal
	State.TerminalOwned := _Updater_AsyncTerminalDeliveryActive()
}

_UpdaterTest_AdmissionRefusalStopsRealAsyncWrappers() {
	global UPDATER_REQUEST_ORIGIN_MANUAL, _UpdaterAsyncRequests
	global _UpdaterActiveAsyncTerminalDeliveryCount
	Saved := _UpdaterTest_SaveRequestState()
	BoundaryOwner := 0
	try {
		_UpdaterTest_ResetRequestState()
		State := { Terminals: 0, Terminal: 0, TerminalOwned: false,
			Polls: 0 }
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)
		BoundaryOwner := _Updater_BeginAsyncAdmissionBoundary("channel switch")
		LatestOwner := _Updater_FetchLatestJsonAsync(
			"main", Request,
			_UpdaterTest_AdmissionWrapperTerminal.Bind(State))
		ListOwner := _Updater_FetchReleasesListJsonAsync(
			"main", Request,
			_UpdaterTest_AdmissionWrapperTerminal.Bind(State))
		Assert(IsObject(LatestOwner) and LatestOwner.Id == 0
			and IsObject(ListOwner) and ListOwner.Id == 0,
			"both real async wrappers must return only terminal Id=0 tokens")
		AssertEqual(2, State.Terminals,
			"each refused wrapper must deliver one typed terminal")
		AssertEqual(true, State.TerminalOwned,
			"wrapper refusal must own terminal quiescence during callback")
		Assert(_Updater_AsyncTerminalIsCancelled(State.Terminal),
			"wrapper refusal must retain typed cancellation")
		AssertEqual(false, _Updater_SendOwnedAsyncRequest(
			LatestOwner, (Id) => (State.Polls += 1),
			"refused owner replay"),
			"an Id=0 terminal token can never enter transport dispatch")
		AssertEqual(0, State.Polls,
			"an Id=0 terminal token can never hand off a poll")
		AssertEqual(2, State.Terminals,
			"replaying the refused token must not duplicate its terminal")
		AssertEqual(0, _UpdaterAsyncRequests.Count,
			"refused wrappers must never publish registry ownership")
		AssertEqual(0, _UpdaterActiveAsyncTerminalDeliveryCount,
			"both refusal callbacks must balance terminal ownership")
	} finally {
		if IsObject(BoundaryOwner)
			_Updater_EndAsyncAdmissionBoundary(BoundaryOwner)
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: real async wrappers stop at admission refusal (updater-channel-replacement-transaction)",
	_UpdaterTest_AdmissionRefusalStopsRealAsyncWrappers)

_UpdaterTest_IntervalCancellationProbesLease(State, Json, Request,
	Terminal := 0) {
	global _UpdaterAsyncActionLeases
	State.Callbacks += 1
	State.Terminal := Terminal
	State.LeasesDuringCallback := _UpdaterAsyncActionLeases.Count
	State.ChannelResult := _UpdaterTest_ResolveFunction(
		"Updater_SetChannel").Call(
		"dev", Request, false,
		_UpdaterTest_RecordChannelNotice.Bind(State),
		_UpdaterTest_CountUnexpectedSettingsWrite.Bind(State))
}

_UpdaterTest_IntervalLeaseSpansPostcommitCancellation() {
	global UPDATER_CHECK_INTERVAL, UPDATER_REQUEST_ORIGIN_MANUAL
	global _UpdaterAsyncActionLeases
	Saved := _UpdaterTest_SaveRequestState()
	SavedInterval := UPDATER_CHECK_INTERVAL
	try {
		_UpdaterTest_ResetRequestState()
		UPDATER_CHECK_INTERVAL := 60
		State := { Writes: 0, Notices: 0, Callbacks: 0,
			Terminal: 0, LeasesDuringCallback: 0,
			ChannelResult: true, MenuSchedules: 0 }
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)
		_Updater_RegisterAsyncRequestOwner(
			0, "main",
			_UpdaterTest_IntervalCancellationProbesLease.Bind(State),
			"test://interval-cancellation", Request)

		AssertEqual(true, Updater_SetCheckInterval(
			0, Request, false,
			_UpdaterTest_RecordChannelNotice.Bind(State),
			_UpdaterTest_CountUnexpectedSettingsWrite.Bind(State),
			_UpdaterTest_AcceptMenuSchedule.Bind(State)),
			"a typed durable interval write must complete")
		AssertEqual(1, State.Writes,
			"the interval setting must persist exactly once")
		AssertEqual(1, State.Callbacks,
			"post-commit Stop must terminal the prior async owner")
		Assert(_Updater_AsyncTerminalIsCancelled(State.Terminal),
			"the stopped owner must receive typed cancellation")
		AssertEqual(1, State.LeasesDuringCallback,
			"the interval action lease must span cancellation callbacks")
		AssertEqual(false, State.ChannelResult,
			"a cancellation callback cannot start channel replacement mid-apply")
		AssertEqual(1, State.Writes,
			"the nested channel refusal must not reach its writer")
		AssertEqual(0, _UpdaterAsyncActionLeases.Count,
			"the successful interval action must release its lease after handoff")
		AssertEqual(1, State.MenuSchedules,
			"post-commit cancellation must still reach one menu handoff")
		AssertEqual(1, State.Notices,
			"the nested channel refusal must remain visible")
	} finally {
		UPDATER_CHECK_INTERVAL := SavedInterval
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: interval action lease spans post-commit cancellation (updater-channel-replacement-transaction)",
	_UpdaterTest_IntervalLeaseSpansPostcommitCancellation)

_UpdaterTest_ChannelWritePumpsRetiredTick(State, Mode, Args*) {
	State.TickResult := State.OldTick.Call()
	if (Mode == "throw")
		throw Error("deterministic channel persistence failure")
	return false
}

_UpdaterTest_RestoreChannelCadence(State, ScheduleFn, Args*) {
	global _UpdaterAsyncActionLeases
	global ConfigurationFile
	State.Recoveries += 1
	State.BoundaryDuringRecovery := _Updater_AsyncAdmissionBoundaryActive()
	State.ActionLeasesDuringRecovery := _UpdaterAsyncActionLeases.Count
	State.ConfigTerminalDuringRecovery := _ConfigWriteTerminalIsActive()
	CompetingConfig := _ConfigWriteLeaseTryAcquire(
		ConfigurationFile . ".precommit-recovery-sibling")
	State.ConfigWriterAdmittedDuringRecovery := CompetingConfig is Object
	if CompetingConfig is Object
		_ConfigWriteLeaseRelease(CompetingConfig)
	State.CompetingBoundary := _Updater_BeginAsyncAdmissionBoundary(
		"competing channel switch")
	return Updater_StartBackgroundChecks(ScheduleFn, false)
}

_UpdaterTest_FailedChannelWriteRestoresExactCadence() {
	global UPDATER_CHANNEL, UPDATER_CHECK_INTERVAL
	global UPDATER_REQUEST_ORIGIN_MANUAL
	global _UpdaterDownloadInProgress, _UpdaterAsyncRequests
	global _UpdaterBackgroundFn, _UpdaterBackgroundOwner
	global _UpdaterBackgroundOwnerCounter, _UpdaterAsyncActionLeases
	Saved := _UpdaterTest_SaveRequestState()
	SavedDownload := _UpdaterDownloadInProgress
	SavedInterval := UPDATER_CHECK_INTERVAL
	HadBackgroundFn := IsSet(_UpdaterBackgroundFn)
	if HadBackgroundFn
		SavedBackgroundFn := _UpdaterBackgroundFn
	HadBackgroundOwner := IsSet(_UpdaterBackgroundOwner)
	if HadBackgroundOwner
		SavedBackgroundOwner := _UpdaterBackgroundOwner
	SavedBackgroundCounter := _UpdaterBackgroundOwnerCounter
	SetChannelFn := _UpdaterTest_ResolveFunction("Updater_SetChannel")
	try {
		for Mode in ["false", "throw"] {
			try Updater_StopBackgroundChecks(false)
			_UpdaterTest_ResetRequestState()
			_UpdaterDownloadInProgress := false
			UPDATER_CHECK_INTERVAL := 60
			_UpdaterBackgroundFn := unset
			_UpdaterBackgroundOwner := 0
			State := { Calls: 0, Disarms: 0, InlineNext: false,
				Pending: [], InterleaveFn: 0, Notices: 0,
				Recoveries: 0, BoundaryDuringRecovery: true,
				ActionLeasesDuringRecovery: 0,
				ConfigTerminalDuringRecovery: false,
				ConfigWriterAdmittedDuringRecovery: true,
				CompetingBoundary: 0,
				TickResult: true, OldTick: 0 }
			ScheduleFn := _UpdaterTest_BackgroundSchedule.Bind(State)
			AssertEqual(true, Updater_StartBackgroundChecks(ScheduleFn, false),
				"the repro must begin with one live cadence owner")
			OldOwner := _UpdaterBackgroundOwner
			State.OldTick := State.Pending[1]
			Request := _Updater_NewRequestContext(
				UPDATER_REQUEST_ORIGIN_MANUAL, false)

			AssertEqual(false, SetChannelFn.Call(
				"dev", Request, false,
				_UpdaterTest_RecordChannelNotice.Bind(State),
				_UpdaterTest_ChannelWritePumpsRetiredTick.Bind(State, Mode),
				0, 0, 0,
				_UpdaterTest_RestoreChannelCadence.Bind(State, ScheduleFn)),
				"failed channel persistence must report failure")
			AssertEqual(false, State.TickResult,
				"the tick captured before persistence must already be retired")
			AssertEqual(false, IsObject(OldOwner.TimerFn),
				"pre-commit stop must break the old callback cycle")
			AssertEqual(1, State.Recoveries,
				"failed persistence must restore the displaced cadence exactly once")
			AssertEqual(false, State.BoundaryDuringRecovery,
				"cadence restoration must start only after exact boundary release")
			AssertEqual(1, State.ActionLeasesDuringRecovery,
				"boundary release must atomically hand recovery one exact action lease")
			AssertEqual(true, State.ConfigTerminalDuringRecovery,
				"write-failure recovery must retain the exact global config bundle")
			AssertEqual(false, State.ConfigWriterAdmittedDuringRecovery,
				"no sibling config writer may enter before retired cadence restoration")
			AssertEqual(0, State.CompetingBoundary,
				"a successor channel boundary cannot enter during exact recovery")
			Assert(IsObject(_UpdaterBackgroundOwner)
				and ObjPtr(_UpdaterBackgroundOwner) != ObjPtr(OldOwner)
				and _UpdaterBackgroundOwner.Active
				and _UpdaterBackgroundOwner.Armed,
				"recovery must publish one acknowledged successor cadence")
			AssertEqual(1, State.Pending.Length,
				"recovery must leave exactly one future timer callback")
			AssertEqual(0, _UpdaterAsyncRequests.Count,
				"a retired tick pumped by persistence must not dispatch HTTP")
			AssertEqual("main", UPDATER_CHANNEL,
				"failed persistence must not publish the requested channel")
			AssertEqual(0, _UpdaterAsyncActionLeases.Count,
				"completed recovery must release action admission")
			AssertEqual(false, _ConfigWriteTerminalIsActive(),
				"completed pre-commit recovery must release global config admission")
			AssertEqual(1, State.Notices,
				"the persistence failure must remain visible exactly once")
		}
	} finally {
		try Updater_StopBackgroundChecks(false)
		_UpdaterDownloadInProgress := SavedDownload
		UPDATER_CHECK_INTERVAL := SavedInterval
		_UpdaterBackgroundOwnerCounter := SavedBackgroundCounter
		if HadBackgroundFn
			_UpdaterBackgroundFn := SavedBackgroundFn
		else
			_UpdaterBackgroundFn := unset
		if HadBackgroundOwner
			_UpdaterBackgroundOwner := SavedBackgroundOwner
		else
			_UpdaterBackgroundOwner := unset
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: failed channel persistence restores the exact retired cadence (updater-channel-replacement-transaction)",
	_UpdaterTest_FailedChannelWriteRestoresExactCadence)

_UpdaterTest_BackgroundScheduleRejectsDisarm(State, TimerFn, DelayMs) {
	Result := _UpdaterTest_BackgroundSchedule(State, TimerFn, DelayMs)
	return DelayMs == 0 ? false : Result
}

_UpdaterTest_FailedCadenceRetirementPreventsPersistence() {
	global UPDATER_CHANNEL, UPDATER_CHECK_INTERVAL
	global UPDATER_REQUEST_ORIGIN_MANUAL, _UpdaterChannelEpoch
	global _UpdaterDownloadInProgress
	global _UpdaterBackgroundFn, _UpdaterBackgroundOwner
	global _UpdaterBackgroundOwnerCounter
	Saved := _UpdaterTest_SaveRequestState()
	SavedDownload := _UpdaterDownloadInProgress
	SavedInterval := UPDATER_CHECK_INTERVAL
	HadBackgroundFn := IsSet(_UpdaterBackgroundFn)
	if HadBackgroundFn
		SavedBackgroundFn := _UpdaterBackgroundFn
	HadBackgroundOwner := IsSet(_UpdaterBackgroundOwner)
	if HadBackgroundOwner
		SavedBackgroundOwner := _UpdaterBackgroundOwner
	SavedBackgroundCounter := _UpdaterBackgroundOwnerCounter
	try {
		_UpdaterTest_ResetRequestState()
		_UpdaterDownloadInProgress := false
		UPDATER_CHECK_INTERVAL := 60
		_UpdaterBackgroundFn := unset
		_UpdaterBackgroundOwner := 0
		State := { Calls: 0, Disarms: 0, InlineNext: false,
			Pending: [], InterleaveFn: 0, Notices: 0, Messages: [],
			Writes: 0, Recoveries: 0, BoundaryDuringRecovery: true,
			ActionLeasesDuringRecovery: 0 }
		ScheduleFn := _UpdaterTest_BackgroundScheduleRejectsDisarm.Bind(State)
		AssertEqual(true, Updater_StartBackgroundChecks(ScheduleFn, false),
			"the repro must begin with a live cadence")
		BeforeEpoch := _UpdaterChannelEpoch
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)

		AssertEqual(false, _UpdaterTest_ResolveFunction(
			"Updater_SetChannel").Call(
			"dev", Request, false,
			_UpdaterTest_RecordChannelNotice.Bind(State),
			_UpdaterTest_CountUnexpectedSettingsWrite.Bind(State),
			0, 0, 0,
			_UpdaterTest_RestoreChannelCadence.Bind(State, ScheduleFn)),
			"failed exact timer retirement must abort before persistence")
		AssertEqual(0, State.Writes,
			"a failed precondition must never reach the TOML writer")
		AssertEqual("main", UPDATER_CHANNEL,
			"failed cadence retirement must not publish channel state")
		AssertEqual(BeforeEpoch, _UpdaterChannelEpoch,
			"failed cadence retirement must not advance channel epoch")
		AssertEqual(1, State.Recoveries,
			"even a rejecting disarm must restore its displaced cadence owner")
		AssertEqual(1, State.Notices,
			"the precondition failure must have one visible terminal")
		AssertEqual(t("updater.settings_save_failed"), State.Messages[1],
			"a pre-write failure must not claim that the channel was saved")
		Assert(IsObject(_UpdaterBackgroundOwner)
			and _UpdaterBackgroundOwner.Active
			and _UpdaterBackgroundOwner.Armed,
			"recovery must acknowledge one replacement cadence")
	} finally {
		try Updater_StopBackgroundChecks(false)
		_UpdaterDownloadInProgress := SavedDownload
		UPDATER_CHECK_INTERVAL := SavedInterval
		_UpdaterBackgroundOwnerCounter := SavedBackgroundCounter
		if HadBackgroundFn
			_UpdaterBackgroundFn := SavedBackgroundFn
		else
			_UpdaterBackgroundFn := unset
		if HadBackgroundOwner
			_UpdaterBackgroundOwner := SavedBackgroundOwner
		else
			_UpdaterBackgroundOwner := unset
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: failed cadence retirement aborts before persistence (updater-channel-replacement-transaction)",
	_UpdaterTest_FailedCadenceRetirementPreventsPersistence)

_UpdaterTest_CaptureReplacementTerminal(State, Json, Request, Terminal := 0) {
	State.NewTerminals += 1
	State.NewTerminal := Terminal
}

_UpdaterTest_RegisterReplacementFromRetiredTerminal(State, Json, Request,
	Terminal := 0) {
	global UPDATER_REQUEST_ORIGIN_MANUAL
	State.OldTerminals += 1
	State.OldTerminal := Terminal
	State.NewRequest := _Updater_NewRequestContext(
		UPDATER_REQUEST_ORIGIN_MANUAL, false)
	State.NewOwner := _Updater_RegisterAsyncRequestOwner(
		_UpdaterTestChannelHttp(State.NewHttp), "main",
		_UpdaterTest_CaptureReplacementTerminal.Bind(State),
		"test://replacement", State.NewRequest)
}

_UpdaterTest_ChannelRegistrySwapPreservesReentrantReplacement() {
	global UPDATER_REQUEST_ORIGIN_MANUAL, _UpdaterAsyncRequests
	global _UpdaterActiveAsyncTerminalDeliveryCount
	if !_UpdaterTest_RequireChannelTransactionFunctions([
		"_Updater_SwapAsyncRequestsForBoundary",
		"_Updater_DeliverCancelledAsyncRequests"
	])
		return
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		State := {
			OldHttp: { Aborts: 0 },
			NewHttp: { Aborts: 0 },
			OldTerminals: 0,
			OldTerminal: 0,
			NewTerminals: 0,
			NewTerminal: 0,
			NewRequest: 0,
			NewOwner: 0
		}
		OldRequest := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)
		OldOwner := _Updater_RegisterAsyncRequestOwner(
			_UpdaterTestChannelHttp(State.OldHttp), "main",
			_UpdaterTest_RegisterReplacementFromRetiredTerminal.Bind(State),
			"test://retired", OldRequest)
		PreviousCritical := A_IsCritical
		Critical("On")
		try Pending := _Updater_SwapAsyncRequestsForBoundary(
			"channel switch", Map())
		finally Critical(PreviousCritical ? PreviousCritical : "Off")

		_Updater_DeliverCancelledAsyncRequests(Pending, "channel switch")

		AssertEqual(1, State.OldHttp.Aborts,
			"the retired registry must abort its old transport exactly once")
		AssertEqual(1, State.OldTerminals,
			"the retired registry must callback its old owner exactly once")
		Assert(_Updater_AsyncTerminalIsCancelled(State.OldTerminal),
			"the retired owner must receive typed cancellation")
		Assert(IsObject(State.NewOwner)
			and _Updater_AsyncRequestOwned(State.NewOwner),
			"callback reentrance must publish into the replacement Map")
		AssertEqual(1, _UpdaterAsyncRequests.Count,
			"retired-map delivery must preserve the one replacement owner")
		AssertEqual(0, State.NewTerminals,
			"old-owner cleanup must not terminal its reentrant replacement")
		AssertEqual(false, _Updater_AsyncRequestOwned(OldOwner),
			"the old owner must remain retired after callback reentrance")
		AssertEqual(0, _UpdaterActiveAsyncTerminalDeliveryCount,
			"retired-map delivery must balance terminal ownership after callback return")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: registry swap preserves reentrant replacement (updater-channel-replacement-transaction)",
	_UpdaterTest_ChannelRegistrySwapPreservesReentrantReplacement)

_UpdaterTest_RecordChannelReloadSchedule(State, Continuation, DelayMs) {
	State.ScheduleCount += 1
	if State.HasOwnProp("CriticalStates")
		State.CriticalStates.Push({ Phase: "schedule", Value: A_IsCritical })
	State.Scheduled.Push({ Continuation: Continuation, DelayMs: DelayMs })
	return true
}

_UpdaterTest_RejectChannelReloadSchedule(State, Continuation, DelayMs) {
	State.ScheduleCount += 1
	State.Scheduled.Push({ Continuation: Continuation, DelayMs: DelayMs })
	return false
}

_UpdaterTest_RunChannelReload(State) {
	State.ReloadCount += 1
	if State.HasOwnProp("CriticalStates")
		State.CriticalStates.Push({ Phase: "reload", Value: A_IsCritical })
	return State.ReloadResult
}

_UpdaterTest_RecordSuccessfulChannelWrite(State, Args*) {
	State.Writes += 1
	State.CriticalStates.Push({ Phase: "writer", Value: A_IsCritical })
	return 1
}

_UpdaterTest_RecordChannelReloadFailure(State, Args*) {
	State.FailureCount += 1
	return true
}

_UpdaterTest_RecordChannelReloadRecovery(State, Args*) {
	State.RecoverCount += 1
	return true
}

_UpdaterTest_CaptureNonLeasedTerminal(State, Json, Request, Terminal := 0) {
	State.TerminalCount += 1
	State.DeliveryActiveDuringCallback := _Updater_AsyncTerminalDeliveryActive()
	State.FirstContinuationResult := State.Scheduled[1].Continuation.Call()
	State.ReloadCountDuringCallback := State.ReloadCount
}

_UpdaterTest_NewChannelReloadProbe() {
	return {
		ScheduleCount: 0,
		Scheduled: [],
		ReloadCount: 0,
		ReloadResult: true,
		FailureCount: 0,
		RecoverCount: 0,
		TerminalCount: 0,
		DeliveryActiveDuringCallback: false,
		FirstContinuationResult: true,
		ReloadCountDuringCallback: -1
	}
}

_UpdaterTest_ChannelActionDefusesInheritedCritical() {
	global UPDATER_REQUEST_ORIGIN_MANUAL, _UpdaterDownloadInProgress
	global _UpdaterBackgroundFn, _UpdaterBackgroundOwner
	Saved := _UpdaterTest_SaveRequestState()
	SavedDownload := _UpdaterDownloadInProgress
	HadBackgroundFn := IsSet(_UpdaterBackgroundFn)
	if HadBackgroundFn
		SavedBackgroundFn := _UpdaterBackgroundFn
	HadBackgroundOwner := IsSet(_UpdaterBackgroundOwner)
	if HadBackgroundOwner
		SavedBackgroundOwner := _UpdaterBackgroundOwner
	try {
		_UpdaterTest_ResetRequestState()
		_UpdaterDownloadInProgress := false
		_UpdaterBackgroundFn := unset
		_UpdaterBackgroundOwner := 0
		State := _UpdaterTest_NewChannelReloadProbe()
		State.Writes := 0
		State.Notices := 0
		State.CriticalStates := []
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)
		PreviousCritical := Critical("On")
		try {
			AssertTrue(Updater_SetChannel("dev", Request, false,
				_UpdaterTest_RecordChannelNotice.Bind(State),
				_UpdaterTest_RecordSuccessfulChannelWrite.Bind(State),
				_UpdaterTest_RunChannelReload.Bind(State),
				_UpdaterTest_RecordChannelReloadSchedule.Bind(State),
				_UpdaterTest_RecordChannelReloadFailure.Bind(State),
				_UpdaterTest_RecordChannelReloadRecovery.Bind(State)))
			AssertTrue(A_IsCritical,
				"Updater_SetChannel must restore its caller's Critical state")
		} finally Critical(PreviousCritical)
		AssertEqual(1, State.Writes)
		AssertEqual(1, State.ScheduleCount)
		for Sample in State.CriticalStates
			AssertEqual(0, Sample.Value,
				Sample.Phase . " must remain interruptible during channel change")
		AssertTrue(State.Scheduled[1].Continuation.Call(),
			"the accepted fake Reload must retire the retained transition bundle")
		AssertEqual(1, State.ReloadCount)
		LastCriticalSample := State.CriticalStates[
			State.CriticalStates.Length]
		AssertEqual("reload", LastCriticalSample.Phase)
		AssertEqual(0, LastCriticalSample.Value,
			"the deferred Reload callback must not recover the original caller's Critical state")
	} finally {
		_UpdaterDownloadInProgress := SavedDownload
		if HadBackgroundFn
			_UpdaterBackgroundFn := SavedBackgroundFn
		else
			_UpdaterBackgroundFn := unset
		if HadBackgroundOwner
			_UpdaterBackgroundOwner := SavedBackgroundOwner
		else
			_UpdaterBackgroundOwner := unset
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: channel action never inherits caller Critical "
	. "(updater-channel-inherited-critical)",
	_UpdaterTest_ChannelActionDefusesInheritedCritical)

_UpdaterTest_NonLeasedTerminalBlocksDeferredReload() {
	global UPDATER_REQUEST_ORIGIN_MANUAL
	global _UpdaterAsyncRequests, _UpdaterActiveSendLeaseCount
	if !_UpdaterTest_RequireChannelTransactionFunctions([
		"_Updater_BeginAsyncAdmissionBoundary",
		"_Updater_EndAsyncAdmissionBoundary",
		"_Updater_TakeAsyncRequest",
		"_Updater_InvokeAsyncOnJson",
		"_Updater_BeginDeferredChannelReload",
		"_Updater_ChannelReloadQuiescent",
		"_Updater_ChannelReloadTransitionActive"
	])
		return
	Saved := _UpdaterTest_SaveRequestState()
	BoundaryOwner := 0
	try {
		_UpdaterTest_ResetRequestState()
		State := _UpdaterTest_NewChannelReloadProbe()
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)
		Owner := _Updater_RegisterAsyncRequestOwner(
			0, "main", _UpdaterTest_CaptureNonLeasedTerminal.Bind(State),
			"test://nonleased-terminal", Request)
		BoundaryOwner := _Updater_BeginAsyncAdmissionBoundary("channel switch")
		Assert(IsObject(BoundaryOwner),
			"the test must own one exact channel boundary")
		ConfigBundle := _UpdaterTest_AcquireChannelConfigBundle()
		AssertEqual(true, _Updater_TakeAsyncRequest(Owner.Id, Owner.Record),
			"completion must exact-take the non-leased registry owner")
		AssertEqual(0, _UpdaterAsyncRequests.Count,
			"the exact take must publish an empty registry")
		AssertEqual(0, _UpdaterActiveSendLeaseCount,
			"this repro deliberately has no COM lease backstop")
		AssertEqual(false, _Updater_ChannelReloadQuiescent(),
			"a claimed non-leased terminal keeps an empty registry non-quiescent")

		Transition := _Updater_BeginDeferredChannelReload(
			BoundaryOwner,
			_UpdaterTest_RunChannelReload.Bind(State),
			_UpdaterTest_RecordChannelReloadSchedule.Bind(State),
			_UpdaterTest_RecordChannelReloadFailure.Bind(State),
			_UpdaterTest_RecordChannelReloadRecovery.Bind(State),
			A_TickCount, 10000, 0, ConfigBundle)
		Assert(IsObject(Transition),
			"channel replacement must publish one exact deferred Reload owner")
		AssertEqual(1, State.ScheduleCount,
			"deferred Reload must start with one one-shot continuation")

		AssertEqual(true, _Updater_InvokeAsyncOnJson(
			Owner.Record["on_json"], "{}", Request, 0,
			"non-leased terminal test", Owner.Record),
			"the owned terminal callback must return through the shared dispatcher")
		AssertEqual(1, State.TerminalCount,
			"the exact completion must callback once")
		AssertEqual(true, State.DeliveryActiveDuringCallback,
			"terminal ownership must remain published on the callback stack")
		AssertEqual(false, State.FirstContinuationResult,
			"a continuation pumped by on_json must refuse Reload")
		AssertEqual(0, State.ReloadCountDuringCallback,
			"Reload must remain impossible until the callback returns")
		AssertEqual(0, State.ReloadCount,
			"terminal return may only make a timer eligible, never Reload inline")
		AssertEqual(true, _Updater_ChannelReloadQuiescent(),
			"quiescence begins after the terminal dispatcher returns")
		AssertEqual(2, State.ScheduleCount,
			"the consumed non-quiescent arm must be replaced exactly once")
		AssertEqual(false, State.Scheduled[1].Continuation.Call(),
			"the consumed first continuation must be stale")
		AssertEqual(true, State.Scheduled[2].Continuation.Call(),
			"the current continuation must perform the quiescent Reload")
		AssertEqual(1, State.ReloadCount,
			"the exact transition must Reload once")
		AssertEqual(false, _Updater_ChannelReloadTransitionActive(),
			"successful Reload must retire the exact transition")
		AssertEqual(false, _Updater_AsyncAdmissionBoundaryActive(),
			"a returning test Reload must release its exact admission boundary")
		BoundaryOwner := 0
	} finally {
		if IsObject(BoundaryOwner)
			_Updater_EndAsyncAdmissionBoundary(BoundaryOwner)
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: non-leased terminal blocks Reload until callback return (updater-channel-replacement-transaction)",
	_UpdaterTest_NonLeasedTerminalBlocksDeferredReload)

_UpdaterTest_TerminalClaimsBalanceIndependently() {
	global _UpdaterActiveAsyncTerminalDeliveryCount
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		First := Map("terminal_claimed", false)
		Second := Map("terminal_claimed", false)
		AssertEqual(true, _Updater_ClaimAsyncTerminalRecord(First),
			"the first exact terminal must claim one delivery slot")
		AssertEqual(true, _Updater_ClaimAsyncTerminalRecord(Second),
			"the second exact terminal must claim an independent delivery slot")
		AssertEqual(2, _UpdaterActiveAsyncTerminalDeliveryCount,
			"two simultaneous terminal owners must publish count two")
		AssertEqual(false, _Updater_ChannelReloadQuiescent(),
			"two claimed terminals keep channel Reload non-quiescent")

		AssertEqual(true, _Updater_EndAsyncTerminalRecord(First),
			"the first exact owner must release its own terminal claim")
		AssertEqual(1, _UpdaterActiveAsyncTerminalDeliveryCount,
			"ending one terminal must preserve the sibling's live claim")
		AssertEqual(false, _Updater_ChannelReloadQuiescent(),
			"one remaining terminal must still block channel Reload")

		AssertEqual(true, _Updater_EndAsyncTerminalRecord(Second),
			"the sibling owner must release its own terminal claim")
		AssertEqual(0, _UpdaterActiveAsyncTerminalDeliveryCount,
			"all terminal claims must balance exactly to zero")
		AssertEqual(true, _Updater_ChannelReloadQuiescent(),
			"terminal quiescence begins only after both exact owners return")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: simultaneous terminal claims balance independently (updater-channel-replacement-transaction)",
	_UpdaterTest_TerminalClaimsBalanceIndependently)

_UpdaterTest_DeferredReloadTimeoutRecoversExactlyOnce() {
	global _UpdaterActiveAsyncTerminalDeliveryCount
	if !_UpdaterTest_RequireChannelTransactionFunctions([
		"_Updater_BeginAsyncAdmissionBoundary",
		"_Updater_EndAsyncAdmissionBoundary",
		"_Updater_BeginDeferredChannelReload",
		"_Updater_RunDeferredChannelReload",
		"_Updater_ChannelReloadTransitionActive"
	])
		return
	Saved := _UpdaterTest_SaveRequestState()
	BoundaryOwner := 0
	try {
		_UpdaterTest_ResetRequestState()
		State := _UpdaterTest_NewChannelReloadProbe()
		BoundaryOwner := _Updater_BeginAsyncAdmissionBoundary("channel switch")
		ConfigBundle := _UpdaterTest_AcquireChannelConfigBundle()
		Transition := _Updater_BeginDeferredChannelReload(
			BoundaryOwner,
			_UpdaterTest_RunChannelReload.Bind(State),
			_UpdaterTest_RecordChannelReloadSchedule.Bind(State),
			_UpdaterTest_RecordChannelReloadFailure.Bind(State),
			_UpdaterTest_RecordChannelReloadRecovery.Bind(State),
			0xFFFFFFF0, 40, 0, ConfigBundle)
		_UpdaterActiveAsyncTerminalDeliveryCount := 1

		AssertEqual(false, _Updater_RunDeferredChannelReload(
			Transition, Transition.ArmEpoch, 0x00000020),
			"wrap-safe timeout must abandon Reload over a live terminal")
		AssertEqual(0, State.ReloadCount,
			"timeout must never force Reload over non-quiescent work")
		AssertEqual(1, State.FailureCount,
			"timeout must surface one failure terminal")
		AssertEqual(1, State.RecoverCount,
			"timeout must recover the committed channel session once")
		AssertEqual(false, _Updater_ChannelReloadTransitionActive(),
			"timeout must retire the exact deferred owner")
		AssertEqual(false, _Updater_AsyncAdmissionBoundaryActive(),
			"timeout recovery must reopen channel admission")
		BoundaryOwner := 0
		AssertEqual(false, _Updater_RunDeferredChannelReload(Transition),
			"the timed-out continuation must be permanently stale")
		AssertEqual(1, State.FailureCount,
			"stale timeout replay must not duplicate failure output")
		AssertEqual(1, State.RecoverCount,
			"stale timeout replay must not duplicate recovery")
	} finally {
		_UpdaterActiveAsyncTerminalDeliveryCount := 0
		if IsObject(BoundaryOwner)
			_Updater_EndAsyncAdmissionBoundary(BoundaryOwner)
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: deferred Reload timeout is wrap-safe and exact-once (updater-channel-replacement-transaction)",
	_UpdaterTest_DeferredReloadTimeoutRecoversExactlyOnce)

_UpdaterTest_DeferredReloadArmFailureOwnsOneRecovery() {
	if !_UpdaterTest_RequireChannelTransactionFunctions([
		"_Updater_BeginAsyncAdmissionBoundary",
		"_Updater_EndAsyncAdmissionBoundary",
		"_Updater_BeginDeferredChannelReload",
		"_Updater_ChannelReloadTransitionActive"
	])
		return
	Saved := _UpdaterTest_SaveRequestState()
	BoundaryOwner := 0
	try {
		_UpdaterTest_ResetRequestState()
		State := _UpdaterTest_NewChannelReloadProbe()
		BoundaryOwner := _Updater_BeginAsyncAdmissionBoundary("channel switch")
		ConfigBundle := _UpdaterTest_AcquireChannelConfigBundle()
		Transition := _Updater_BeginDeferredChannelReload(
			BoundaryOwner,
			_UpdaterTest_RunChannelReload.Bind(State),
			_UpdaterTest_RejectChannelReloadSchedule.Bind(State),
			_UpdaterTest_RecordChannelReloadFailure.Bind(State),
			_UpdaterTest_RecordChannelReloadRecovery.Bind(State),
			A_TickCount, 10000, 0, ConfigBundle)
		AssertEqual(0, Transition,
			"a false scheduler result must refuse deferred Reload ownership")
		AssertEqual(1, State.ScheduleCount,
			"the failed exact arm must make one scheduler attempt")
		AssertEqual(1, State.FailureCount,
			"arm failure must own one visible failure terminal")
		AssertEqual(1, State.RecoverCount,
			"arm failure must recover the committed channel once")
		AssertEqual(false, _Updater_ChannelReloadTransitionActive(),
			"arm failure must retire its exact transition")
		AssertEqual(false, _Updater_AsyncAdmissionBoundaryActive(),
			"arm failure must release its exact channel boundary")
		BoundaryOwner := 0
		AssertEqual(false, State.Scheduled[1].Continuation.Call(),
			"a callback retained by a rejecting scheduler must be stale")
		AssertEqual(1, State.FailureCount,
			"stale rejected-arm callback must not duplicate failure")
		AssertEqual(1, State.RecoverCount,
			"stale rejected-arm callback must not duplicate recovery")
	} finally {
		if IsObject(BoundaryOwner)
			_Updater_EndAsyncAdmissionBoundary(BoundaryOwner)
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: deferred Reload arm failure owns one recovery (updater-channel-replacement-transaction)",
	_UpdaterTest_DeferredReloadArmFailureOwnsOneRecovery)

_UpdaterTest_RecordReloadEvent(State, Kind, Args*) {
	State.Events.Push(Kind)
	if (Kind == "failure")
		State.FailureCount += 1
	else if (Kind == "recover")
		State.RecoverCount += 1
	else if (Kind == "notice")
		State.Notices += 1
	return true
}

_UpdaterTest_SetterArmFailureHasOneOwnedTerminal() {
	global UPDATER_CHANNEL, UPDATER_REQUEST_ORIGIN_MANUAL
	global _UpdaterDownloadInProgress, _UpdaterFetchCache
	global UPDATER_LATEST_RELEASE, _UpdaterAsyncActionLeases
	Saved := _UpdaterTest_SaveRequestState()
	SavedDownload := _UpdaterDownloadInProgress
	SavedFetchCache := _UpdaterFetchCache
	HadLatest := IsSet(UPDATER_LATEST_RELEASE)
	if HadLatest
		SavedLatest := UPDATER_LATEST_RELEASE
	try {
		_UpdaterTest_ResetRequestState()
		_UpdaterDownloadInProgress := false
		State := _UpdaterTest_NewChannelReloadProbe()
		State.Writes := 0
		State.Notices := 0
		State.Events := []
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)
		AssertEqual(false, _UpdaterTest_ResolveFunction(
			"Updater_SetChannel").Call(
			"dev", Request, false,
			_UpdaterTest_RecordReloadEvent.Bind(State, "notice"),
			_UpdaterTest_CountUnexpectedSettingsWrite.Bind(State),
			_UpdaterTest_RunChannelReload.Bind(State),
			_UpdaterTest_RejectChannelReloadSchedule.Bind(State),
			_UpdaterTest_RecordReloadEvent.Bind(State, "failure"),
			_UpdaterTest_RecordReloadEvent.Bind(State, "recover")),
			"a rejecting initial reload arm must fail the outer setter")
		AssertEqual(1, State.Writes,
			"the channel must reach its durable commit exactly once")
		AssertEqual(1, State.FailureCount,
			"initial arm failure must own one failure callback")
		AssertEqual(1, State.Notices,
			"initial arm failure must use the injected visible terminal once")
		AssertEqual(1, State.RecoverCount,
			"initial arm failure must recover once")
		AssertEqual(3, State.Events.Length,
			"outer Setter must not duplicate the helper-owned terminal")
		AssertEqual("failure", State.Events[1],
			"failure callback must precede visible output")
		AssertEqual("notice", State.Events[2],
			"the injected notice must be emitted by the owned failure path")
		AssertEqual("recover", State.Events[3],
			"recovery must follow the visible failure terminal")
		AssertEqual("dev", UPDATER_CHANNEL,
			"arm failure happens after the explicit durable commit point")
		AssertEqual(false, _Updater_AsyncAdmissionBoundaryActive(),
			"helper-owned recovery must consume the exact boundary")
		AssertEqual(0, _UpdaterAsyncActionLeases.Count,
			"synchronous injected recovery must release its exact lease")
	} finally {
		_UpdaterDownloadInProgress := SavedDownload
		_UpdaterFetchCache := SavedFetchCache
		if HadLatest
			UPDATER_LATEST_RELEASE := SavedLatest
		else
			UPDATER_LATEST_RELEASE := unset
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: Setter initial arm failure has one owned terminal (updater-channel-replacement-transaction)",
	_UpdaterTest_SetterArmFailureHasOneOwnedTerminal)

_UpdaterTest_ActiveSendLeaseBlocksDeferredReload() {
	global _UpdaterActiveSendLeaseCount
	Saved := _UpdaterTest_SaveRequestState()
	BoundaryOwner := 0
	try {
		_UpdaterTest_ResetRequestState()
		State := _UpdaterTest_NewChannelReloadProbe()
		BoundaryOwner := _Updater_BeginAsyncAdmissionBoundary("channel switch")
		ConfigBundle := _UpdaterTest_AcquireChannelConfigBundle()
		_UpdaterActiveSendLeaseCount := 1
		Transition := _Updater_BeginDeferredChannelReload(
			BoundaryOwner,
			_UpdaterTest_RunChannelReload.Bind(State),
			_UpdaterTest_RecordChannelReloadSchedule.Bind(State),
			_UpdaterTest_RecordChannelReloadFailure.Bind(State),
			_UpdaterTest_RecordChannelReloadRecovery.Bind(State),
			A_TickCount, 10000, 0, ConfigBundle)
		AssertEqual(false, State.Scheduled[1].Continuation.Call(),
			"an empty registry with one active COM lease must not Reload")
		AssertEqual(0, State.ReloadCount,
			"Reload must remain blocked until the yielding COM frame returns")
		AssertEqual(2, State.ScheduleCount,
			"the consumed lease-blocked arm must be replaced exactly once")
		_UpdaterActiveSendLeaseCount := 0
		AssertEqual(true, State.Scheduled[2].Continuation.Call(),
			"the current continuation may Reload after lease release")
		AssertEqual(1, State.ReloadCount,
			"lease quiescence must hand off exactly one Reload")
		AssertEqual(false, _Updater_ChannelReloadTransitionActive(),
			"successful lease-gated Reload must retire its transition")
		AssertEqual(false, _Updater_AsyncAdmissionBoundaryActive(),
			"successful lease-gated Reload must release admission")
		BoundaryOwner := 0
	} finally {
		_UpdaterActiveSendLeaseCount := 0
		if IsObject(BoundaryOwner)
			_Updater_EndAsyncAdmissionBoundary(BoundaryOwner)
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: active COM lease blocks deferred Reload (updater-channel-replacement-transaction)",
	_UpdaterTest_ActiveSendLeaseBlocksDeferredReload)

_UpdaterTest_ThrowChannelReload(State) {
	State.ReloadCount += 1
	throw Error("deterministic Reload failure")
}

_UpdaterTest_FailChannelRecovery(State, Mode, Args*) {
	State.RecoverCount += 1
	if (Mode == "throw")
		throw Error("deterministic recovery failure")
	return false
}

_UpdaterTest_ReloadAndRecoveryFailuresAreExact() {
	global _UpdaterAsyncActionLeases
	Saved := _UpdaterTest_SaveRequestState()
	try {
		for ReloadMode in ["false", "throw"] {
			_UpdaterTest_ResetRequestState()
			State := _UpdaterTest_NewChannelReloadProbe()
			State.ReloadResult := false
			BoundaryOwner := _Updater_BeginAsyncAdmissionBoundary("channel switch")
			ConfigBundle := _UpdaterTest_AcquireChannelConfigBundle()
			ReloadFn := ReloadMode == "throw"
				? _UpdaterTest_ThrowChannelReload.Bind(State)
				: _UpdaterTest_RunChannelReload.Bind(State)
			Transition := _Updater_BeginDeferredChannelReload(
				BoundaryOwner, ReloadFn,
				_UpdaterTest_RecordChannelReloadSchedule.Bind(State),
				_UpdaterTest_RecordChannelReloadFailure.Bind(State),
				_UpdaterTest_RecordChannelReloadRecovery.Bind(State),
				A_TickCount, 10000, 0, ConfigBundle)
			AssertEqual(false, State.Scheduled[1].Continuation.Call(),
				ReloadMode . " Reload failure must return a typed failure")
			AssertEqual(1, State.ReloadCount,
				ReloadMode . " Reload effect must run exactly once")
			AssertEqual(1, State.FailureCount,
				ReloadMode . " Reload failure must surface exactly once")
			AssertEqual(1, State.RecoverCount,
				ReloadMode . " Reload failure must recover exactly once")
			AssertEqual(true, Transition.RecoveryOwned,
				ReloadMode . " failure must record typed recovery ownership")
			AssertEqual(false, _Updater_AsyncAdmissionBoundaryActive(),
				ReloadMode . " failure recovery must consume the boundary")
			AssertEqual(0, _UpdaterAsyncActionLeases.Count,
				ReloadMode . " injected recovery must release its exact lease")
			AssertEqual(false, State.Scheduled[1].Continuation.Call(),
				ReloadMode . " consumed continuation must stay stale")
			AssertEqual(1, State.FailureCount,
				ReloadMode . " stale replay must not duplicate output")
		}

		for RecoveryMode in ["false", "throw"] {
			_UpdaterTest_ResetRequestState()
			State := _UpdaterTest_NewChannelReloadProbe()
			State.ReloadResult := false
			BoundaryOwner := _Updater_BeginAsyncAdmissionBoundary("channel switch")
			ConfigBundle := _UpdaterTest_AcquireChannelConfigBundle()
			Transition := _Updater_BeginDeferredChannelReload(
				BoundaryOwner,
				_UpdaterTest_RunChannelReload.Bind(State),
				_UpdaterTest_RecordChannelReloadSchedule.Bind(State),
				_UpdaterTest_RecordChannelReloadFailure.Bind(State),
				_UpdaterTest_FailChannelRecovery.Bind(State, RecoveryMode),
				A_TickCount, 10000, 0, ConfigBundle)
			AssertEqual(false, State.Scheduled[1].Continuation.Call(),
				RecoveryMode . " recovery failure must remain contained")
			AssertEqual(1, State.FailureCount,
				RecoveryMode . " recovery failure must not duplicate the Reload terminal")
			AssertEqual(1, State.RecoverCount,
				RecoveryMode . " recovery seam must execute exactly once")
			AssertEqual(false, Transition.RecoveryOwned,
				RecoveryMode . " recovery must not be recorded as owned")
			AssertEqual(false, _Updater_AsyncAdmissionBoundaryActive(),
				RecoveryMode . " failed recovery must not leave a stale boundary")
			AssertEqual(0, _UpdaterAsyncActionLeases.Count,
				RecoveryMode . " failed recovery must release its exact lease")
		}
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: Reload and recovery false/throw paths are exact (updater-channel-replacement-transaction)",
	_UpdaterTest_ReloadAndRecoveryFailuresAreExact)

_UpdaterTest_RecoveryEffect(State, Field, Mode, Args*) {
	State[Field] += 1
	if (Mode == "throw")
		throw Error("deterministic " . Field . " failure")
	return Mode == "true"
}

_UpdaterTest_ProbeRecoveryRebuildOwnership(State, Args*) {
	global _UpdaterAsyncActionLeases
	State["Rebuilds"] += 1
	State["LeasesDuringRebuild"] := _UpdaterAsyncActionLeases.Count
	CompetingBoundary := _Updater_BeginAsyncAdmissionBoundary(
		"competing channel during menu rebuild")
	State["CompetingBoundaryAdmitted"] := IsObject(CompetingBoundary)
	if IsObject(CompetingBoundary)
		_Updater_EndAsyncAdmissionBoundary(CompetingBoundary)
	return true
}

_UpdaterTest_InlineRecoverySchedule(State, Mode, Continuation, DelayMs) {
	State["Schedules"] += 1
	if (Mode == "throw")
		throw Error("deterministic recovery scheduler failure")
	if (Mode == "false")
		return false
	State["CallbackResult"] := Continuation.Call()
	return true
}

_UpdaterTest_DefaultRecoveryTypesEveryEffect() {
	global _UpdaterAsyncActionLeases
	Saved := _UpdaterTest_SaveRequestState()
	try {
		for RecoverySpec in [
			{ Start: "false", Schedule: "false", Rebuild: "true" },
			{ Start: "throw", Schedule: "false", Rebuild: "true" },
			{ Start: "true", Schedule: "false", Rebuild: "true" },
			{ Start: "true", Schedule: "throw", Rebuild: "true" },
			{ Start: "true", Schedule: "true", Rebuild: "false" },
			{ Start: "true", Schedule: "true", Rebuild: "throw" },
			{ Start: "true", Schedule: "true", Rebuild: "true" }
		] {
			_UpdaterTest_ResetRequestState()
			State := Map("Starts", 0, "Schedules", 0, "Rebuilds", 0,
				"CallbackResult", false)
			Result := _Updater_RecoverCommittedChannelTransition(
				"deterministic recovery", 0,
				_UpdaterTest_InlineRecoverySchedule.Bind(
					State, RecoverySpec.Schedule),
				_UpdaterTest_RecoveryEffect.Bind(
					State, "Starts", RecoverySpec.Start),
				0,
				_UpdaterTest_RecoveryEffect.Bind(
					State, "Rebuilds", RecoverySpec.Rebuild))
			Expected := RecoverySpec.Start == "true"
				and RecoverySpec.Schedule == "true"
				and RecoverySpec.Rebuild == "true"
			AssertEqual(Expected, Result,
				"recovery must type Start, scheduler and actual menu effect")
			AssertEqual(1, State["Starts"],
				"recovery must attempt cadence startup exactly once")
			AssertEqual(1, State["Schedules"],
				"recovery must attempt menu scheduling exactly once")
			AssertEqual(RecoverySpec.Schedule == "true" ? 1 : 0,
				State["Rebuilds"],
				"only an acknowledged inline schedule may run menu rebuild")
			AssertEqual(0, _UpdaterAsyncActionLeases.Count,
				"every synchronous recovery terminal must release action ownership")
		}

		_UpdaterTest_ResetRequestState()
		ScheduleState := _UpdaterTest_NewChannelReloadProbe()
		EffectState := Map("Starts", 0, "Rebuilds", 0,
			"LeasesDuringRebuild", -1,
			"CompetingBoundaryAdmitted", false)
		AssertEqual(true, _Updater_RecoverCommittedChannelTransition(
			"future menu recovery", 0,
			_UpdaterTest_RecordChannelReloadSchedule.Bind(ScheduleState),
			_UpdaterTest_RecoveryEffect.Bind(
				EffectState, "Starts", "true"),
			0,
			_UpdaterTest_ProbeRecoveryRebuildOwnership.Bind(EffectState)),
			"an acknowledged future menu callback must retain recovery ownership")
		AssertEqual(1, _UpdaterAsyncActionLeases.Count,
			"future menu recovery must keep its exact action lease")
		AssertEqual(0, _Updater_BeginAsyncAdmissionBoundary("successor channel"),
			"channel replacement must remain closed until the actual menu effect")
		AssertEqual(true, ScheduleState.Scheduled[1].Continuation.Call(),
			"the retained continuation must execute the typed menu effect")
		AssertEqual(1, EffectState["Rebuilds"],
			"the future continuation must rebuild once")
		AssertEqual(1, EffectState["LeasesDuringRebuild"],
			"the exact recovery lease must stay live on the menu effect stack")
		AssertEqual(false, EffectState["CompetingBoundaryAdmitted"],
			"menu rebuild must refuse a competing channel boundary until it returns")
		AssertEqual(0, _UpdaterAsyncActionLeases.Count,
			"actual menu completion must release recovery admission")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: default recovery types cadence, scheduler and menu effect (updater-channel-replacement-transaction)",
	_UpdaterTest_DefaultRecoveryTypesEveryEffect)

_UpdaterTest_StaleTimedOutRecoveryCannotRetireSuccessor() {
	global _UpdaterActiveAsyncTerminalDeliveryCount
	Saved := _UpdaterTest_SaveRequestState()
	BoundaryTwo := 0
	try {
		_UpdaterTest_ResetRequestState()
		StateOne := _UpdaterTest_NewChannelReloadProbe()
		BoundaryOne := _Updater_BeginAsyncAdmissionBoundary("channel switch one")
		ConfigBundleOne := _UpdaterTest_AcquireChannelConfigBundle()
		TransitionOne := _Updater_BeginDeferredChannelReload(
			BoundaryOne,
			_UpdaterTest_RunChannelReload.Bind(StateOne),
			_UpdaterTest_RecordChannelReloadSchedule.Bind(StateOne),
			_UpdaterTest_RecordChannelReloadFailure.Bind(StateOne),
			_UpdaterTest_RecordChannelReloadRecovery.Bind(StateOne),
			100, 10, 0, ConfigBundleOne)
		_UpdaterActiveAsyncTerminalDeliveryCount := 1
		AssertEqual(false, _Updater_RunDeferredChannelReload(
			TransitionOne, TransitionOne.ArmEpoch, 111),
			"the first exact transition must time out")
		_UpdaterActiveAsyncTerminalDeliveryCount := 0

		StateTwo := _UpdaterTest_NewChannelReloadProbe()
		BoundaryTwo := _Updater_BeginAsyncAdmissionBoundary("channel switch two")
		Assert(IsObject(BoundaryTwo),
			"timeout recovery must permit one exact successor boundary")
		ConfigBundleTwo := _UpdaterTest_AcquireChannelConfigBundle()
		TransitionTwo := _Updater_BeginDeferredChannelReload(
			BoundaryTwo,
			_UpdaterTest_RunChannelReload.Bind(StateTwo),
			_UpdaterTest_RecordChannelReloadSchedule.Bind(StateTwo),
			_UpdaterTest_RecordChannelReloadFailure.Bind(StateTwo),
			_UpdaterTest_RecordChannelReloadRecovery.Bind(StateTwo),
			A_TickCount, 10000, 0, ConfigBundleTwo)
		AssertEqual(false, StateOne.Scheduled[1].Continuation.Call(),
			"the retained timeout callback must stay stale beside a successor")
		AssertEqual(true, _Updater_ChannelReloadTransitionActive(),
			"stale predecessor replay must not retire the live successor")
		AssertEqual(0, StateTwo.ReloadCount,
			"stale predecessor replay must not run successor Reload")
		AssertEqual(true, StateTwo.Scheduled[1].Continuation.Call(),
			"the successor's exact continuation must remain runnable")
		AssertEqual(1, StateTwo.ReloadCount,
			"the successor must Reload exactly once")
		BoundaryTwo := 0
	} finally {
		_UpdaterActiveAsyncTerminalDeliveryCount := 0
		if IsObject(BoundaryTwo)
			_Updater_EndAsyncAdmissionBoundary(BoundaryTwo)
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: stale timed-out continuation cannot retire successor (updater-channel-replacement-transaction)",
	_UpdaterTest_StaleTimedOutRecoveryCannotRetireSuccessor)

_UpdaterTest_ChannelEpochRejectsABA() {
	global UPDATER_REQUEST_ORIGIN_MANUAL, UPDATER_REQUEST_POLICY_ALLOW
	global UPDATER_REQUEST_POLICY_DROP
	global _UpdaterChannelEpoch, UPDATER_CHANNEL
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		NewRequest := _UpdaterTest_ResolveFunction("_Updater_NewRequestContext")
		RequestA := NewRequest.Call(
			UPDATER_REQUEST_ORIGIN_MANUAL, false, "main")
		CapturedEpoch := RequestA.ChannelEpoch
		AssertEqual(_UpdaterChannelEpoch, CapturedEpoch,
			"a new request must capture the current monotone channel epoch")
		AssertEqual(UPDATER_REQUEST_POLICY_ALLOW,
			_Updater_RequestPolicy(RequestA, false),
			"fresh same-epoch work must remain publishable before a channel transition")
		UPDATER_CHANNEL := "dev"
		_UpdaterChannelEpoch += 1
		UPDATER_CHANNEL := "main"
		_UpdaterChannelEpoch += 1
		Assert(_UpdaterChannelEpoch > CapturedEpoch,
			"main-dev-main must advance beyond the request's captured epoch")
		AssertEqual("main", RequestA.Channel,
			"the stale request and current state deliberately share a channel String")
		AssertEqual(UPDATER_REQUEST_POLICY_DROP,
			_Updater_RequestPolicy(RequestA, false),
			"main-dev-main must still reject stale work by monotone channel epoch")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: channel epoch rejects ABA publication (updater-channel-replacement-transaction)",
	_UpdaterTest_ChannelEpochRejectsABA)



; ====================================
; ===== AHK-31 operation leasing =====
; ====================================

_UpdaterTest_OperationLeaseActiveOrFalse() {
	try return _Updater_AsyncSendLeaseActive()
	catch {
		return false
	}
}

class _UpdaterTestOperationLeaseHttp {
	__New(State, SendInterleave := 0, WaitInterleave := 0,
		ThrowOnAbort := false) {
		this.State := State
		this.SendInterleave := SendInterleave
		this.WaitInterleave := WaitInterleave
		this.ThrowOnAbort := ThrowOnAbort
		this.Status := 200
		this.ResponseText := '{}'
	}

	Send() {
		this.State.Sends += 1
		this.State.LeaseInsideSend := _UpdaterTest_OperationLeaseActiveOrFalse()
		if IsObject(this.SendInterleave)
			this.SendInterleave.Call()
		this.State.TerminalsInsideSend := this.State.Terminals
		this.State.AbortsInsideSend := this.State.Aborts
		return true
	}

	WaitForResponse(*) {
		this.State.Waits += 1
		this.State.LeaseInsideWait := _UpdaterTest_OperationLeaseActiveOrFalse()
		if IsObject(this.WaitInterleave)
			this.WaitInterleave.Call()
		this.State.TerminalsInsideWait := this.State.Terminals
		this.State.AbortsInsideWait := this.State.Aborts
		return false
	}

	GetResponseHeader(*) {
		return ""
	}

	Abort() {
		this.State.Aborts += 1
		if this.ThrowOnAbort
			throw Error("deterministic Abort failure")
		return true
	}
}

_UpdaterTest_CaptureOperationLeaseTerminal(State, Json, Request,
	Terminal := 0) {
	State.LeaseAtTerminal := _UpdaterTest_OperationLeaseActiveOrFalse()
	State.AbortsAtTerminal := State.Aborts
	_UpdaterTest_CaptureOwnedPreparationTerminal(
		State, Json, Request, Terminal)
}

_UpdaterTest_CancelOperationLease(State, Transport := 0, *) {
	global UPDATER_CANCEL_REASON_SUSPEND
	State.LeaseDuringCancel := _UpdaterTest_OperationLeaseActiveOrFalse()
	_Updater_CancelAsyncChecks(UPDATER_CANCEL_REASON_SUSPEND)
	State.TerminalsDuringCancel := State.Terminals
	State.AbortsDuringCancel := State.Aborts
	return Transport
}

_UpdaterTest_CancelThenThrowOwnedPreparation(State, *) {
	global UPDATER_CANCEL_REASON_SUSPEND
	State.LeaseDuringCancel := _UpdaterTest_OperationLeaseActiveOrFalse()
	_Updater_CancelAsyncChecks(UPDATER_CANCEL_REASON_SUSPEND)
	State.TerminalsDuringCancel := State.Terminals
	throw Error("deterministic preparation throw after cancellation")
}

_UpdaterTest_NewOperationLeaseState() {
	return { Sends: 0, Waits: 0, Aborts: 0, Polls: 0,
		Terminals: 0, Json: "not-called", CompletedRequest: 0,
		Terminal: 0, LeaseDuringCancel: false,
		LeaseInsideSend: false, LeaseInsideWait: false,
		LeaseAtTerminal: false, AbortsAtTerminal: -1,
		TerminalsDuringCancel: -1, AbortsDuringCancel: -1,
		TerminalsInsideSend: -1, AbortsInsideSend: -1,
		TerminalsInsideWait: -1, AbortsInsideWait: -1 }
}

_UpdaterTest_SendLeaseCancelsBeforeCommit() {
	global UPDATER_REQUEST_ORIGIN_BACKGROUND, UPDATER_CANCEL_REASON_SUSPEND
	global _UpdaterAsyncRequests, _UpdaterActiveSendLeaseCount
	RegisterOwner := _UpdaterTest_ResolveFunction(
		"_Updater_RegisterAsyncRequestOwner")
	SendOwned := _UpdaterTest_ResolveFunction("_Updater_SendOwnedAsyncRequest")
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		State := _UpdaterTest_NewOperationLeaseState()
		Http := _UpdaterTestOperationLeaseHttp(State)
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_BACKGROUND, false)
		Owner := RegisterOwner.Call(
			Http, "main",
			_UpdaterTest_CaptureOperationLeaseTerminal.Bind(State),
			"test://cancel-before-send-commit", Request)
		PrepareFn := _UpdaterTest_CancelOperationLease.Bind(State, Http)
		PollFn := (Id) => (State.Polls += 1, true)

		AssertEqual(false, SendOwned.Call(
			Owner, PollFn, "test cancel before Send commit", PrepareFn),
			"cancellation after lease acquisition must win before COM Send")
		AssertEqual(0, State.TerminalsDuringCancel,
			"leased cancellation must defer its callback until release")
		AssertEqual(0, State.AbortsDuringCancel,
			"leased cancellation must not Abort a transport still on the stack")
		AssertEqual(true, State.LeaseDuringCancel,
			"the deterministic cancellation must run under the exact lease")
		AssertEqual(0, State.Sends,
			"cancel-before-commit must prevent Send")
		AssertEqual(1, State.Aborts,
			"lease release must abort the cancelled exact transport once")
		AssertEqual(1, State.Terminals,
			"lease release must deliver one cancellation terminal")
		AssertEqual(true, State.LeaseAtTerminal,
			"deferred callback return must remain inside published quiescence")
		AssertEqual(1, State.AbortsAtTerminal,
			"deferred callback must observe its transport already aborted")
		Assert(_Updater_AsyncTerminalIsCancelled(State.Terminal)
			and State.Terminal.Reason == UPDATER_CANCEL_REASON_SUSPEND,
			"lease release must preserve the typed suspend terminal")
		AssertEqual(0, State.Polls,
			"cancel-before-commit must never hand off to polling")
		AssertEqual(false, _UpdaterTest_OperationLeaseActiveOrFalse(),
			"every sender exit must release operation quiescence")
		AssertEqual(0, _UpdaterActiveSendLeaseCount,
			"the exact operation-lease count must return to zero")
		AssertEqual(0, _UpdaterAsyncRequests.Count,
			"cancel-before-commit must leave no registry owner")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: lease closes cancel-before-Send window (updater-operation-lease)",
	_UpdaterTest_SendLeaseCancelsBeforeCommit)

_UpdaterTest_SendStackDefersCancellationTerminal() {
	global UPDATER_REQUEST_ORIGIN_BACKGROUND, UPDATER_CANCEL_REASON_SUSPEND
	global _UpdaterAsyncRequests
	RegisterOwner := _UpdaterTest_ResolveFunction(
		"_Updater_RegisterAsyncRequestOwner")
	SendOwned := _UpdaterTest_ResolveFunction("_Updater_SendOwnedAsyncRequest")
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		State := _UpdaterTest_NewOperationLeaseState()
		InterleaveFn := _UpdaterTest_CancelOperationLease.Bind(State)
		Http := _UpdaterTestOperationLeaseHttp(State, InterleaveFn)
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_BACKGROUND, false)
		Owner := RegisterOwner.Call(
			Http, "main",
			_UpdaterTest_CaptureOperationLeaseTerminal.Bind(State),
			"test://cancel-inside-send", Request)

		AssertEqual(false, SendOwned.Call(
			Owner, (Id) => (State.Polls += 1, true),
			"test cancellation inside Send"),
			"cancellation pumped by Send must own the terminal")
		AssertEqual(true, State.LeaseInsideSend,
			"the exact lease must remain active through return from Send")
		AssertEqual(0, State.TerminalsInsideSend,
			"Send-stack cancellation must not re-enter its callback")
		AssertEqual(0, State.AbortsInsideSend,
			"Send-stack cancellation must not Abort the active COM frame")
		AssertEqual(1, State.Sends,
			"the deterministic Send interleave must execute once")
		AssertEqual(1, State.Aborts,
			"release after Send must abort the retired transport once")
		AssertEqual(1, State.Terminals,
			"release after Send must terminal exactly once")
		Assert(_Updater_AsyncTerminalIsCancelled(State.Terminal)
			and State.Terminal.Reason == UPDATER_CANCEL_REASON_SUSPEND,
			"Send-stack cancellation must retain its typed reason")
		AssertEqual(0, State.Polls,
			"a Send cancelled on its stack must never start polling")
		AssertEqual(false, _UpdaterTest_OperationLeaseActiveOrFalse(),
			"Send return must release operation quiescence")
		AssertEqual(0, _UpdaterAsyncRequests.Count,
			"Send cancellation must leave no registry owner")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: Send-stack cancellation defers terminal (updater-operation-lease)",
	_UpdaterTest_SendStackDefersCancellationTerminal)

_UpdaterTest_CancellationOwnsPreparationThrowTerminal() {
	global UPDATER_REQUEST_ORIGIN_BACKGROUND, UPDATER_CANCEL_REASON_SUSPEND
	global _UpdaterAsyncRequests
	RegisterOwner := _UpdaterTest_ResolveFunction(
		"_Updater_RegisterAsyncRequestOwner")
	SendOwned := _UpdaterTest_ResolveFunction("_Updater_SendOwnedAsyncRequest")
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		State := _UpdaterTest_NewOperationLeaseState()
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_BACKGROUND, false)
		Owner := RegisterOwner.Call(
			0, "main",
			_UpdaterTest_CaptureOperationLeaseTerminal.Bind(State),
			"test://cancel-then-prepare-throw", Request)

		AssertEqual(false, SendOwned.Call(
			Owner, (Id) => (State.Polls += 1, true),
			"test cancel and preparation throw",
			_UpdaterTest_CancelThenThrowOwnedPreparation.Bind(State)),
			"cancellation must win over a simultaneous preparation exception")
		AssertEqual(true, State.LeaseDuringCancel,
			"preparation must run inside the operation lease")
		AssertEqual(0, State.TerminalsDuringCancel,
			"preparation cancellation must defer while its frame unwinds")
		AssertEqual(1, State.Terminals,
			"cancel plus throw must deliver only one terminal")
		Assert(_Updater_AsyncTerminalIsCancelled(State.Terminal)
			and State.Terminal.Reason == UPDATER_CANCEL_REASON_SUSPEND,
			"cancellation, not the sibling exception, must own the terminal")
		AssertEqual(0, State.Sends,
			"a cancelled throwing preparation must never reach Send")
		AssertEqual(0, State.Polls,
			"a cancelled throwing preparation must never start polling")
		AssertEqual(false, _UpdaterTest_OperationLeaseActiveOrFalse(),
			"preparation unwind must release operation quiescence")
		AssertEqual(0, _UpdaterAsyncRequests.Count,
			"cancel plus throw must leave no registry owner")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: cancellation owns simultaneous preparation throw (updater-operation-lease)",
	_UpdaterTest_CancellationOwnsPreparationThrowTerminal)

_UpdaterTest_BothPollComPathsDeferCancellation() {
	global UPDATER_REQUEST_ORIGIN_BACKGROUND, UPDATER_CANCEL_REASON_SUSPEND
	global _UpdaterAsyncRequests
	RegisterOwner := _UpdaterTest_ResolveFunction(
		"_Updater_RegisterAsyncRequestOwner")
	LatestPoll := _UpdaterTest_ResolveFunction("_Updater_PollAsync")
	ReleasesPoll := _UpdaterTest_ResolveFunction("_Updater_PollReleasesListAsync")
	Saved := _UpdaterTest_SaveRequestState()
	try {
		for Name, PollFn in Map(
				"latest", LatestPoll,
				"releases", ReleasesPoll) {
			_UpdaterTest_ResetRequestState()
			State := _UpdaterTest_NewOperationLeaseState()
			InterleaveFn := _UpdaterTest_CancelOperationLease.Bind(State)
			Http := _UpdaterTestOperationLeaseHttp(State, 0, InterleaveFn)
			Request := _Updater_NewRequestContext(
				UPDATER_REQUEST_ORIGIN_BACKGROUND, false)
			Owner := RegisterOwner.Call(
				Http, "main",
				_UpdaterTest_CaptureOperationLeaseTerminal.Bind(State),
				"test://cancel-inside-" . Name . "-poll", Request)

			AssertEqual(false, PollFn.Call(Owner.Id),
				Name . " cancellation pumped by WaitForResponse must retire the poll")
			AssertEqual(true, State.LeaseInsideWait,
				Name . " WaitForResponse must execute under the exact operation lease")
			AssertEqual(0, State.TerminalsInsideWait,
				Name . " poll cancellation must defer its callback until COM returns")
			AssertEqual(0, State.AbortsInsideWait,
				Name . " poll cancellation must not Abort the active COM frame")
			AssertEqual(1, State.Waits,
				Name . " poll must execute its deterministic wait once")
			AssertEqual(1, State.Aborts,
				Name . " poll release must abort the cancelled transport once")
			AssertEqual(1, State.Terminals,
				Name . " poll release must deliver exactly one terminal")
			Assert(_Updater_AsyncTerminalIsCancelled(State.Terminal)
				and State.Terminal.Reason == UPDATER_CANCEL_REASON_SUSPEND,
				Name . " poll must retain the typed cancellation reason")
			AssertEqual(false, _UpdaterTest_OperationLeaseActiveOrFalse(),
				Name . " poll exit must release operation quiescence")
			AssertEqual(0, _UpdaterAsyncRequests.Count,
				Name . " cancelled poll must leave no registry owner")
		}
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: both poll COM paths defer cancellation (updater-operation-lease)",
	_UpdaterTest_BothPollComPathsDeferCancellation)

_UpdaterTest_AbortFailureStillDeliversCancellation() {
	global UPDATER_REQUEST_ORIGIN_BACKGROUND, UPDATER_CANCEL_REASON_SUSPEND
	global _UpdaterAsyncRequests, _UpdaterActiveSendLeaseCount
	RegisterOwner := _UpdaterTest_ResolveFunction(
		"_Updater_RegisterAsyncRequestOwner")
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		State := _UpdaterTest_NewOperationLeaseState()
		Http := _UpdaterTestOperationLeaseHttp(State, 0, 0, true)
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_BACKGROUND, false)
		RegisterOwner.Call(
			Http, "main",
			_UpdaterTest_CaptureOperationLeaseTerminal.Bind(State),
			"test://throwing-abort", Request)

		_Updater_CancelAsyncChecks(UPDATER_CANCEL_REASON_SUSPEND)

		AssertEqual(1, State.Aborts,
			"direct cancellation must attempt its exact transport Abort once")
		AssertEqual(1, State.Terminals,
			"an Abort exception must not suppress the typed terminal callback")
		AssertEqual(1, State.AbortsAtTerminal,
			"the terminal callback must run after the failed Abort attempt")
		AssertEqual(false, State.LeaseAtTerminal,
			"a transport between polls must cancel without inventing a COM lease")
		Assert(_Updater_AsyncTerminalIsCancelled(State.Terminal)
			and State.Terminal.Reason == UPDATER_CANCEL_REASON_SUSPEND,
			"Abort failure must preserve the typed cancellation reason")
		AssertEqual(0, _UpdaterActiveSendLeaseCount,
			"direct cancellation must not leak operation quiescence")
		AssertEqual(0, _UpdaterAsyncRequests.Count,
			"direct cancellation must retire registry ownership before Abort")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: Abort failure cannot suppress cancellation (updater-operation-lease)",
	_UpdaterTest_AbortFailureStillDeliversCancellation)

_UpdaterTest_PollHandoffFailureCannotLeakOwner() {
	global UPDATER_REQUEST_ORIGIN_BACKGROUND, _UpdaterAsyncRequests
	RegisterOwner := _UpdaterTest_ResolveFunction(
		"_Updater_RegisterAsyncRequestOwner")
	SendOwned := _UpdaterTest_ResolveFunction("_Updater_SendOwnedAsyncRequest")
	Saved := _UpdaterTest_SaveRequestState()
	try {
		for Mode in ["invalid", "false"] {
			_UpdaterTest_ResetRequestState()
			State := _UpdaterTest_NewOperationLeaseState()
			Http := _UpdaterTestOperationLeaseHttp(State)
			Request := _Updater_NewRequestContext(
				UPDATER_REQUEST_ORIGIN_BACKGROUND, false)
			Owner := RegisterOwner.Call(
				Http, "main",
				_UpdaterTest_CaptureOperationLeaseTerminal.Bind(State),
				"test://poll-handoff-" . Mode, Request)
			PollFn := Mode == "invalid" ? 0 : (Id) => false

			AssertEqual(false, SendOwned.Call(
				Owner, PollFn, "test poll handoff " . Mode),
				Mode . " poll handoff must fail closed")
			AssertEqual(Mode == "invalid" ? 0 : 1, State.Sends,
				"validation must precede Send while false handoff follows it")
			AssertEqual(1, State.Aborts,
				Mode . " handoff failure must abort its exact transport")
			AssertEqual(1, State.Terminals,
				Mode . " handoff failure must callback exactly once")
			AssertEqual(0, State.Terminal,
				Mode . " handoff failure must not impersonate cancellation")
			AssertEqual(false, _UpdaterTest_OperationLeaseActiveOrFalse(),
				Mode . " handoff failure must release operation quiescence")
			AssertEqual(0, _UpdaterAsyncRequests.Count,
				Mode . " handoff failure must leave no registry owner")
		}
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: poll handoff failure cannot leak owner (updater-operation-lease)",
	_UpdaterTest_PollHandoffFailureCannotLeakOwner)

_UpdaterTest_BackgroundSchedule(State, TimerFn, DelayMs) {
	State.Calls += 1
	if (DelayMs == 0) {
		State.Disarms += 1
		Loop State.Pending.Length {
			if ObjPtr(State.Pending[A_Index]) == ObjPtr(TimerFn) {
				State.Pending.RemoveAt(A_Index)
				break
			}
		}
		return true
	}
	if State.InlineNext {
		State.InlineNext := false
		TimerFn.Call()
		return true
	}
	if State.HasOwnProp("InterleaveFn") and IsObject(State.InterleaveFn) {
		InterleaveFn := State.InterleaveFn
		State.InterleaveFn := 0
		InterleaveFn.Call()
	}
	State.Pending.Push(TimerFn)
	return true
}

_UpdaterTest_ReplaceBackgroundOwnerDuringArm(State, ScheduleFn) {
	global _UpdaterBackgroundOwner
	State.Interleaves += 1
	Updater_StopBackgroundChecks(false)
	Updater_StartBackgroundChecks(ScheduleFn, false)
	State.SuccessorOwner := _UpdaterBackgroundOwner
}

_UpdaterTest_BackgroundOwnerRejectsStaleTick() {
	global UPDATER_CHECK_INTERVAL, _UpdaterBackgroundFn
	global _UpdaterBackgroundOwner, _UpdaterBackgroundOwnerCounter
	global _UpdaterAsyncRequests
	SavedRequests := _UpdaterTest_SaveRequestState()
	SavedInterval := UPDATER_CHECK_INTERVAL
	HadFn := IsSet(_UpdaterBackgroundFn)
	if HadFn
		SavedFn := _UpdaterBackgroundFn
	HadOwner := IsSet(_UpdaterBackgroundOwner)
	if HadOwner
		SavedOwner := _UpdaterBackgroundOwner
	HadCounter := IsSet(_UpdaterBackgroundOwnerCounter)
	if HadCounter
		SavedCounter := _UpdaterBackgroundOwnerCounter
	try {
		_UpdaterTest_ResetRequestState()
		UPDATER_CHECK_INTERVAL := 60
		_UpdaterBackgroundFn := unset
		_UpdaterBackgroundOwner := 0
		_UpdaterBackgroundOwnerCounter := 0
		State := { Calls: 0, Disarms: 0, InlineNext: true, Pending: [],
			InterleaveFn: 0, Interleaves: 0, SuccessorOwner: 0 }
		ScheduleFn := _UpdaterTest_BackgroundSchedule.Bind(State)

		AssertEqual(true, Updater_StartBackgroundChecks(ScheduleFn, false),
			"Start must replace an inline-consumed arm with one future owner")
		AssertEqual(2, State.Calls,
			"the inline callback must consume A and force one bounded B arm")
		AssertEqual(1, State.Pending.Length,
			"successful Start must own exactly one demonstrably future callback")
		OldTick := State.Pending[1]
		OldOwner := _UpdaterBackgroundOwner
		AssertEqual(true, Updater_StopBackgroundChecks(false),
			"Stop must retire and disarm the exact first owner")
		AssertEqual(0, State.Pending.Length,
			"retiring the first owner must remove its pending timer")
		AssertEqual(false, IsObject(OldOwner.TimerFn),
			"Stop must break the retired Owner-BoundFunc reference cycle")

		AssertEqual(true, Updater_StartBackgroundChecks(ScheduleFn, false),
			"Start after Stop must publish a successor owner")
		NewOwner := _UpdaterBackgroundOwner
		NewTick := State.Pending[1]
		Assert(NewOwner.Id > OldOwner.Id,
			"Stop-Start must use a monotone owner epoch")
		CallsBeforeStale := State.Calls
		AssertEqual(false, OldTick.Call(),
			"a queued callback from the retired owner must be inert")
		AssertEqual(CallsBeforeStale, State.Calls,
			"the stale callback must not arm a timer for the successor")
		AssertEqual(1, State.Pending.Length,
			"the successor must retain exactly its own pending callback")
		Assert(ObjPtr(State.Pending[1]) == ObjPtr(NewTick),
			"the stale callback must not replace the successor timer")
		AssertEqual(0, _UpdaterAsyncRequests.Count,
			"the stale callback must not dispatch an HTTP request")

		; Stronger interleave: the current tick has already claimed MayRun when
		; its rearm scheduler pumps Stop -> Start. Its failed old-owner arm must
		; not globally stop the successor that now owns the cadence.
		State.Pending.RemoveAt(1)
		State.InterleaveFn := _UpdaterTest_ReplaceBackgroundOwnerDuringArm.Bind(
			State, ScheduleFn)
		OwnerBeforeInterleave := _UpdaterBackgroundOwner
		AssertEqual(false, NewTick.Call(),
			"an old tick displaced during rearm must retire without dispatch")
		AssertEqual(1, State.Interleaves,
			"the scheduler must execute the deterministic Stop-Start interleave")
		Assert(IsObject(State.SuccessorOwner)
			and ObjPtr(State.SuccessorOwner) == ObjPtr(_UpdaterBackgroundOwner)
			and ObjPtr(_UpdaterBackgroundOwner) != ObjPtr(OwnerBeforeInterleave),
			"the reentrant Start successor must remain the published owner")
		AssertEqual(false, IsObject(OwnerBeforeInterleave.TimerFn),
			"a displaced arm must disarm its callback and break its owner cycle")
		Assert(_UpdaterBackgroundOwner.Active
			and _UpdaterBackgroundOwner.Armed
			and _UpdaterBackgroundOwner.Phase == "armed",
			"the displaced tick must not stop the successor cadence")
		AssertEqual(1, State.Pending.Length,
			"detached old-arm cleanup must leave only the successor callback")
		Assert(ObjPtr(State.Pending[1])
			== ObjPtr(_UpdaterBackgroundOwner.TimerFn),
			"the sole remaining timer must belong to the successor owner")
		AssertEqual(0, _UpdaterAsyncRequests.Count,
			"the displaced tick must not dispatch after losing its arm owner")
		Updater_StopBackgroundChecks(false)
		AssertEqual(false, IsObject(State.SuccessorOwner.TimerFn),
			"final Stop must release the successor BoundFunc cycle")
	} finally {
		UPDATER_CHECK_INTERVAL := SavedInterval
		if HadFn
			_UpdaterBackgroundFn := SavedFn
		else
			_UpdaterBackgroundFn := unset
		if HadOwner
			_UpdaterBackgroundOwner := SavedOwner
		else
			_UpdaterBackgroundOwner := unset
		if HadCounter
			_UpdaterBackgroundOwnerCounter := SavedCounter
		else
			_UpdaterBackgroundOwnerCounter := unset
		_UpdaterTest_RestoreRequestState(SavedRequests)
	}
}
Test("Updater AHK-31: stale Stop-Start tick cannot adopt its successor (updater-background-owner-epoch)",
	_UpdaterTest_BackgroundOwnerRejectsStaleTick)

_UpdaterTest_BeginBoundaryDuringBackgroundArm(State) {
	State.Interleaves += 1
	State.BoundaryOwner := _Updater_BeginAsyncAdmissionBoundary(
		"channel switch")
}

_UpdaterTest_BackgroundArmCannotCrossChannelBoundary() {
	global UPDATER_CHECK_INTERVAL, _UpdaterBackgroundFn
	global _UpdaterBackgroundOwner, _UpdaterBackgroundOwnerCounter
	global _UpdaterAsyncRequests
	Saved := _UpdaterTest_SaveRequestState()
	SavedInterval := UPDATER_CHECK_INTERVAL
	HadFn := IsSet(_UpdaterBackgroundFn)
	if HadFn
		SavedFn := _UpdaterBackgroundFn
	HadOwner := IsSet(_UpdaterBackgroundOwner)
	if HadOwner
		SavedOwner := _UpdaterBackgroundOwner
	SavedCounter := _UpdaterBackgroundOwnerCounter
	try {
		_UpdaterTest_ResetRequestState()
		UPDATER_CHECK_INTERVAL := 60
		_UpdaterBackgroundFn := unset
		_UpdaterBackgroundOwner := 0
		State := { Calls: 0, Disarms: 0, InlineNext: false,
			Pending: [], InterleaveFn: 0, Interleaves: 0,
			BoundaryOwner: 0 }
		ScheduleFn := _UpdaterTest_BackgroundSchedule.Bind(State)
		AssertEqual(true, Updater_StartBackgroundChecks(ScheduleFn, false),
			"the ready-tick repro must begin with one armed owner")
		ReadyTick := State.Pending.RemoveAt(1)
		OldOwner := _UpdaterBackgroundOwner
		State.InterleaveFn := _UpdaterTest_BeginBoundaryDuringBackgroundArm.Bind(State)
		AssertEqual(false, ReadyTick.Call(),
			"a boundary acquired by the rearm scheduler must retire the ready tick")
		AssertEqual(1, State.Interleaves,
			"the scheduler must pump the deterministic channel boundary")
		Assert(IsObject(State.BoundaryOwner),
			"the reentrant channel boundary must own admission")
		AssertEqual(false, IsSet(_UpdaterBackgroundFn),
			"the detached rearm must not leave a dead callback published")
		AssertEqual(false, IsObject(_UpdaterBackgroundOwner),
			"the detached rearm must not leave a dead cadence owner")
		AssertEqual(false, IsObject(OldOwner.TimerFn),
			"detached cleanup must break the exact BoundFunc cycle")
		AssertEqual(0, State.Pending.Length,
			"detached cleanup must disarm the scheduler's callback")
		AssertEqual(0, _UpdaterAsyncRequests.Count,
			"a tick that crossed channel admission must not dispatch HTTP")
		_Updater_EndAsyncAdmissionBoundary(State.BoundaryOwner)
		State.BoundaryOwner := 0

		_UpdaterBackgroundFn := unset
		_UpdaterBackgroundOwner := 0
		StateTwo := { Calls: 0, Disarms: 0, InlineNext: false,
			Pending: [], InterleaveFn: 0, Interleaves: 0,
			BoundaryOwner: 0 }
		StateTwo.InterleaveFn :=
			_UpdaterTest_BeginBoundaryDuringBackgroundArm.Bind(StateTwo)
		AssertEqual(false, Updater_StartBackgroundChecks(
			_UpdaterTest_BackgroundSchedule.Bind(StateTwo), false),
			"initial Start must fail if its scheduler opens a channel boundary")
		AssertEqual(false, IsSet(_UpdaterBackgroundFn),
			"failed initial arm must unpublish its callback")
		AssertEqual(false, IsObject(_UpdaterBackgroundOwner),
			"failed initial arm must retire its owner")
		AssertEqual(0, StateTwo.Pending.Length,
			"failed initial arm must disarm the detached timer")
		_Updater_EndAsyncAdmissionBoundary(StateTwo.BoundaryOwner)
		StateTwo.BoundaryOwner := 0
	} finally {
		if IsObject(State.BoundaryOwner)
			_Updater_EndAsyncAdmissionBoundary(State.BoundaryOwner)
		if IsSet(StateTwo) and IsObject(StateTwo.BoundaryOwner)
			_Updater_EndAsyncAdmissionBoundary(StateTwo.BoundaryOwner)
		try Updater_StopBackgroundChecks(false)
		UPDATER_CHECK_INTERVAL := SavedInterval
		_UpdaterBackgroundOwnerCounter := SavedCounter
		if HadFn
			_UpdaterBackgroundFn := SavedFn
		else
			_UpdaterBackgroundFn := unset
		if HadOwner
			_UpdaterBackgroundOwner := SavedOwner
		else
			_UpdaterBackgroundOwner := unset
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: background arm cannot cross channel admission (updater-channel-replacement-transaction)",
	_UpdaterTest_BackgroundArmCannotCrossChannelBoundary)





; ====================================================
; ====================================================
; ======= AHK-32/ Causal tray-root publication =======
; ====================================================
; ====================================================

_UpdaterTest_SaveTrayRootState() {
	global _TrayMenuStage
	global _TrayRootRequestedGeneration, _TrayRootPublishedGeneration
	global _TrayRootActive, _TrayRootLifecycleEpoch
	global _TrayRootLatestAuthorizeFn, _TrayRootLatestWorkerFn
	global _TrayRootRetryGeneration, _TrayRootAutomaticRetryCount
	return {
		Stage: _TrayMenuStage,
		RequestedGeneration: _TrayRootRequestedGeneration,
		PublishedGeneration: _TrayRootPublishedGeneration,
		Active: _TrayRootActive,
		LifecycleEpoch: _TrayRootLifecycleEpoch,
		LatestAuthorizeFn: _TrayRootLatestAuthorizeFn,
		LatestWorkerFn: _TrayRootLatestWorkerFn,
		RetryGeneration: _TrayRootRetryGeneration,
		AutomaticRetryCount: _TrayRootAutomaticRetryCount
	}
}

_UpdaterTest_ResetTrayRootState() {
	global _TrayMenuStage
	global _TrayRootRequestedGeneration, _TrayRootPublishedGeneration
	global _TrayRootActive, _TrayRootLifecycleEpoch
	global _TrayRootLatestAuthorizeFn, _TrayRootLatestWorkerFn
	global _TrayRootRetryGeneration, _TrayRootAutomaticRetryCount
	_TrayMenuStage := false
	_TrayRootRequestedGeneration := 0
	_TrayRootPublishedGeneration := 0
	_TrayRootActive := false
	_TrayRootLifecycleEpoch := 0
	_TrayRootLatestAuthorizeFn := 0
	_TrayRootLatestWorkerFn := 0
	_TrayRootRetryGeneration := 0
	_TrayRootAutomaticRetryCount := 0
}

_UpdaterTest_RestoreTrayRootState(Saved) {
	global _TrayMenuStage
	global _TrayRootRequestedGeneration, _TrayRootPublishedGeneration
	global _TrayRootActive, _TrayRootLifecycleEpoch
	global _TrayRootLatestAuthorizeFn, _TrayRootLatestWorkerFn
	global _TrayRootRetryGeneration, _TrayRootAutomaticRetryCount
	_TrayMenuStage := Saved.Stage
	_TrayRootRequestedGeneration := Saved.RequestedGeneration
	_TrayRootPublishedGeneration := Saved.PublishedGeneration
	_TrayRootActive := Saved.Active
	_TrayRootLifecycleEpoch := Saved.LifecycleEpoch
	_TrayRootLatestAuthorizeFn := Saved.LatestAuthorizeFn
	_TrayRootLatestWorkerFn := Saved.LatestWorkerFn
	_TrayRootRetryGeneration := Saved.RetryGeneration
	_TrayRootAutomaticRetryCount := Saved.AutomaticRetryCount
}

_UpdaterTest_StageThenSuspend(State, PublishAuthorizeFn) {
	State.StageCount += 1
	WasSuspended := A_IsSuspended
	if !WasSuspended
		Suspend(1)
	try {
		Authorized := PublishAuthorizeFn.Call()
		if ((Authorized is Integer) and Authorized == 1)
			State.PublishCount += 1
		return Authorized
	} finally {
		if !WasSuspended
			Suspend(0)
	}
}

_UpdaterTest_GenerationCallbackRechecksAfterStaging() {
	global _UpdaterPauseGeneration, _UpdaterMenuRebuildPending
	SavedRequest := _UpdaterTest_SaveRequestState()
	SavedTray := _UpdaterTest_SaveTrayRootState()
	try {
		_UpdaterTest_ResetRequestState()
		_UpdaterTest_ResetTrayRootState()
		AssertFalse(A_IsSuspended,
			"the causal pause repro must begin from a running driver")
		State := { StageCount: 0, PublishCount: 0 }
		Result := _Updater_RunMenuRebuildForGeneration(
			_UpdaterPauseGeneration,
			_UpdaterTest_StageThenSuspend.Bind(State))
		AssertFalse(Result,
			"a pause entered after detached staging must refuse terminal root publication")
		AssertEqual(1, State.StageCount,
			"the repro must cross the detached staging boundary exactly once")
		AssertEqual(0, State.PublishCount,
			"a root staged before pause must never become visible during that pause")
		AssertTrue(_UpdaterMenuRebuildPending,
			"terminal pause refusal must retain the updater menu obligation for resume")
	} finally {
		if A_IsSuspended
			Suspend(0)
		_UpdaterTest_RestoreTrayRootState(SavedTray)
		_UpdaterTest_RestoreRequestState(SavedRequest)
	}
}
Test("Updater AHK-32: generation rebuild rechecks pause after staging (updater-tray-terminal-authorization)",
	_UpdaterTest_GenerationCallbackRechecksAfterStaging)

_UpdaterTest_StageThenAdvanceGeneration(State, PublishAuthorizeFn) {
	global _UpdaterPauseGeneration
	State.StageCount += 1
	_UpdaterPauseGeneration += 1
	Authorized := PublishAuthorizeFn.Call()
	if ((Authorized is Integer) and Authorized == 1)
		State.PublishCount += 1
	return Authorized
}

_UpdaterTest_RequestCallbackRechecksGenerationAfterStaging() {
	global UPDATER_REQUEST_ORIGIN_BACKGROUND, _UpdaterMenuRebuildPending
	SavedRequest := _UpdaterTest_SaveRequestState()
	SavedTray := _UpdaterTest_SaveTrayRootState()
	try {
		_UpdaterTest_ResetRequestState()
		_UpdaterTest_ResetTrayRootState()
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_BACKGROUND, false)
		State := { StageCount: 0, PublishCount: 0 }
		Result := _Updater_RunMenuRebuildForRequest(Request,
			_UpdaterTest_StageThenAdvanceGeneration.Bind(State))
		AssertFalse(Result,
			"a request invalidated after detached staging must refuse terminal root publication")
		AssertEqual(1, State.StageCount,
			"the request repro must cross the detached staging boundary exactly once")
		AssertEqual(0, State.PublishCount,
			"a stale request generation must not publish its detached tray root")
		AssertTrue(_UpdaterMenuRebuildPending,
			"terminal generation refusal must retain a fresh updater menu obligation")
	} finally {
		_UpdaterTest_RestoreTrayRootState(SavedTray)
		_UpdaterTest_RestoreRequestState(SavedRequest)
	}
}
Test("Updater AHK-32: request rebuild rechecks generation after staging (updater-tray-terminal-authorization)",
	_UpdaterTest_RequestCallbackRechecksGenerationAfterStaging)

_UpdaterTest_TerminalOutcomeWorker(Mode, PublishAuthorizeFn) {
	Authorized := PublishAuthorizeFn.Call()
	if !((Authorized is Integer) and Authorized == 1)
		return false
	switch Mode {
		case "false": return false
		case "malformed": return "1"
		case "throw": throw Error("deterministic tray-root worker failure")
	}
	return true
}

_UpdaterTest_TerminalFailuresRetainPendingObligation() {
	global _UpdaterPauseGeneration, _UpdaterMenuRebuildPending
	SavedRequest := _UpdaterTest_SaveRequestState()
	SavedTray := _UpdaterTest_SaveTrayRootState()
	try {
		for _, Mode in ["false", "malformed", "throw"] {
			_UpdaterTest_ResetRequestState()
			_UpdaterTest_ResetTrayRootState()
			Result := _Updater_RunMenuRebuildForGeneration(
				_UpdaterPauseGeneration,
				_UpdaterTest_TerminalOutcomeWorker.Bind(Mode))
			AssertFalse(Result,
				Mode . " terminal outcome must not acknowledge updater tray publication")
			AssertTrue(_UpdaterMenuRebuildPending,
				Mode . " terminal outcome must retain the updater menu obligation")
		}
	} finally {
		_UpdaterTest_RestoreTrayRootState(SavedTray)
		_UpdaterTest_RestoreRequestState(SavedRequest)
	}
}
Test("Updater AHK-32: refused malformed and thrown tray terminals stay pending (updater-tray-terminal-authorization)",
	_UpdaterTest_TerminalFailuresRetainPendingObligation)

_UpdaterTest_ResumeReplayOutcomeWorker(State, Mode, PublishAuthorizeFn) {
	State.CallCount += 1
	Authorized := PublishAuthorizeFn.Call()
	if !((Authorized is Integer) and Authorized == 1)
		return false
	switch Mode {
		case "false": return false
		case "malformed": return "1"
		case "throw": throw Error("deterministic resumed tray-root worker failure")
	}
	return true
}

_UpdaterTest_ResumeReplaysPendingMenuWithStrictTerminalAck() {
	global _UpdaterMenuRebuildPending
	SavedRequest := _UpdaterTest_SaveRequestState()
	SavedTray := _UpdaterTest_SaveTrayRootState()
	try {
		for _, Scenario in [
			{ Mode: "true", Expected: true },
			{ Mode: "false", Expected: false },
			{ Mode: "malformed", Expected: false },
			{ Mode: "throw", Expected: false }
		] {
			_UpdaterTest_ResetRequestState()
			_UpdaterTest_ResetTrayRootState()
			_UpdaterMenuRebuildPending := true
			State := { CallCount: 0 }
			Result := Updater_OnSuspendResume(0, false,
				_UpdaterTest_ResumeReplayOutcomeWorker.Bind(State, Scenario.Mode))

			AssertEqual(Scenario.Expected, Result,
				Scenario.Mode . " resumed terminal must return its strict acknowledgement")
			AssertEqual(1, State.CallCount,
				Scenario.Mode . " pending obligation must traverse the resume replay exactly once")
			AssertEqual(!Scenario.Expected, _UpdaterMenuRebuildPending,
				Scenario.Mode . " resumed terminal must clear pending only after strict true")
		}
	} finally {
		_UpdaterTest_RestoreTrayRootState(SavedTray)
		_UpdaterTest_RestoreRequestState(SavedRequest)
	}
}
Test("Updater AHK-32: resume replays pending root with strict terminal acknowledgement (updater-tray-resume-replay)",
	_UpdaterTest_ResumeReplaysPendingMenuWithStrictTerminalAck)





; ===============================================
; ===============================================
; ======= AHK-34/ Global config admission =======
; ===============================================
; ===============================================

_UpdaterTest_GlobalBarrierWriter(State, Args*) {
	global ConfigurationFile
	State.Writes += 1
	State.TerminalDuringWrite := _ConfigWriteTerminalIsActive()
	if State.HasOwnProp("CaptureWriterArgs") && State.CaptureWriterArgs
		State.WriterArgs := Args
	if State.HasOwnProp("ProbeCompetingTerminal")
		&& State.ProbeCompetingTerminal {
		Competing := _ConfigWriteTerminalTryAcquire([
			ConfigurationFile . ".writer-sibling"])
		State.CompetingTerminalAdmitted := Competing is Object
		if Competing is Object
			_ConfigWriteTerminalRelease(Competing)
	}
	return State.HasOwnProp("WriteResult") ? State.WriteResult : true
}

_UpdaterTest_GlobalBarrierMenuSchedule(State, Args*) {
	State.MenuSchedules += 1
	return true
}

_UpdaterTest_GlobalBarrierMenuMutatesLive(State, Args*) {
	global UPDATER_CHECK_INTERVAL
	State.MenuSchedules += 1
	; Models a yielding scheduler that dispatches a stale direct writer before
	; returning its strict acknowledgement to the owned transaction.
	UPDATER_CHECK_INTERVAL := 999
	return true
}

_UpdaterTest_GlobalBarrierReload(State, Args*) {
	State.Reloads += 1
	State.TerminalDuringReload := _ConfigWriteTerminalIsActive()
	return State.HasOwnProp("ReloadResult") ? State.ReloadResult : true
}

_UpdaterTest_GlobalBarrierReloadSchedule(State, Continuation, DelayMs) {
	State.ReloadSchedules += 1
	State.ReloadContinuation := Continuation
	return true
}

_UpdaterTest_GlobalBarrierRecovery(State, Args*) {
	global ConfigurationFile
	State.Recoveries += 1
	State.TerminalDuringRecovery := _ConfigWriteTerminalIsActive()
	Competing := _ConfigWriteLeaseTryAcquire(
		ConfigurationFile . ".recovery-sibling")
	State.SiblingAdmittedDuringRecovery := Competing is Object
	if Competing is Object
		_ConfigWriteLeaseRelease(Competing)
	return true
}

_UpdaterTest_GlobalTerminalRefusesPreferencesBeforeEffects() {
	global UPDATER_CHANNEL, UPDATER_CHECK_INTERVAL
	global UPDATER_REQUEST_ORIGIN_MANUAL
	global _UpdaterDownloadInProgress, _UpdaterChannelEpoch
	global _UpdaterFetchCache, _UpdaterPendingReleaseNotification
	global UPDATER_LATEST_RELEASE, ConfigurationFile
	global _UpdaterBackgroundFn, _UpdaterBackgroundOwner
	Saved := _UpdaterTest_SaveRequestState()
	SavedDownload := _UpdaterDownloadInProgress
	SavedInterval := UPDATER_CHECK_INTERVAL
	SavedChannel := UPDATER_CHANNEL
	SavedEpoch := _UpdaterChannelEpoch
	SavedCache := _UpdaterFetchCache
	SavedPending := _UpdaterPendingReleaseNotification
	HadLatest := IsSet(UPDATER_LATEST_RELEASE)
	if HadLatest
		SavedLatest := UPDATER_LATEST_RELEASE
	Barrier := 0
	try {
		try Updater_StopBackgroundChecks(false)
		_UpdaterTest_ResetRequestState()
		_UpdaterDownloadInProgress := false
		UPDATER_CHANNEL := "main"
		UPDATER_CHECK_INTERVAL := 60
		_UpdaterBackgroundFn := unset
		_UpdaterBackgroundOwner := 0
		State := { Writes: 0, MenuSchedules: 0,
			Reloads: 0, ReloadSchedules: 0, Notices: 0,
			TerminalDuringWrite: false }
		Barrier := _ConfigWriteTerminalTryAcquire([
			ConfigurationFile . ".unrelated-terminal-target"])
		Assert(IsObject(Barrier),
			"the repro must own a process-wide sibling-path terminal barrier")
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)

		AssertEqual(false, Updater_SetCheckInterval(
			120, Request, false,
			_UpdaterTest_RecordChannelNotice.Bind(State),
			_UpdaterTest_GlobalBarrierWriter.Bind(State),
			_UpdaterTest_GlobalBarrierMenuSchedule.Bind(State)),
			"a sibling terminal barrier must refuse interval persistence")
		AssertEqual(false, _UpdaterTest_ResolveFunction(
			"Updater_SetChannel").Call(
			"dev", Request, false,
			_UpdaterTest_RecordChannelNotice.Bind(State),
			_UpdaterTest_GlobalBarrierWriter.Bind(State),
			_UpdaterTest_GlobalBarrierReload.Bind(State),
			_UpdaterTest_GlobalBarrierReloadSchedule.Bind(State)),
			"a sibling terminal barrier must refuse channel persistence")
		AssertEqual(0, State.Writes,
			"terminal collision must stop before either injected writer")
		AssertEqual(0, State.MenuSchedules,
			"terminal collision must not schedule a menu rebuild")
		AssertEqual(0, State.ReloadSchedules,
			"terminal collision must not publish a deferred Reload")
		AssertEqual(0, State.Reloads,
			"terminal collision must not invoke Reload")
		AssertEqual(60, UPDATER_CHECK_INTERVAL,
			"terminal collision must retain the prior live interval")
		AssertEqual("main", UPDATER_CHANNEL,
			"terminal collision must retain the prior live channel")
		AssertEqual(false, IsSet(_UpdaterBackgroundFn),
			"terminal collision must not arm or retire a timer callback")
		AssertEqual(false, IsObject(_UpdaterBackgroundOwner),
			"terminal collision must not publish a cadence owner")
		AssertEqual(false, _Updater_AsyncAdmissionBoundaryActive(),
			"global collision must not leak updater-local admission")
		AssertEqual(false, _Updater_ChannelReloadTransitionActive(),
			"global collision must not leak a deferred transition")
		AssertEqual(2, State.Notices,
			"each refused user preference must remain visibly terminal")
	} finally {
		if IsObject(Barrier)
			_ConfigWriteTerminalRelease(Barrier)
		try Updater_StopBackgroundChecks(false)
		_UpdaterDownloadInProgress := SavedDownload
		UPDATER_CHECK_INTERVAL := SavedInterval
		UPDATER_CHANNEL := SavedChannel
		_UpdaterChannelEpoch := SavedEpoch
		_UpdaterFetchCache := SavedCache
		_UpdaterPendingReleaseNotification := SavedPending
		if HadLatest
			UPDATER_LATEST_RELEASE := SavedLatest
		else
			UPDATER_LATEST_RELEASE := unset
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-34: global terminal collision precedes all preference effects (updater-global-config-barrier)",
	_UpdaterTest_GlobalTerminalRefusesPreferencesBeforeEffects)

_UpdaterTest_ChannelRetainsGlobalBundleThroughReloadRecovery() {
	global UPDATER_CHANNEL, UPDATER_CHECK_INTERVAL
	global UPDATER_REQUEST_ORIGIN_MANUAL
	global _UpdaterDownloadInProgress, _UpdaterChannelEpoch
	global _UpdaterFetchCache, _UpdaterPendingReleaseNotification
	global UPDATER_LATEST_RELEASE, ConfigurationFile
	Saved := _UpdaterTest_SaveRequestState()
	SavedDownload := _UpdaterDownloadInProgress
	SavedInterval := UPDATER_CHECK_INTERVAL
	SavedChannel := UPDATER_CHANNEL
	SavedEpoch := _UpdaterChannelEpoch
	SavedCache := _UpdaterFetchCache
	SavedPending := _UpdaterPendingReleaseNotification
	HadLatest := IsSet(UPDATER_LATEST_RELEASE)
	if HadLatest
		SavedLatest := UPDATER_LATEST_RELEASE
	try {
		try Updater_StopBackgroundChecks(false)
		_UpdaterTest_ResetRequestState()
		_UpdaterDownloadInProgress := false
		UPDATER_CHANNEL := "main"
		UPDATER_CHECK_INTERVAL := 0
		State := { Writes: 0, WriteResult: true,
			TerminalDuringWrite: false, ReloadSchedules: 0,
			ReloadContinuation: 0, Reloads: 0,
			ReloadResult: false, TerminalDuringReload: false,
			Recoveries: 0, TerminalDuringRecovery: false,
			SiblingAdmittedDuringRecovery: true, Notices: 0 }
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)
		AssertEqual(true, _UpdaterTest_ResolveFunction(
			"Updater_SetChannel").Call(
			"dev", Request, false,
			_UpdaterTest_RecordChannelNotice.Bind(State),
			_UpdaterTest_GlobalBarrierWriter.Bind(State),
			_UpdaterTest_GlobalBarrierReload.Bind(State),
			_UpdaterTest_GlobalBarrierReloadSchedule.Bind(State),
			0,
			_UpdaterTest_GlobalBarrierRecovery.Bind(State)),
			"a durable channel change must transfer its exact bundle to Reload")
		AssertEqual(1, State.Writes,
			"channel durability must be attempted once")
		AssertEqual(true, State.TerminalDuringWrite,
			"channel persistence must borrow the process-wide terminal owner")
		AssertEqual(true, _ConfigWriteTerminalIsActive(),
			"the deferred transition must retain global admission after the setter returns")
		CompetingWriter := _ConfigWriteLeaseTryAcquire(
			ConfigurationFile . ".deferred-sibling")
		CompetingWriterAdmitted := CompetingWriter is Object
		if CompetingWriterAdmitted
			_ConfigWriteLeaseRelease(CompetingWriter)
		AssertEqual(false, CompetingWriterAdmitted,
			"no sibling writer may enter while deferred Reload is alive")
		AssertEqual(1, State.ReloadSchedules,
			"the transition must own exactly one deferred Reload callback")
		Assert(HasMethod(State.ReloadContinuation, "Call"),
			"the deferred Reload callback must remain callable")
		AssertEqual(false, State.ReloadContinuation.Call(),
			"the deterministic Reload refusal must enter owned recovery")
		AssertEqual(1, State.Reloads,
			"the deferred Reload seam must run once")
		AssertEqual(true, State.TerminalDuringReload,
			"the global bundle must remain active on the Reload stack")
		AssertEqual(1, State.Recoveries,
			"Reload refusal must run one exact recovery")
		AssertEqual(true, State.TerminalDuringRecovery,
			"recovery must retain the same global bundle")
		AssertEqual(false, State.SiblingAdmittedDuringRecovery,
			"recovery must still exclude every sibling config writer")
		AssertEqual(false, _ConfigWriteTerminalIsActive(),
			"completed recovery must release the exact terminal bundle")
		AssertEqual(false, _Updater_AsyncAdmissionBoundaryActive(),
			"completed recovery must consume updater-local admission")
		AssertEqual("dev", UPDATER_CHANNEL,
			"Reload refusal occurs after the durable live channel commit")
	} finally {
		try Updater_StopBackgroundChecks(false)
		UPDATER_CHANNEL := SavedChannel
		UPDATER_CHECK_INTERVAL := SavedInterval
		_UpdaterDownloadInProgress := SavedDownload
		_UpdaterChannelEpoch := SavedEpoch
		_UpdaterFetchCache := SavedCache
		_UpdaterPendingReleaseNotification := SavedPending
		if HadLatest
			UPDATER_LATEST_RELEASE := SavedLatest
		else
			UPDATER_LATEST_RELEASE := unset
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-34: channel Reload retains global config ownership through recovery (updater-global-config-barrier)",
	_UpdaterTest_ChannelRetainsGlobalBundleThroughReloadRecovery)

_UpdaterTest_IntervalWriterFailureCannotPublishStaleLiveState() {
	global UPDATER_CHECK_INTERVAL, UPDATER_REQUEST_ORIGIN_MANUAL
	global _UpdaterBackgroundFn, _UpdaterBackgroundOwner
	global ConfigurationFile, UPDATER_INI_SECTION, UPDATER_INI_INTERVAL_KEY
	Saved := _UpdaterTest_SaveRequestState()
	SavedInterval := UPDATER_CHECK_INTERVAL
	try {
		try Updater_StopBackgroundChecks(false)
		_UpdaterTest_ResetRequestState()
		UPDATER_CHECK_INTERVAL := 60
		_UpdaterBackgroundFn := unset
		_UpdaterBackgroundOwner := 0
		State := { Writes: 0, WriteResult: false,
			TerminalDuringWrite: false, MenuSchedules: 0,
			Notices: 0, ProbeCompetingTerminal: true,
			CompetingTerminalAdmitted: true, CaptureWriterArgs: true,
			WriterArgs: [] }
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)
		AssertEqual(false, Updater_SetCheckInterval(
			120, Request, false,
			_UpdaterTest_RecordChannelNotice.Bind(State),
			_UpdaterTest_GlobalBarrierWriter.Bind(State),
			_UpdaterTest_GlobalBarrierMenuSchedule.Bind(State)),
			"a strict false writer must reject the interval transaction")
		AssertEqual(1, State.Writes,
			"the strict writer seam must run exactly once")
		AssertEqual(4, State.WriterArgs.Length,
			"the owned gateway must preserve the legacy four-argument writer seam")
		AssertEqual(120, State.WriterArgs[1],
			"the legacy writer must still receive the requested value first")
		AssertEqual(ConfigurationFile, State.WriterArgs[2],
			"the legacy writer must still receive the exact config path second")
		AssertEqual(UPDATER_INI_SECTION, State.WriterArgs[3],
			"the legacy writer must still receive the updater section third")
		AssertEqual(UPDATER_INI_INTERVAL_KEY, State.WriterArgs[4],
			"the legacy writer must still receive the interval key fourth")
		AssertEqual(false, State.TerminalDuringWrite,
			"ordinary interval persistence must own a path lease, not a terminal bundle")
		AssertEqual(false, State.CompetingTerminalAdmitted,
			"the owned writer must prevent a process-wide terminal from interleaving")
		AssertEqual(60, UPDATER_CHECK_INTERVAL,
			"writer failure must retain the exact old live preference")
		AssertEqual(0, State.MenuSchedules,
			"writer failure must not reach native menu handoff")
		AssertEqual(false, IsSet(_UpdaterBackgroundFn),
			"writer failure must not retire or arm a cadence callback")
		AssertEqual(false, IsObject(_UpdaterBackgroundOwner),
			"writer failure must not publish a cadence owner")
		AssertEqual(1, State.Notices,
			"writer failure must have one visible terminal")
	} finally {
		try Updater_StopBackgroundChecks(false)
		UPDATER_CHECK_INTERVAL := SavedInterval
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-34: interval writer owns config before failure publication (updater-global-config-barrier)",
	_UpdaterTest_IntervalWriterFailureCannotPublishStaleLiveState)

_UpdaterTest_IntervalPublicationReassertsDurableCandidate() {
	global UPDATER_CHECK_INTERVAL, UPDATER_REQUEST_ORIGIN_MANUAL
	global _UpdaterBackgroundFn, _UpdaterBackgroundOwner
	Saved := _UpdaterTest_SaveRequestState()
	SavedInterval := UPDATER_CHECK_INTERVAL
	try {
		try Updater_StopBackgroundChecks(false)
		_UpdaterTest_ResetRequestState()
		UPDATER_CHECK_INTERVAL := 60
		_UpdaterBackgroundFn := unset
		_UpdaterBackgroundOwner := 0
		State := { Writes: 0, WriteResult: true,
			TerminalDuringWrite: false, MenuSchedules: 0,
			Notices: 0 }
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)
		AssertEqual(true, Updater_SetCheckInterval(
			120, Request, false,
			_UpdaterTest_RecordChannelNotice.Bind(State),
			_UpdaterTest_GlobalBarrierWriter.Bind(State),
			_UpdaterTest_GlobalBarrierMenuMutatesLive.Bind(State)),
			"an acknowledged native handoff must commit the interval transaction")
		AssertEqual(1, State.Writes,
			"the successful transaction must write its durable candidate once")
		AssertEqual(1, State.MenuSchedules,
			"the deterministic yielding scheduler must run once")
		AssertEqual(120, UPDATER_CHECK_INTERVAL,
			"owned publication must replace a stale live mutation with the durable candidate")
		AssertEqual(0, State.Notices,
			"the recovered live candidate must not emit a false failure terminal")
	} finally {
		try Updater_StopBackgroundChecks(false)
		UPDATER_CHECK_INTERVAL := SavedInterval
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-34: interval publication replaces stale reentrant live state (updater-global-config-barrier)",
	_UpdaterTest_IntervalPublicationReassertsDurableCandidate)

_UpdaterTest_RecordCrossChannelInstall(State, Release) {
	State.Installs += 1
	State.Tag := Release.Tag
	return true
}

_UpdaterTest_RecordCrossChannelRebuild(State) {
	State.Rebuilds += 1
	return true
}

_UpdaterTest_ExplicitChannelTransitionUsesReleasePolicy() {
	global UPDATER_LATEST_RELEASE, UPDATER_REQUEST_ORIGIN_MANUAL
	ShouldOffer := _UpdaterTest_ResolveFunction("_Updater_ShouldOfferCandidate")
	Publish := _UpdaterTest_ResolveFunction("_Updater_PublishOneClickRelease")
	Workflow := FileRead(A_ScriptDir . "\..\..\..\..\.github\workflows\ci.yml", "UTF-8")
	TagTemplate := 'tag="v0.0.0-dev.${next_n}"'
	Assert(InStr(Workflow, TagTemplate) > 0,
		"the regression must consume the exact dev tag family owned by CI")
	DevCandidate := StrReplace(
		SubStr(TagTemplate, 6, StrLen(TagTemplate) - 6), "${next_n}", "117")
	AssertEqual(true, ShouldOffer.Call(
		DevCandidate, "1.0.0", "dev", "main"),
		"an explicit stable-to-dev transition must offer the CI dev candidate")
	AssertEqual(false, ShouldOffer.Call(
		DevCandidate, "1.0.0", "main", "main"),
		"ordinary same-channel checks must retain strict semver ordering")
	AssertEqual(false, ShouldOffer.Call(
		"v1.1.0", "1.0.0", "dev", "main"),
		"a stable candidate must never satisfy a selected dev channel")
	AssertEqual(true, ShouldOffer.Call(
		"v1.1.0", "0.0.0-dev.117", "main", "dev"),
		"an explicit dev-to-stable transition must offer a stable candidate")
	AssertEqual(false, ShouldOffer.Call(
		"not-semver", "1.0.0", "dev", "main"),
		"channel migration must fail closed on malformed release metadata")

	Saved := _UpdaterTest_SaveRequestState()
	HadLatest := IsSet(UPDATER_LATEST_RELEASE)
	if HadLatest
		SavedLatest := UPDATER_LATEST_RELEASE
	try {
		_UpdaterTest_ResetRequestState()
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false, "dev")
		Release := { Tag: DevCandidate, RawJson: "{}" }
		State := { Rebuilds: 0, Installs: 0, Tag: "" }
		AssertEqual(true, Publish.Call(
			Release, Request, false,
			_UpdaterTest_RecordCrossChannelRebuild.Bind(State),
			0, _UpdaterTest_RecordCrossChannelInstall.Bind(State)),
			"the selected dev candidate must cross publication into staging")
		AssertEqual(1, State.Rebuilds,
			"candidate publication must refresh the visible updater state once")
		AssertEqual(1, State.Installs,
			"the explicit channel migration must invoke staging exactly once")
		AssertEqual(DevCandidate, State.Tag,
			"staging must receive the exact CI-generated candidate")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
		if HadLatest
			UPDATER_LATEST_RELEASE := SavedLatest
		else
			UPDATER_LATEST_RELEASE := unset
	}
}
Test("Updater AHK-047: explicit channel changes override cross-channel semver ordering (updater-cross-channel-install-2026-08-28)",
	_UpdaterTest_ExplicitChannelTransitionUsesReleasePolicy)

class _UpdaterTestDeadlineWorker {
	__New(State) {
		this.State := State
	}

	terminate() {
		this.State.Terminations += 1
		return true
	}
}

_UpdaterTest_RecordDeadlineFailure(State, Message, Options) {
	State.Notices += 1
	State.Message := Message
	return true
}

_UpdaterTest_AbsoluteDownloadDeadlineOwnsCleanup() {
	global _UpdaterDownloadInProgress, _UpdaterDownloadWorker
	global _UpdaterDownloadRequest, _UpdaterDownloadArtifacts
	global _UpdaterDownloadStartedTick, _UpdaterSelfUpdateEpoch
	global _UpdaterSwapOwner, _UpdaterExitIntent, _UpdaterExitInvocation
	global UPDATER_HTTP_DOWNLOAD_DEADLINE_MS
	Enforce := _UpdaterTest_ResolveFunction("_Updater_EnforceDownloadDeadline")
	Saved := {
		InProgress: _UpdaterDownloadInProgress,
		Worker: _UpdaterDownloadWorker,
		Request: _UpdaterDownloadRequest,
		Artifacts: _UpdaterDownloadArtifacts,
		StartedTick: _UpdaterDownloadStartedTick,
		Epoch: _UpdaterSelfUpdateEpoch,
		SwapOwner: _UpdaterSwapOwner,
		ExitIntent: _UpdaterExitIntent,
		ExitInvocation: _UpdaterExitInvocation
	}
	TempDir := A_Temp . "\ergopti-updater-deadline-" . A_TickCount
	DirCreate(TempDir)
	NewExe := TempDir . "\ErgoptiPlus_new.exe"
	SwapScript := TempDir . "\swap_update.ps1"
	FileAppend("partial", NewExe, "UTF-8-RAW")
	FileAppend("partial", SwapScript, "UTF-8-RAW")
	State := { Terminations: 0, Notices: 0, Message: "" }
	try {
		_UpdaterDownloadInProgress := true
		_UpdaterDownloadWorker := _UpdaterTestDeadlineWorker(State)
		_UpdaterDownloadRequest := 0
		_UpdaterDownloadArtifacts := { NewExe: NewExe, SwapScript: SwapScript }
		_UpdaterDownloadStartedTick := 100
		_UpdaterSelfUpdateEpoch := 51
		_UpdaterSwapOwner := 0
		_UpdaterExitIntent := 0
		_UpdaterExitInvocation := 0
		AssertEqual(true, Enforce.Call(
			100 + UPDATER_HTTP_DOWNLOAD_DEADLINE_MS, false,
			_UpdaterTest_RecordDeadlineFailure.Bind(State)),
			"the wall-clock boundary must terminate the exact transaction")
		AssertEqual(1, State.Terminations,
			"deadline expiry must terminate the owned process tree exactly once")
		AssertEqual(false, _UpdaterDownloadInProgress,
			"deadline expiry must release the global download owner")
		Assert(!FileExist(NewExe),
			"deadline expiry must delete the partial executable")
		Assert(!FileExist(SwapScript),
			"deadline expiry must delete the partial swap worker")
		AssertEqual(1, State.Notices,
			"deadline expiry must publish one visible failure terminal")
	} finally {
		_UpdaterDownloadInProgress := Saved.InProgress
		_UpdaterDownloadWorker := Saved.Worker
		_UpdaterDownloadRequest := Saved.Request
		_UpdaterDownloadArtifacts := Saved.Artifacts
		_UpdaterDownloadStartedTick := Saved.StartedTick
		_UpdaterSelfUpdateEpoch := Saved.Epoch
		_UpdaterSwapOwner := Saved.SwapOwner
		_UpdaterExitIntent := Saved.ExitIntent
		_UpdaterExitInvocation := Saved.ExitInvocation
		try FileDelete(NewExe)
		try FileDelete(SwapScript)
		try DirDelete(TempDir)
	}
}
Test("Updater AHK-049: absolute download deadline terminates and cleans staging (updater-absolute-download-deadline-2026-08-28)",
	_UpdaterTest_AbsoluteDownloadDeadlineOwnsCleanup)
