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
; one runtime shipped on the other (runtime-contract-2026-09-26). This suite
; must now run on the contract's runtime.
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

_RCV_SuiteRunsOnTheContractRuntime() {
	Expected := _RCV_ContractRuntimeVersion()
	AssertEqual(Expected, A_AhkVersion,
		"the AHK suite must run on the AutoHotkey the release exe ships (windows_release_toolchain.json runtime.version)")
}
Test("runtime contract: the suite runs on the interpreter the release exe ships (runtime-contract-2026-09-26)",
	_RCV_SuiteRunsOnTheContractRuntime)
