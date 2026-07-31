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
	AssertEqual(true, InStr(Worker, "ShellRunner_Spawn") > 0,
		"Updater staging worker must use ShellRunner_Spawn so the hook thread never waits for HTTP")
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
