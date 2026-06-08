; static/ergopti_plus/windows/tests/test_updater.ahk

; ==============================================================================
; MODULE: Updater Logic Tests
; DESCRIPTION:
; Unit-tests for the semver and JSON parsing functions in lib/updater.ahk.
; Ensures prerelease ordering and version parsing work correctly.
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
