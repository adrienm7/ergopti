; static/ergopti_plus/windows/tests/unit/test_runtime_contract_version.ahk

; ==============================================================================
; MODULE: AutoHotkey runtime contract version test
; DESCRIPTION:
; The release exe is compiled on the interpreter named by
; _shared/modules/updater/windows_release_toolchain.json. The AHK suites ran on a
; 2.0.19 the CI job downloaded on its own while the driver's hook behaviours
; (prefix keys firing on press or release, modifier key-up suppression, the
; SendLevel key-up correlation) were measured on 2.0.26, and those rules changed
; between 2.0.19 and 2.0.23. Nothing compared the two, so a claim measured on
; one runtime shipped on the other (runtime-contract-2026-09-26). The CI suite
; must run on the contract's runtime. A developer's own AutoHotkey is not the
; code's concern: it updates itself, and a local run on 2.0.27 went red with
; nothing wrong in the code (runtime-contract-local-2026-09-26), so a local
; mismatch is a logged notice and CI (GITHUB_ACTIONS) enforces the pin.
; ==============================================================================

#Requires AutoHotkey v2.0

; The runtime version the release contract pins, read from the shared file.
_RCV_ContractRuntimeVersion() {
	Path := A_ScriptDir . "\..\..\_shared\modules\updater\windows_release_toolchain.json"
	Text := FileRead(Path, "UTF-8")
	if !RegExMatch(Text, 's)"runtime"\s*:\s*\{[^}]*"version"\s*:\s*"([^"]+)"', &Match)
		throw ValueError("The release contract names no runtime version.", -1, Path)
	return Match[1]
}

; Whether this run is a CI run: GitHub Actions sets GITHUB_ACTIONS=true in the
; environment of every step, and the workflow never overrides it
; (tools/test/test-release-packaging-workflow.cjs).
_RCV_IsCi() {
	return EnvGet("GITHUB_ACTIONS") = "true"
}

; Hold the runtime Actual to the contract's Expected: a mismatch fails under
; CI; anywhere else it yields the notice the suite logs.
; @return {String} "" on the contract's runtime, else the local notice.
_RCV_CheckRuntime(Expected, Actual, IsCi) {
	if (Actual == Expected)
		return ""
	if IsCi
		AssertEqual(Expected, Actual,
			"the CI AHK suite must run on the AutoHotkey the release exe ships (windows_release_toolchain.json runtime.version)")
	return "# notice: this local run uses AutoHotkey " . Actual . ", not the " . Expected
		. " the release exe ships; the hook behaviours are pinned on " . Expected . " and CI enforces it."
}

_RCV_SuiteRunsOnTheContractRuntime() {
	Notice := _RCV_CheckRuntime(_RCV_ContractRuntimeVersion(), A_AhkVersion, _RCV_IsCi())
	if (Notice != "")
		_TestPrint(Notice)
}
Test("runtime contract: the suite runs on the interpreter the release exe ships (runtime-contract-2026-09-26)",
	_RCV_SuiteRunsOnTheContractRuntime)

; The same check with the runtime set by the case: a mismatch can never pass
; silently in CI, and never fails a developer's run.
_RCV_MismatchFailsInCiOnly() {
	AssertThrows(() => _RCV_CheckRuntime("2.0.26", "2.0.27", true),
		"under CI a runtime other than the contract's must fail the suite")
	Notice := _RCV_CheckRuntime("2.0.26", "2.0.27", false)
	AssertTrue(InStr(Notice, "# notice: ") == 1 and InStr(Notice, "AutoHotkey 2.0.27, not the 2.0.26") > 0,
		"a local run on another runtime must pass with a notice naming both versions, got: " . Notice)
	AssertEqual("", _RCV_CheckRuntime("2.0.26", "2.0.26", true), "the contract's runtime passes under CI")
	AssertEqual("", _RCV_CheckRuntime("2.0.26", "2.0.26", false), "and locally, silently")
}
Test("runtime contract: a runtime mismatch fails under CI and is a notice locally (runtime-contract-local-2026-09-26)",
	_RCV_MismatchFailsInCiOnly)
