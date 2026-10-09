; tests/meta/test_suite_watchdog_manifest.ahk

; ==============================================================================
; MODULE: AHK Suite Watchdog Manifest Regression Test
; DESCRIPTION:
; Guards the adaptive terminal budget and the partial-result publication that
; let CI prove every planned test reached one terminal result.
; ==============================================================================

#Requires AutoHotkey v2.0+





; ==========================================
; ==========================================
; ======= 1/ Adaptive watchdog contract ====
; ==========================================
; ==========================================

_TSWM_WatchdogTracksSuiteSize() {
	global TEST_REGISTRY, _SUITE_TIMEOUT_MS, _SUITE_MAX_TIMEOUT_MS
	global _SUITE_STARTUP_BUDGET_MS, _SUITE_PER_TEST_BUDGET_MS
	Source := FileRead(A_ScriptDir . "\run_all.ahk", "UTF-8")
	Assert(InStr(Source, "_SUITE_TIMEOUT_MS := _SuiteTimeoutForCount(TEST_REGISTRY.Length)") > 0,
		"the suite timeout must use the tested calculation with the exact planned count")
	Assert(InStr(Source, "_SUITE_MAX_TIMEOUT_MS") > 0,
		"the adaptive timeout must stay below the external CI process timeout")
	Assert(InStr(Source, "_SUITE_TIMEOUT_MS := 360000") == 0,
		"the stale six-minute global timeout must never return")
	AssertEqual(_SuiteTimeoutForCount(TEST_REGISTRY.Length), _SUITE_TIMEOUT_MS,
		"the active timeout must match the complete registered corpus")
	AssertEqual(_SUITE_STARTUP_BUDGET_MS, _SuiteTimeoutForCount(0))
	AssertEqual(_SUITE_STARTUP_BUDGET_MS + _SUITE_PER_TEST_BUDGET_MS, _SuiteTimeoutForCount(1))
	SaturationCount := Ceil((_SUITE_MAX_TIMEOUT_MS - _SUITE_STARTUP_BUDGET_MS) / _SUITE_PER_TEST_BUDGET_MS)
	Assert(SaturationCount > 1, "the fixture must exercise growth before saturation")
	AssertEqual(_SUITE_STARTUP_BUDGET_MS + (SaturationCount - 1) * _SUITE_PER_TEST_BUDGET_MS,
		_SuiteTimeoutForCount(SaturationCount - 1), "the budget must still grow immediately below the cap")
	Assert(_SuiteTimeoutForCount(SaturationCount - 1) < _SUITE_MAX_TIMEOUT_MS)
	AssertEqual(_SUITE_MAX_TIMEOUT_MS, _SuiteTimeoutForCount(SaturationCount),
		"reaching the safety cap is intentional even as the corpus grows")
	AssertEqual(_SUITE_MAX_TIMEOUT_MS, _SuiteTimeoutForCount(SaturationCount + 1000),
		"larger corpora must never consume the CI publication reserve")
	Assert(_SUITE_MAX_TIMEOUT_MS < 25 * 60 * 1000,
		"the in-process safety cap must leave time for CI to publish the partial manifest")
}

_TSWM_WatchdogPublishesPartialResults() {
	Source := FileRead(A_ScriptDir . "\run_all.ahk", "UTF-8")
	Start := InStr(Source, "_WatchdogFire() {")
	Body := Start > 0 ? SubStr(Source, Start, 500) : ""
	Assert(InStr(Body, "_CopyTestResultsForCi()") > 0,
		"a timed-out suite must publish its partial planned/executed transcript before exiting")
}

Test("AHK suite watchdog: budget follows planned corpus size (ahk-045)",
	_TSWM_WatchdogTracksSuiteSize)
Test("AHK suite watchdog: timeout publishes partial execution manifest (ahk-045)",
	_TSWM_WatchdogPublishesPartialResults)
