; static/ergopti_plus/windows/tests/test_updater.ahk

; ==============================================================================
; MODULE: Updater Logic Tests
; DESCRIPTION:
; Unit-tests for the semver and JSON parsing functions in lib/updater.ahk.
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
	; Locate lib/updater.ahk relative to the tests/ directory.
	SplitPath(A_ScriptDir, , &WindowsDir)
	UpdaterFile := WindowsDir . "\lib\updater.ahk"

	try {
		Source := FileRead(UpdaterFile)
	} catch {
		; File not found in this environment — skip rather than false-fail.
		return
	}

	; Extract only the body of Updater_FetchLatestJson so we don't match
	; SetTimeouts that belong to other functions (e.g. Updater_FetchReleasesListJson).
	FnStart := InStr(Source, "Updater_FetchLatestJson(")
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
